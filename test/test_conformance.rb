# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "restlytics/ids"
require "restlytics/otlp"
require "restlytics/span"
require "restlytics/tracer"
require "restlytics/transport"

class TestConformance < Minitest::Test
  FIXTURES = File.expand_path("fixtures/v1", __dir__)

  def test_shared_otlp_propagation_redaction_error_and_sampling_fixture
    fixture = properties
    span = Restlytics::Span.new(
      trace_id: fixture.fetch("trace.id"),
      span_id: fixture.fetch("span.id"),
      parent_span_id: fixture.fetch("span.parent_id"),
      name: fixture.fetch("span.name"),
      kind: fixture.fetch("span.kind").to_i,
      start_unix_nano: fixture.fetch("span.start_ns").to_i,
      end_unix_nano: fixture.fetch("span.end_ns").to_i
    )
    span.set_string(fixture.fetch("attribute.string.key"), fixture.fetch("attribute.string.value"))
        .set_int(fixture.fetch("attribute.int.key"), fixture.fetch("attribute.int.value").to_i)
        .set_bool(fixture.fetch("attribute.bool.key"), fixture.fetch("attribute.bool.value") == "true")
        .set_string(fixture.fetch("redaction.attribute_key"), fixture.fetch("redaction.attribute_value"))
        .set_status(fixture.fetch("error.status_code").to_i, fixture.fetch("error.message"))

    expected_text = File.read(File.join(FIXTURES, "otlp.expected.json"), encoding: "UTF-8")
                        .gsub("${SDK_NAME}", Restlytics::Otlp::SDK_NAME)
                        .gsub("${SDK_LANGUAGE}", Restlytics::Otlp::SDK_LANGUAGE)
                        .gsub("${SDK_VERSION}", Restlytics::Otlp::SDK_VERSION)
    assert_equal JSON.parse(expected_text),
                 Restlytics::Otlp.build(
                   fixture.fetch("service.name"),
                   fixture.fetch("deployment.environment"),
                   [span]
                 )

    sampled = Restlytics::Ids.parse_traceparent(fixture.fetch("propagation.sampled"))
    assert_equal fixture.fetch("trace.id"), sampled.fetch(:trace_id)
    assert_equal fixture.fetch("span.id"), sampled.fetch(:parent_span_id)
    assert sampled.fetch(:sampled)
    refute Restlytics::Ids.parse_traceparent(fixture.fetch("propagation.unsampled")).fetch(:sampled)
    assert_nil Restlytics::Ids.parse_traceparent(fixture.fetch("propagation.invalid"))

    zero = tracer(fixture.fetch("sampling.root_rate_zero").to_f)
    zero.start_server_span("fixture")
    refute zero.sampled?
    zero.reset
    one = tracer(fixture.fetch("sampling.root_rate_one").to_f)
    one.start_server_span("fixture")
    assert one.sampled?
    one.reset
  end

  private

  def properties
    File.readlines(File.join(FIXTURES, "vectors.properties"), chomp: true).to_h do |line|
      line.split("=", 2)
    end
  end

  def tracer(sample_rate)
    Restlytics::Tracer.new(
      transport: Restlytics::NullTransport.new,
      service_name: "fixture",
      environment: "fixture",
      sample_rate: sample_rate
    )
  end
end
