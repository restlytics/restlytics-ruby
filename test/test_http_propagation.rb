# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "restlytics"

class TestHttpPropagation < Minitest::Test
  SAMPLED = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  UNSAMPLED = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"

  class CaptureTransport < Restlytics::Transport
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def send_payload(payload)
      @payloads << payload
    end
  end

  def setup
    @capture = CaptureTransport.new
    @tracer = Restlytics::Tracer.new(
      transport: @capture,
      service_name: "ruby-test",
      environment: "test",
      sample_rate: 1.0
    )
    Restlytics::NetHttpInstrumentation.install(tracer: @tracer, query_keys: ["token"])
    @requests = []
    @http = Net::HTTP.new("api.example.test", 443)
    @http.use_ssl = true
    requests = @requests
    @http.define_singleton_method(:started?) { true }
    @http.define_singleton_method(:__restlytics_request) do |request, _body = nil, &_block|
      requests << request
      Net::HTTPOK.new("1.1", "200", "OK")
    end
  end

  def teardown
    @tracer.reset
  end

  def test_injects_the_recorded_client_span_context
    @tracer.start_server_span("GET /proxy", SAMPLED)
    response = @http.request(Net::HTTP::Get.new("/orders?token=secret"))
    assert_equal "200", response.code
    @tracer.finish_server_span

    header = @requests[0]["traceparent"]
    assert_match(/\A00-4bf92f3577b34da6a3ce929d0e0e4736-[0-9a-f]{16}-01\z/, header)
    spans = @capture.payloads[0]["resourceSpans"][0]["scopeSpans"][0]["spans"]
    assert_equal header.split("-")[2], spans[1]["spanId"]
    assert_equal spans[0]["spanId"], spans[1]["parentSpanId"]
  end

  def test_propagates_unsampled_context_without_recording
    @tracer.start_server_span("GET /proxy", UNSAMPLED)
    @http.request(Net::HTTP::Get.new("/orders"))
    @tracer.finish_server_span

    assert_match(
      /\A00-4bf92f3577b34da6a3ce929d0e0e4736-[0-9a-f]{16}-00\z/,
      @requests[0]["traceparent"]
    )
    assert_empty @capture.payloads
  end
end
