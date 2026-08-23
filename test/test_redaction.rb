# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "restlytics/span"
require "restlytics/redact"

class TestRedaction < Minitest::Test
  def test_url_removes_credentials_fragment_and_every_query_value
    value = Restlytics::Redact.url(
      "https://alice:password@example.test/orders?token=abc&unknown=customer-secret#raw",
      ["token"]
    )

    %w[alice password abc customer-secret raw].each do |secret|
      refute_includes value, secret
    end
  end

  def test_span_boundary_drops_content_bearing_fields
    span = Restlytics::Span.new(
      trace_id: "a" * 32,
      span_id: "b" * 16,
      parent_span_id: nil,
      name: "GET /users/{id}",
      kind: Restlytics::Span::KIND_SERVER,
      start_unix_nano: 1,
      end_unix_nano: 2
    )
    span.set_string("http.request.method", "GET")
        .set_string("http.request.header.authorization", "Bearer abc.def.ghi")
        .set_string("rails.request.body", "password=hunter2")
        .set_string("log.body", "alice@example.test")
        .set_string("url.full", "https://example.test/?unknown=customer-secret")
        .set_status(Restlytics::Span::STATUS_ERROR,
                    "login failed for alice@example.test password=hunter2")

    payload = span.to_otlp
    encoded = JSON.generate(payload)
    ["hunter2", "alice@example.test", "customer-secret", "authorization"].each do |secret|
      refute_includes encoded, secret
    end
    refute payload.fetch("status").key?("message")
    assert Restlytics::Redact.sensitive_attribute_key?("rack.request.payload")
    refute Restlytics::Redact.sensitive_attribute_key?("restlytics.bindings_count")
  end
end
