# frozen_string_literal: true

require "minitest/autorun"
require "restlytics/tracer"
require "restlytics/transport"

# Head-based sampling contract (SPEC section 3, "decide once per trace").
# A CONTINUED trace inherits the upstream sampled bit verbatim; only a ROOT trace
# rolls locally. Runs with stdlib minitest only -- no gems, no network.
class TestTracerSampling < Minitest::Test
  SAMPLED_TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  UNSAMPLED_TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"

  def setup
    # sample_rate 0.0 => any local roll returns false, so an inherited "sampled"
    # bit can only survive if we truly stopped re-rolling on continuation.
    @tracer = Restlytics::Tracer.new(
      transport: Restlytics::NullTransport.new,
      service_name: "test-service",
      environment: "test",
      sample_rate: 0.0
    )
  end

  def teardown
    # State is thread-local; clear it so tests don't leak into each other.
    @tracer.reset
  end

  def test_continued_trace_inherits_upstream_sampled_bit
    @tracer.start_server_span("GET /users", SAMPLED_TRACEPARENT)

    assert @tracer.sampled?, "continued trace must inherit the upstream sampled bit, not re-roll"
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", @tracer.trace_id
    refute_nil @tracer.root_span
  end

  def test_continued_trace_respects_upstream_not_sampled
    @tracer.start_server_span("GET /users", UNSAMPLED_TRACEPARENT)

    refute @tracer.sampled?, "upstream cleared the sampled bit; we must not sample"
    assert_nil @tracer.root_span
  end

  def test_root_trace_still_rolls_locally
    @tracer.start_server_span("GET /users")

    refute @tracer.sampled?, "root trace with sample_rate 0.0 must not be sampled"
    assert_nil @tracer.root_span
  end
end
