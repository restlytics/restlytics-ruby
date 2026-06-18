# frozen_string_literal: true

require_relative "span"

module Restlytics
  # Rack middleware that owns the root SERVER span.
  #
  # It opens the span at the very start of the request, then -- crucially -- uses a
  # Rack body proxy so the span is finalized and flushed AFTER the response body has
  # been fully written to the client (`#close` on the body). That keeps span close,
  # self-time computation, gzip, and the network POST off the request's critical
  # path (the actual POST also runs on a background thread inside the transport).
  #
  # `call` is wrapped so a bug in our own instrumentation can never break a served
  # request -- on any error we fall through to the app untraced.
  class Middleware
    # Minimal Rack BodyProxy: yields each chunk through untouched and runs a
    # callback when the server closes the body (after the response is sent).
    class BodyProxy
      def initialize(body, &on_close)
        @body = body
        @on_close = on_close
      end

      def each(&block)
        @body.each(&block)
      end

      def close
        @body.close if @body.respond_to?(:close)
      ensure
        begin
          @on_close.call
        rescue StandardError
          # Telemetry close must never raise into the server.
        end
      end
    end

    def initialize(app, tracer:, config:)
      @app = app
      @tracer = tracer
      @config = config
    end

    def call(env)
      # Skip ignored paths (health checks, assets, etc.) before any work.
      path = env["PATH_INFO"].to_s
      return @app.call(env) unless should_trace?(path)

      method = env["REQUEST_METHOD"].to_s
      # Continue an incoming distributed trace if the upstream sent traceparent.
      traceparent = env["HTTP_TRACEPARENT"]

      # Provisional name; the real http.route template isn't known until routing
      # has resolved, so we finalize the name + route attribute after the app runs.
      begin
        @tracer.start_server_span("#{method} #{path}", traceparent)
      rescue StandardError
        # If we somehow fail to start, run the app untraced.
        return @app.call(env)
      end

      status, headers, body = @app.call(env)

      # Finalize on body close (after the response is flushed). If the tracer isn't
      # sampling we still need to reset to avoid leaking state on this thread.
      unless @tracer.sampled?
        @tracer.reset
        return [status, headers, body]
      end

      route = route_template(env, path)
      finisher = lambda do
        finalize(method, route, status)
      end

      [status, headers, BodyProxy.new(body, &finisher)]
    rescue StandardError
      # Never let telemetry break the host app. Best-effort cleanup and re-run
      # the app untraced if we hadn't yet.
      begin
        @tracer.reset
      rescue StandardError
        # give up silently
      end
      @app.call(env)
    end

    private

    def finalize(method, route, status)
      root = @tracer.root_span
      if root.nil?
        @tracer.reset
        return
      end

      status_i = status.to_i
      root.set_name("#{method} #{route}")
      root.set_string("http.request.method", method)
      root.set_string("http.route", route)
      root.set_int("http.response.status_code", status_i)

      # Crash & error detection: 5xx (and unset-status) become ERROR.
      if status_i >= 500
        root.set_status(Span::STATUS_ERROR, "HTTP #{status_i}") if root.status_code != Span::STATUS_ERROR
      elsif root.status_code == Span::STATUS_UNSET
        root.set_status(Span::STATUS_OK)
      end

      @tracer.finish_server_span
    rescue StandardError
      begin
        @tracer.reset
      rescue StandardError
        # give up silently
      end
    end

    # http.route MUST be the TEMPLATE (e.g. /users/{id}), never the raw URL, so
    # high-cardinality ids don't explode the grouping. Rails exposes the matched
    # route pattern via request.route_uri_pattern (Rails 7+); fall back to the
    # ActionDispatch routing env, then to the raw path for unrouted requests.
    def route_template(env, path)
      template = rails_route_template(env)
      template = path if template.nil? || template.empty?
      template
    rescue StandardError
      path
    end

    def rails_route_template(env)
      # Rails 7 stores the matched route on the request; build one if ActionDispatch
      # is present. We avoid a hard dependency on Rails by probing dynamically.
      if defined?(ActionDispatch::Request)
        req = ActionDispatch::Request.new(env)
        if req.respond_to?(:route_uri_pattern) && req.route_uri_pattern
          return normalize_template(req.route_uri_pattern)
        end
      end

      # Some Rails versions expose the matched pattern in the routing env.
      route = env["action_dispatch.route_uri_pattern"]
      route ? normalize_template(route) : nil
    end

    # Rails route patterns look like "/users/:id(.:format)". Strip the optional
    # format segment and convert :id -> {id} to match the cross-SDK template style.
    def normalize_template(pattern)
      p = pattern.to_s.sub(/\(\.:format\)\z/, "")
      p = p.gsub(/:(\w+)/) { "{#{Regexp.last_match(1)}}" }
      p.empty? ? "/" : p
    end

    def should_trace?(path)
      normalized = "/#{path.sub(%r{\A/+}, '')}"
      @config.ignore_paths.none? { |pattern| path_matches?(normalized, pattern.to_s) }
    end

    # Support exact matches and trailing `*` wildcards (e.g. /assets/*).
    def path_matches?(path, pattern)
      pattern = "/#{pattern.sub(%r{\A/+}, '')}"
      if pattern.end_with?("*")
        prefix = pattern[0..-2]
        path.start_with?(prefix)
      else
        path == pattern
      end
    end
  end
end
