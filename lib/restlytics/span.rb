# frozen_string_literal: true

module Restlytics
  # A single span, accumulated in-request and serialized to OTLP/JSON on flush.
  #
  # Timestamps are kept as integer nanoseconds internally and only stringified at
  # serialization time -- the OTLP/JSON contract requires *UnixNano fields to be
  # decimal STRINGS (to preserve 64-bit precision through JSON).
  #
  # Attribute values are kept as raw Ruby scalars in @attributes and converted to
  # the OTLP AnyValue wrapper ({"stringValue"|"intValue"|...}) at serialization.
  # The single most error-prone rule lives here: intValue MUST be a string.
  class Span
    # OTLP SpanKind enum values we use.
    KIND_SERVER = 2
    KIND_CLIENT = 3

    # OTLP status codes.
    STATUS_UNSET = 0
    STATUS_OK = 1
    STATUS_ERROR = 2

    attr_reader :trace_id, :span_id, :parent_span_id, :kind, :start_unix_nano
    attr_accessor :name, :end_unix_nano

    def initialize(trace_id:, span_id:, parent_span_id:, name:, kind:, start_unix_nano:, end_unix_nano:)
      @trace_id = trace_id
      @span_id = span_id
      @parent_span_id = parent_span_id
      @name = name
      @kind = kind
      @start_unix_nano = start_unix_nano
      @end_unix_nano = end_unix_nano

      # Raw attribute values (key => ruby scalar).
      @attributes = {}
      # Keys forced to intValue serialization (a value like 200 could be int or float).
      @int_keys = {}

      @status_code = STATUS_UNSET
      @status_message = nil
    end

    def set_name(name)
      @name = name
      self
    end

    def set_end(end_unix_nano)
      @end_unix_nano = end_unix_nano
      self
    end

    def set_string(key, value)
      @attributes[key] = value.to_s
      self
    end

    # Record an int attribute. Serialized as intValue (a STRING) per the contract.
    def set_int(key, value)
      @attributes[key] = value.to_i
      @int_keys[key] = true
      self
    end

    def set_double(key, value)
      @attributes[key] = value.to_f
      self
    end

    def set_bool(key, value)
      @attributes[key] = (value ? true : false)
      self
    end

    def set_status(code, message = nil)
      @status_code = code
      # Cap to keep payloads bounded; full stack traces don't belong on the wire.
      @status_message = message[0, 1024] unless message.nil?
      self
    end

    def status_code
      @status_code
    end

    # Read a string attribute back (used for self-time categorization).
    def attr_string(key)
      v = @attributes[key]
      v.is_a?(String) ? v : nil
    end

    # Duration in nanoseconds (clamped non-negative against clock skew).
    def duration_ns
      d = @end_unix_nano - @start_unix_nano
      d.negative? ? 0 : d
    end

    # Serialize to the OTLP/JSON Span shape the ingestion contract validates.
    #
    # @return [Hash]
    def to_otlp
      span = {
        "traceId" => @trace_id,
        "spanId" => @span_id,
        "name" => @name,
        "kind" => @kind,
        # Decimal STRINGS -- int64-safe in JSON.
        "startTimeUnixNano" => @start_unix_nano.to_s,
        "endTimeUnixNano" => @end_unix_nano.to_s
      }

      # parentSpanId is omitted/empty for the root SERVER span.
      if !@parent_span_id.nil? && @parent_span_id != ""
        span["parentSpanId"] = @parent_span_id
      end

      span["attributes"] = serialize_attributes unless @attributes.empty?

      # Only attach status when it carries signal (OK/ERROR); UNSET is the default.
      if @status_code != STATUS_UNSET
        status = { "code" => @status_code }
        status["message"] = @status_message if @status_message && @status_message != ""
        span["status"] = status
      end

      span
    end

    private

    def serialize_attributes
      @attributes.map do |key, value|
        { "key" => key, "value" => any_value(key, value) }
      end
    end

    # Wrap a Ruby scalar in the OTLP AnyValue shape.
    def any_value(key, value)
      if @int_keys.key?(key) || value.is_a?(Integer)
        # CONTRACT: intValue is a STRING, not a JSON number.
        { "intValue" => value.to_i.to_s }
      elsif value == true || value == false
        { "boolValue" => value }
      elsif value.is_a?(Float)
        { "doubleValue" => value }
      else
        { "stringValue" => value.to_s }
      end
    end
  end
end
