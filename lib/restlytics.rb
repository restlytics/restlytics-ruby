# frozen_string_literal: true

require_relative "restlytics/version"
require_relative "restlytics/ids"
require_relative "restlytics/sql"
require_relative "restlytics/intervals"
require_relative "restlytics/span"
require_relative "restlytics/otlp"
require_relative "restlytics/transport"
require_relative "restlytics/config"
require_relative "restlytics/tracer"
require_relative "restlytics/middleware"

# restlytics -- Ruby/Rails SDK.
#
# Zero-config performance + error tracing for Rails, shipped to the restlytics
# ingestion service in OTLP/JSON. Pure Ruby stdlib in the core (no gems): JSON +
# zlib + net/http only. Safe by default: head-based sampling, SQL normalized to
# literal-free templates, bindings counted never sent, query strings scrubbed,
# fire-and-forget transport that never blocks or raises into the host app.
#
# Typical install (Rails): require the gem and the Railtie auto-wires the Rack
# middleware + the sql.active_record subscriber. You can also drive it manually:
#
#   Restlytics.configure do |c|
#     c.key = ENV["RESTLYTICS_KEY"]
#     c.ingest_url = ENV["RESTLYTICS_INGEST_URL"]
#   end
#   Restlytics.init
module Restlytics
  class << self
    # The resolved configuration (lazily built from env + defaults).
    def config
      @config ||= Config.new
    end

    # Configure the SDK. Yields the Config so callers can override any key.
    #
    #   Restlytics.configure { |c| c.sample_rate = 0.25 }
    def configure
      yield(config) if block_given?
      config
    end

    # Build the transport + tracer from the current config and mark the SDK ready.
    # Idempotent: calling init again rebuilds with the latest config. Returns the
    # tracer (or nil when disabled / on any error -- we never raise from init).
    def init
      return @tracer if @initialized && @tracer

      @transport = build_transport
      @tracer = Tracer.new(
        transport: @transport,
        service_name: config.service_name,
        environment: config.env,
        sample_rate: config.sample_rate,
        max_spans: config.max_spans
      )
      @initialized = true
      @tracer
    rescue StandardError
      # init must never raise into the host boot sequence.
      @tracer = nil
    end

    # The process-wide tracer (built by init / the Railtie).
    def tracer
      @tracer
    end

    def transport
      @transport
    end

    # True once init has run and a key is configured.
    def enabled?
      config.enabled?
    end

    # Reset everything (mainly for tests).
    def reset!
      @config = nil
      @tracer = nil
      @transport = nil
      @initialized = false
    end

    private

    def build_transport
      case config.transport_driver
      when "null"
        NullTransport.new
      when "log"
        logger = config.logger
        writer = lambda do |json|
          if logger.respond_to?(:debug)
            logger.debug("restlytics payload: #{json}")
          else
            warn(json)
          end
        end
        LogTransport.new(writer)
      else
        on_error = build_error_logger
        HttpTransport.new(
          ingest_url: config.ingest_url,
          key: config.key,
          timeout_ms: config.timeout_ms,
          on_error: on_error
        )
      end
    end

    def build_error_logger
      logger = config.logger
      return nil unless logger.respond_to?(:debug)

      lambda do |message|
        begin
          logger.debug(message)
        rescue StandardError
          # never noisy, never thrown
        end
      end
    end
  end
end

# Load the Railtie only when Rails is present so the gem stays usable as a plain
# Rack library (and so requiring it never fails without Rails installed).
require_relative "restlytics/railtie" if defined?(Rails::Railtie)
