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
  end

  # Default transport: gzip the JSON body and POST it with Net::HTTP, on a
  # detached Thread so the host request is never blocked.
  #
  # Design constraints (all in service of "telemetry must never hurt the host app"):
  #  - Runs AFTER the response has been flushed (from Rack middleware), and the
  #    actual send happens on a background Thread, so its latency is invisible.
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

    # @param ingest_url [String] base URL; we POST to {url}/v1/traces
    # @param key [String] ingest key for the X-Restlytics-Key header
    # @param timeout_ms [Integer] open/read timeout in milliseconds
    # @param on_error [#call, nil] optional logger callback: ->(message) {}
    def initialize(ingest_url:, key:, timeout_ms: DEFAULT_TIMEOUT_MS, on_error: nil)
      super()
      @ingest_url = ingest_url.to_s
      @key = key.to_s
      @timeout_ms = (timeout_ms || DEFAULT_TIMEOUT_MS).to_i
      @on_error = on_error
    end

    def send_payload(payload)
      # Defensive: without the basics, there's nothing useful to do -- and we
      # must not raise, so just bail quietly.
      return if @ingest_url.empty? || @key.empty?

      # Encode/gzip on the caller's side is cheap; the network send is what we
      # push to a background thread (fire-and-forget). We swallow everything.
      json = Otlp.encode(payload)
      body = gzip(json)
      return if body.nil?

      url = build_url
      return if url.nil?

      Thread.new do
        begin
          post(url, body)
        rescue StandardError => e
          report_error("restlytics: send failed: #{e.class}: #{e.message}")
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Absolute backstop -- a background telemetry thread must never crash
          # the process or surface anything.
          report_error("restlytics: transport fatal: #{e.class}")
        end
      end
    rescue StandardError => e
      # Even spawning the thread / encoding must never raise into the host.
      report_error("restlytics: transport exception: #{e.class}: #{e.message}")
    end

    private

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
