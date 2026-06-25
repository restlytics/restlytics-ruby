# frozen_string_literal: true

require "json"

module Restlytics
  # Builds the top-level OTLP/JSON ExportTraceServiceRequest body.
  #
  # Shape (matches packages/contract ExportTraceServiceRequest exactly):
  #   { "resourceSpans": [ {
  #       "resource":   { "attributes": [ ...resource KVs... ] },
  #       "scopeSpans": [ { "scope": {"name": "restlytics-rails", "version": "..."},
  #                         "spans": [ ... ] } ]
  #   } ] }
  #
  # The resource attributes carry service identity + SDK identity; the spans carry
  # the per-request work. We emit a single resourceSpans/scopeSpans envelope because
  # every span in one request shares the same resource.
  module Otlp
    # Stable identifiers for the SDK, surfaced as resource attributes and the scope name.
    SDK_NAME = "restlytics-rails"
    SDK_LANGUAGE = "ruby"
    SDK_VERSION = "0.1.1"

    module_function

    # @param service_name [String]
    # @param environment [String]
    # @param spans [Array<Restlytics::Span>]
    # @return [Hash] ExportTraceServiceRequest
    def build(service_name, environment, spans)
      {
        "resourceSpans" => [
          {
            "resource" => {
              "attributes" => resource_attributes(service_name, environment)
            },
            "scopeSpans" => [
              {
                "scope" => { "name" => SDK_NAME, "version" => SDK_VERSION },
                "spans" => spans.map(&:to_otlp)
              }
            ]
          }
        ]
      }
    end

    # Serialize the payload to a compact JSON string (stdlib json).
    def encode(payload)
      JSON.generate(payload)
    end

    # OTLP AnyValue helpers (exactly one field set). intValue is a STRING.
    def string_value(value)
      { "stringValue" => value.to_s }
    end

    def int_value(value)
      { "intValue" => value.to_i.to_s }
    end

    def bool_value(value)
      { "boolValue" => (value ? true : false) }
    end

    def double_value(value)
      { "doubleValue" => value.to_f }
    end

    def resource_attributes(service_name, environment)
      [
        string_attr("service.name", service_name),
        string_attr("deployment.environment", environment),
        string_attr("telemetry.sdk.name", SDK_NAME),
        string_attr("telemetry.sdk.language", SDK_LANGUAGE),
        string_attr("telemetry.sdk.version", SDK_VERSION)
      ]
    end

    def string_attr(key, value)
      { "key" => key, "value" => string_value(value) }
    end
  end
end
