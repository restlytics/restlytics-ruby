# frozen_string_literal: true

require "net/http"

require_relative "redact"
require_relative "span"

module Restlytics
  # Best-effort Net::HTTP CLIENT spans with exact W3C context propagation.
  module NetHttpInstrumentation
    module_function

    def install(tracer:, query_keys:)
      return false unless tracer && defined?(Net::HTTP)

      @tracer = tracer
      @query_keys = query_keys
      return true if Net::HTTP.method_defined?(:__restlytics_request)

      Net::HTTP.class_eval do
        alias_method :__restlytics_request, :request

        define_method(:request) do |req, body = nil, &block|
          tracer = NetHttpInstrumentation.tracer
          query_keys = NetHttpInstrumentation.query_keys
          context = tracer.outbound_context
          unless context && started?
            return __restlytics_request(req, body, &block)
          end

          req["traceparent"] = context[:traceparent]
          start_ns = tracer.now_ns
          response = nil
          begin
            response = __restlytics_request(req, body, &block)
          ensure
            begin
              if tracer.sampled?
                finish_ns = tracer.now_ns
                host = address
                scheme = use_ssl? ? "https" : "http"
                raw_path = req.respond_to?(:path) ? req.path.to_s : "/"
                full = "#{scheme}://#{host}#{raw_path}"
                span = tracer.add_child_span(
                  "http #{host}", start_ns, finish_ns, Span::KIND_CLIENT,
                  span_id: context[:span_id]
                )
                if span
                  method = req.respond_to?(:method) ? req.method.to_s : "GET"
                  span.set_string("http.request.method", method)
                  span.set_string("url.full", Redact.url(full, query_keys))
                  span.set_string("server.address", host.to_s)
                  if response.respond_to?(:code)
                    span.set_int("http.response.status_code", response.code.to_i)
                  else
                    span.set_status(Span::STATUS_ERROR)
                  end
                  span.set_string("restlytics.category", "http")
                end
              end
            rescue StandardError
              # Instrumentation must never break the caller.
            end
          end

          response
        end
      end
      true
    rescue StandardError
      false
    end

    def tracer
      @tracer
    end

    def query_keys
      @query_keys || []
    end
  end
end
