# frozen_string_literal: true

require "securerandom"

module Restlytics
  # Trace / span id generation and W3C traceparent handling.
  #
  # OTLP/JSON wants lowercase-hex ids: 32 chars (16 bytes) for a trace id,
  # 16 chars (8 bytes) for a span id. The ingestion contract additionally
  # rejects all-zero ids, so we make sure the random bytes are never empty.
  module Ids
    ALL_ZERO = /\A0+\z/.freeze

    # 00-<32hex>-<16hex>-<2hex>
    TRACEPARENT = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/.freeze

    module_function

    # 32 lowercase hex chars (16 random bytes), never all-zero.
    def trace_id
      random_hex(16)
    end

    # 16 lowercase hex chars (8 random bytes), never all-zero.
    def span_id
      random_hex(8)
    end

    # SecureRandom is cryptographically secure and always available in stdlib.
    # The all-zero probability is negligible, but the contract forbids it, so guard.
    def random_hex(bytes)
      hex = SecureRandom.hex(bytes)
      hex = SecureRandom.hex(bytes) while ALL_ZERO.match?(hex)
      hex
    end

    # Parse a W3C `traceparent` header into a hash.
    #
    # Format: `version-traceid-spanid-flags`, e.g.
    #   00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
    #
    # Returns nil when absent or malformed so the caller falls back to a fresh
    # trace. Continuing an incoming traceparent lets a single distributed trace
    # stitch together across services (e.g. an upstream gateway -> this Rails app).
    #
    # @return [Hash, nil] { trace_id:, parent_span_id:, sampled: } or nil
    def parse_traceparent(header)
      return nil if header.nil? || header.empty?

      m = TRACEPARENT.match(header.to_s.strip.downcase)
      return nil unless m

      trace_id = m[2]
      parent_span_id = m[3]

      # Reject the invalid all-zero trace/parent ids per the W3C spec.
      return nil if ALL_ZERO.match?(trace_id) || ALL_ZERO.match?(parent_span_id)

      {
        trace_id: trace_id,
        parent_span_id: parent_span_id,
        # low bit of the flags byte is the "sampled" flag
        sampled: (m[4].to_i(16) & 0x01) == 0x01
      }
    end

    # Build a W3C `traceparent` value for outbound injection (optional).
    def traceparent(trace_id, span_id, sampled)
      format("00-%s-%s-%02x", trace_id, span_id, sampled ? 1 : 0)
    end
  end
end
