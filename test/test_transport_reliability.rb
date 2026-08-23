# frozen_string_literal: true

require "minitest/autorun"
require "restlytics/transport"

class TransportReliabilityTest < Minitest::Test
  class BlockingTransport < Restlytics::HttpTransport
    def initialize(gate:, **options)
      @gate = gate
      super(**options)
    end

    private

    def post(_url, _body)
      @gate.pop
      true
    end
  end

  class FailingTransport < Restlytics::HttpTransport
    attr_reader :attempts

    def initialize(**options)
      @attempts = 0
      super(**options)
    end

    private

    def post(_url, _body)
      @attempts += 1
      raise Net::ReadTimeout, "simulated hard timeout"
    end
  end

  def test_send_is_non_blocking_bounded_observable_and_flushable
    gate = Queue.new
    errors = []
    transport = BlockingTransport.new(
      gate: gate,
      ingest_url: "http://ingest.test",
      key: "rl_test",
      queue_capacity: 4,
      on_error: errors.method(:push)
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    10.times { transport.send_payload({}) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.25
    snapshot = transport.diagnostics
    assert_operator snapshot[:accepted_batches], :<=, 5
    assert_operator snapshot[:dropped_batches], :>=, 5
    assert_equal 4, snapshot[:queue_capacity]
    assert errors.any? { |message| message.include?("queue is full") }

    snapshot[:accepted_batches].times { gate.push(true) }
    assert transport.close(timeout_ms: 2000)
    assert_equal snapshot[:accepted_batches], transport.diagnostics[:delivered_batches]
    transport.send_payload({})
    assert_equal snapshot[:dropped_batches] + 1, transport.diagnostics[:dropped_batches]
  end

  def test_timeout_is_counted_swallowed_and_never_retried
    transport = FailingTransport.new(ingest_url: "http://ingest.test", key: "rl_test")
    transport.send_payload({})
    assert transport.flush(timeout_ms: 1000)
    assert_equal 1, transport.attempts
    assert_equal 1, transport.diagnostics[:failed_batches]
    assert_equal 0, transport.diagnostics[:delivered_batches]
    assert transport.close
  end
end
