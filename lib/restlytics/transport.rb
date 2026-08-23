# frozen_string_literal: true

require "json"
require "zlib"
require "stringio"
require "uri"
require "net/http"

require_relative "otlp"

module Restlytics
  # Ships a fully-built OTLP/JSON ExportTraceServiceRequest to the ingestion service.
  #
  # Implementations MUST be fire-and-forget and MUST NOT raise -- telemetry must
  # never be able to fail (or slow) the host application's request. Any transport
  # error is swallowed (and optionally logged), never surfaced.
  class Transport
    # @param payload [Hash] OTLP ExportTraceServiceRequest
    def send_payload(payload)
      raise NotImplementedError
    end

    def flush(timeout_ms: 2000)
      true
    end

    def close(timeout_ms: 2000)
      flush(timeout_ms: timeout_ms)
    end
  end

  # Default transport: gzip the JSON body and POST it with Net::HTTP using one
  # worker Thread and a bounded queue so the host request is never blocked.
  #
  # Design constraints (all in service of "telemetry must never hurt the host app"):
  #  - Runs AFTER the response has been flushed (from Rack middleware), and the
  #    actual send happens on a background worker, so its latency is invisible.
  #  - Hard short timeouts (open/read) so a slow/unreachable ingest endpoint can't
  #    pile up worker time.
  #  - Every error path is swallowed. We never raise into the host application.
  #
  # Wire format (must match the ingestion contract exactly):
  #   POST {ingest_url}/v1/traces
  #   X-Restlytics-Key: {key}
  #   Content-Type: application/json
  #   Content-Encoding: gzip
  #   body = gzip(json)
  class HttpTransport < Transport
    DEFAULT_TIMEOUT_MS = 2000
    DEFAULT_QUEUE_CAPACITY = 64
    STOP = Object.new.freeze

    # @param ingest_url [String] base URL; we POST to {url}/v1/traces
    # @param key [String] ingest key for the X-Restlytics-Key header
    # @param timeout_ms [Integer] open/read timeout in milliseconds
    # @param on_error [#call, nil] optional logger callback: ->(message) {}
    def initialize(ingest_url:, key:, timeout_ms: DEFAULT_TIMEOUT_MS, on_error: nil,
                   queue_capacity: DEFAULT_QUEUE_CAPACITY)
      super()
      @ingest_url = ingest_url.to_s
      @key = key.to_s
      @timeout_ms = (timeout_ms || DEFAULT_TIMEOUT_MS).to_i
      @on_error = on_error
      @queue_capacity = [queue_capacity.to_i, 1].max
      @queue = SizedQueue.new(@queue_capacity)
      @mutex = Mutex.new
      @closed = false
      @in_flight = 0
      @pending = 0
      @accepted = 0
      @delivered = 0
      @dropped = 0
      @failed = 0
      @worker = Thread.new { run }
      @worker.name = "restlytics-transport" if @worker.respond_to?(:name=)
      @worker.report_on_exception = false if @worker.respond_to?(:report_on_exception=)
    end

    def send_payload(payload)
      outcome = @mutex.synchronize do
        if @closed || @ingest_url.empty? || @key.empty?
          :unavailable
        else
          begin
            @pending += 1
            @accepted += 1
            @queue.push(payload, true)
            :accepted
          rescue ThreadError
            @pending -= 1
            @accepted -= 1
            :full
          end
        end
      end
      if outcome == :unavailable
        record_drop("restlytics: batch dropped because transport is closed or unconfigured")
        return
      end
      if outcome == :full
        record_drop("restlytics: batch dropped because transport queue is full")
        return
      end
      nil
    rescue StandardError => e
      record_drop("restlytics: enqueue failed: #{e.class}: #{e.message}")
    end

    def diagnostics
      @mutex.synchronize do
        {
          accepted_batches: @accepted,
          delivered_batches: @delivered,
          dropped_batches: @dropped,
          failed_batches: @failed,
          queued_batches: @queue.length,
          in_flight_batches: @in_flight,
          queue_capacity: @queue_capacity,
          closed: @closed
        }.freeze
      end
    end

    def flush(timeout_ms: DEFAULT_TIMEOUT_MS)
      deadline = monotonic + [timeout_ms.to_i, 0].max / 1000.0
      loop do
        pending = @mutex.synchronize { @pending }
        return true if pending.zero?
        return false if monotonic >= deadline

        sleep(0.005)
      end
    end

    def close(timeout_ms: DEFAULT_TIMEOUT_MS)
      already_stopped = @mutex.synchronize do
        stopped = @closed && !@worker.alive?
        @closed = true
        stopped
      end
      return true if already_stopped

      flushed = flush(timeout_ms: timeout_ms)
      return false unless flushed

      @queue.push(STOP, true)
      @worker.join([timeout_ms.to_i, 0].max / 1000.0)
      !@worker.alive?
    rescue ThreadError
      false
    end

    private

    def run
      loop do
        payload = @queue.pop
        break if payload.equal?(STOP)

        @mutex.synchronize { @in_flight = 1 }
        begin
          json = Otlp.encode(payload)
          body = gzip(json)
          url = build_url
          raise "payload encoding failed" if body.nil? || url.nil?

          post(url, body)
          @mutex.synchronize { @delivered += 1 }
        rescue StandardError => e
          @mutex.synchronize { @failed += 1 }
          report_error("restlytics: send failed: #{e.class}: #{e.message}")
        rescue Exception => e # rubocop:disable Lint/RescueException
          @mutex.synchronize { @failed += 1 }
          report_error("restlytics: transport fatal: #{e.class}")
        ensure
          @mutex.synchronize do
            @in_flight = 0
            @pending -= 1
          end
        end
      end
    end

    def record_drop(message)
      @mutex.synchronize { @dropped += 1 }
      report_error(message)
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def post(url, body)
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = (url.scheme == "https")
      timeout_s = @timeout_ms / 1000.0
      http.open_timeout = timeout_s
      http.read_timeout = timeout_s
      # Bound the SSL handshake too, where supported.
      http.ssl_timeout = timeout_s if http.respond_to?(:ssl_timeout=) && http.use_ssl?

      request = Net::HTTP::Post.new(url.request_uri)
      request["Content-Type"] = "application/json"
      request["Content-Encoding"] = "gzip"
      request["X-Restlytics-Key"] = @key
      request.body = body

      # Response is always 200 with a partialSuccess envelope -- we treat any/no
      # response as success and move on. We don't even inspect the response.
      http.request(request)
    end

    def gzip(json)
      io = StringIO.new
      io.set_encoding(Encoding::BINARY)
      gz = Zlib::GzipWriter.new(io, 6)
      gz.write(json)
      gz.close
      io.string
    rescue StandardError => e
      # gzip is required by the contract's Content-Encoding header; if it somehow
      # fails, drop the batch rather than send a mislabeled body.
      report_error("restlytics: gzip failed: #{e.message}")
      nil
    end

    def build_url
      base = @ingest_url.sub(%r{/+\z}, "")
      URI.parse("#{base}/v1/traces")
    rescue URI::InvalidURIError => e
      report_error("restlytics: invalid ingest url: #{e.message}")
      nil
    end

    def report_error(message)
      return unless @on_error.respond_to?(:call)

      begin
        @on_error.call(message)
      rescue StandardError
        # Even logging must not raise.
      end
    end
  end

  # No-op transport. Useful in tests, local dev, and CI where you don't want to
  # (or can't) reach the ingestion service. Records payloads so tests can assert
  # on the built OTLP body without any network.
  #
  # Select with RESTLYTICS_TRANSPORT=null.
  class NullTransport < Transport
    attr_reader :sent

    def initialize
      super
      @sent = []
    end

    def last_payload
      @sent.last
    end

    def send_payload(payload)
      @sent << payload
      nil
    end
  end

  # Writes the OTLP payload (as JSON) to a logger callback instead of the network.
  # Handy for local development and debugging the wire shape without standing up
  # an ingestion service.
  #
  # Select with RESTLYTICS_TRANSPORT=log.
  class LogTransport < Transport
    # @param writer [#call] callback that performs the log write: ->(json) {}
    def initialize(writer)
      super()
      @writer = writer
    end

    def send_payload(payload)
      json = JSON.pretty_generate(payload)
      @writer.call(json) if @writer.respond_to?(:call)
      nil
    rescue StandardError
      # Never raise into the host app, even for a dev transport.
      nil
    end
  end
end
