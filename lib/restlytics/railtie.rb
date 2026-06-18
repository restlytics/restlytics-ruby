# frozen_string_literal: true

require "rails/railtie"

require_relative "sql"
require_relative "span"
require_relative "middleware"

module Restlytics
  # Wires the SDK into a Rails 7 app:
  #  - inserts the Rack middleware (owns the root SERVER span),
  #  - subscribes to ActiveSupport::Notifications "sql.active_record" for DB spans,
  #  - optionally patches Net::HTTP for outbound HTTP spans (best-effort).
  #
  # Everything is guarded: a failure while wiring up instrumentation must never
  # prevent the host app from booting or serving requests.
  class Railtie < ::Rails::Railtie
    config.before_configure do
      # Allow `Restlytics.configure` in config/initializers to win; we read config
      # at initializer time below.
    end

    # Insert the middleware as early as possible so the SERVER span brackets the
    # whole request. We add it to the app's middleware stack here; the tracer is
    # built lazily in an initializer (after config/initializers have run).
    initializer "restlytics.middleware", before: :build_middleware_stack do |app|
      begin
        tracer = Restlytics.init
        if Restlytics.enabled? && tracer
          app.middleware.use Restlytics::Middleware, tracer: tracer, config: Restlytics.config
        end
      rescue StandardError
        # Never break boot. If wiring fails, the app runs untraced.
      end
    end

    # Subscribe to DB + outbound HTTP after the full app has initialized, so the
    # configured tracer exists and ActiveSupport/Net::HTTP are loaded.
    config.after_initialize do
      begin
        Restlytics.init
        next unless Restlytics.enabled? && Restlytics.tracer

        subscribe_active_record if Restlytics.config.instrument_db
        patch_net_http if Restlytics.config.instrument_http
      rescue StandardError
        # best-effort instrumentation
      end
    end

    class << self
      # DB child spans via ActiveSupport::Notifications "sql.active_record".
      #
      # The event payload carries `:sql`, `:binds`, `:name`, `:connection`, and the
      # event provides start/finish times. We:
      #  - skip SCHEMA / CACHE queries (noise, and CACHE has no real DB work),
      #  - normalize the statement to a literal-free template (db.query.summary),
      #  - record the binding COUNT only (never values),
      #  - send raw SQL only when capture_sql is enabled (capped at 2048 chars).
      def subscribe_active_record
        tracer = Restlytics.tracer
        capture_sql = Restlytics.config.capture_sql

        ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          begin
            event = ActiveSupport::Notifications::Event.new(*args)
            record_sql_event(tracer, capture_sql, event)
          rescue StandardError
            # best-effort: DB instrumentation never breaks a query
          end
        end
      end

      def record_sql_event(tracer, capture_sql, event)
        return unless tracer.sampled?

        payload = event.payload
        name = payload[:name].to_s

        # Skip schema introspection and ActiveRecord query-cache hits.
        return if name == "SCHEMA" || name == "CACHE" || payload[:cached]

        sql = payload[:sql].to_s
        return if sql.empty?

        tracer.increment_db_query_count

        # Event times are in milliseconds since the monotonic-ish clock base; we
        # back-date using the event duration to align with the tracer's clock.
        end_ns = tracer.now_ns
        start_ns = end_ns - (event.duration * 1_000_000).to_i

        summary = Sql.normalize(sql)

        span = tracer.add_child_span("db.query", start_ns, end_ns)
        return if span.nil?

        span.set_string("db.system.name", db_system(payload))
        span.set_string("db.query.summary", summary)
        span.set_int("restlytics.bindings_count", bind_count(payload))
        span.set_string("restlytics.category", "db")

        # Short, human-readable span name from the leading SQL keyword.
        if (m = summary.match(/\A\s*(\w+)/))
          span.set_name("db #{m[1].downcase}")
        end

        if capture_sql
          # Raw text may carry PII; cap hard at 2048 chars (contract max).
          span.set_string("db.query.text", sql[0, 2048])
        end
      end

      # Count binds without ever reading their values. Across AR versions binds may
      # be Attribute objects, [col, value] pairs, or raw values -- we only count.
      def bind_count(payload)
        binds = payload[:binds]
        return 0 if binds.nil?

        binds.respond_to?(:length) ? binds.length : 0
      end

      def db_system(payload)
        conn = payload[:connection]
        adapter = nil
        if conn.respond_to?(:adapter_name)
          adapter = conn.adapter_name.to_s.downcase
        end
        case adapter
        when /postgres/ then "postgresql"
        when /mysql/, /trilogy/ then "mysql"
        when /sqlite/ then "sqlite"
        else
          adapter && !adapter.empty? ? adapter : "sql"
        end
      rescue StandardError
        "sql"
      end

      # Best-effort outbound HTTP instrumentation: wrap Net::HTTP#request so each
      # call becomes a CLIENT child span. Kept light and fully guarded.
      #
      # Redaction: url.full has its query string scrubbed; no headers/bodies sent.
      def patch_net_http
        return unless defined?(Net::HTTP)
        return if Net::HTTP.method_defined?(:__restlytics_request)

        query_keys = Restlytics.config.query_keys

        Net::HTTP.class_eval do
          alias_method :__restlytics_request, :request

          define_method(:request) do |req, body = nil, &block|
            tracer = Restlytics.tracer
            unless tracer && tracer.sampled? && started?
              return __restlytics_request(req, body, &block)
            end

            start_ns = tracer.now_ns
            response = __restlytics_request(req, body, &block)
            begin
              end_ns = tracer.now_ns
              host = address
              scheme = use_ssl? ? "https" : "http"
              raw_path = req.respond_to?(:path) ? req.path.to_s : "/"
              full = "#{scheme}://#{host}#{raw_path}"

              span = tracer.add_child_span("http #{host}", start_ns, end_ns)
              if span
                method = req.respond_to?(:method) ? req.method.to_s : "GET"
                span.set_string("http.request.method", method)
                span.set_string("url.full", Restlytics::Redact.url(full, query_keys))
                span.set_string("server.address", host.to_s)
                if response.respond_to?(:code)
                  span.set_int("http.response.status_code", response.code.to_i)
                end
                span.set_string("restlytics.category", "http")
              end
            rescue StandardError
              # outbound HTTP instrumentation never breaks the call
            end

            response
          end
        end
      rescue StandardError
        # best-effort: if patching fails, outbound HTTP just isn't instrumented
      end
    end
  end

  # URL redaction helper -- strips sensitive keys from a query string for url.full.
  # Keeps the host + path (needed for grouping) but never leaks tokens/secrets.
  # Pure stdlib (URI), no Rails dependency.
  module Redact
    require "uri"

    module_function

    def url(raw, redact_keys)
      uri = URI.parse(raw)
      return raw if uri.query.nil? || uri.query.empty?

      lower = redact_keys.map { |k| k.to_s.downcase }
      pairs = URI.decode_www_form(uri.query)
      scrubbed = pairs.map do |k, v|
        lower.include?(k.to_s.downcase) ? [k, "REDACTED"] : [k, v]
      end
      uri.query = URI.encode_www_form(scrubbed)
      uri.to_s
    rescue StandardError
      raw
    end
  end
end
