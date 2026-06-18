# frozen_string_literal: true

module Restlytics
  # Resolved configuration for the SDK. Values come from explicit overrides
  # (e.g. config/initializers/restlytics.rb) first, then environment variables,
  # then defaults -- the same keys every restlytics SDK uses (SPEC section 7).
  class Config
    # Sensitive query-string keys scrubbed from url.full on outbound HTTP spans.
    DEFAULT_QUERY_KEYS = %w[
      token api_key apikey password secret access_token key signature
    ].freeze

    # Request headers never read/forwarded (defense-in-depth; we don't send headers).
    DEFAULT_SENSITIVE_HEADERS = %w[
      authorization cookie set-cookie x-api-key x-restlytics-key proxy-authorization
    ].freeze

    # Paths skipped entirely (no span opened). Supports trailing `*` wildcards.
    DEFAULT_IGNORE_PATHS = %w[
      /up /health /healthz /assets/* /packs/* /cable
    ].freeze

    attr_accessor :key, :ingest_url, :service_name, :env, :sample_rate,
                  :transport, :timeout_ms, :capture_sql, :max_spans,
                  :instrument_db, :instrument_http, :instrument_cache,
                  :ignore_paths, :query_keys, :sensitive_headers, :logger

    def initialize
      @key            = env_str("RESTLYTICS_KEY", "")
      @ingest_url     = env_str("RESTLYTICS_INGEST_URL", "https://ingest.restlytics.com")
      @service_name   = env_str("RESTLYTICS_SERVICE_NAME", default_service_name)
      @env            = env_str("RESTLYTICS_ENV", env_str("RAILS_ENV", "production"))
      @sample_rate    = env_float("RESTLYTICS_SAMPLE_RATE", 1.0)
      @transport      = env_str("RESTLYTICS_TRANSPORT", "http")
      @timeout_ms     = env_int("RESTLYTICS_TIMEOUT_MS", 2000)
      @capture_sql    = env_bool("RESTLYTICS_CAPTURE_SQL", false)
      @max_spans      = env_int("RESTLYTICS_MAX_SPANS", 2000)

      @instrument_db    = env_bool("RESTLYTICS_INSTRUMENT_DB", true)
      @instrument_http  = env_bool("RESTLYTICS_INSTRUMENT_HTTP", true)
      @instrument_cache = env_bool("RESTLYTICS_INSTRUMENT_CACHE", true)

      @ignore_paths      = DEFAULT_IGNORE_PATHS.dup
      @query_keys        = DEFAULT_QUERY_KEYS.dup
      @sensitive_headers = DEFAULT_SENSITIVE_HEADERS.dup
      @logger            = nil
    end

    # The SDK stays inert (no spans, no requests) until a key is configured.
    def enabled?
      !@key.to_s.empty?
    end

    # Normalize the transport selector to one of the supported drivers.
    def transport_driver
      case @transport.to_s.downcase
      when "null", "none" then "null"
      when "log"          then "log"
      else "http" # curl|http both map to the Net::HTTP transport in Ruby
      end
    end

    private

    def default_service_name
      env_str("RESTLYTICS_SERVICE_NAME", nil) ||
        env_str("RAILS_APP_NAME", nil) ||
        "rails"
    end

    def env_str(name, default)
      v = ENV[name]
      v.nil? || v.empty? ? default : v
    end

    def env_int(name, default)
      v = ENV[name]
      v.nil? || v.empty? ? default : v.to_i
    end

    def env_float(name, default)
      v = ENV[name]
      v.nil? || v.empty? ? default : v.to_f
    end

    def env_bool(name, default)
      v = ENV[name]
      return default if v.nil? || v.empty?

      %w[1 true yes on].include?(v.downcase)
    end
  end
end
