# frozen_string_literal: true

require_relative "ids"
require_relative "span"
require_relative "intervals"
require_relative "otlp"

module Restlytics
  # Per-request tracer. Unlike the Laravel singleton model, Ruby web servers
  # (Puma/Unicorn) serve concurrent requests on threads, so ALL per-request state
  # lives in a fiber/thread-local "state" object. One Tracer instance is shared by
  # the whole process; each request gets its own isolated State.
  #
  # The State holds the active trace id, the root SERVER span, and the in-request
  # span buffer. The Tracer owns the sampling decision and, on finish, computes the
  # self-time rollups and flushes the OTLP batch through the transport.
  #
  # Timing model: we use Process.clock_gettime(:MONOTONIC) for DURATIONS -- it isn't
  # affected by NTP/clock adjustments -- and anchor it to a single wall-clock reading
  # (Process.clock_gettime(:REALTIME)) so we can emit absolute epoch-nanosecond
  # timestamps. Each span's absolute start is wall_anchor + (mono_now - mono_anchor).
  class Tracer
    # Thread/fiber-local key. Using a thread variable keyed by name keeps each
    # request's state isolated even under threaded servers and Fiber schedulers.
    STATE_KEY = :__restlytics_state__

    # Per-request mutable state. A fresh one is created per request and discarded
    # at the end -- there is no cross-request reuse to leak.
    class State
      attr_accessor :enabled, :sampled, :trace_id, :root_parent_span_id,
                    :root_span, :spans, :wall_anchor_ns, :mono_anchor_ns,
                    :db_query_count

      def initialize
        @enabled = false
        @sampled = false
        @trace_id = ""
        @root_parent_span_id = nil
        @root_span = nil
        @spans = []
        @wall_anchor_ns = 0
        @mono_anchor_ns = 0
        @db_query_count = 0
      end
    end

    def initialize(transport:, service_name:, environment:, sample_rate: 1.0, max_spans: 2000)
      @transport = transport
      @service_name = service_name
      @environment = environment
      @sample_rate = sample_rate.to_f
      @max_spans = max_spans.to_i
    end

    # Clear per-request state. Called at request end so nothing lingers on the
    # thread for the next request it serves.
    def reset
      Thread.current[STATE_KEY] = nil
    end

    def sampled?
      st = state
      st && st.enabled && st.sampled
    end

    def trace_id
      state&.trace_id
    end

    def root_span
      state&.root_span
    end

    def root_span_id
      state&.root_span&.span_id
    end

    # Open the root SERVER span at request start.
    #
    # Continues an incoming W3C traceparent if present (distributed tracing),
    # otherwise mints a fresh trace id. The sampling decision is HEAD-BASED and
    # made exactly once here, keyed off the trace id, so all spans in a trace share
    # the same fate (and a continued trace inherits the upstream sampled flag).
    def start_server_span(name, traceparent = nil)
      st = State.new
      Thread.current[STATE_KEY] = st
      st.enabled = true

      incoming = Ids.parse_traceparent(traceparent)
      if incoming
        st.trace_id = incoming[:trace_id]
        st.root_parent_span_id = incoming[:parent_span_id]
        # Respect an upstream "not sampled" decision; only re-roll if it was sampled.
        st.sampled = incoming[:sampled] && sample_decision(st.trace_id)
      else
        st.trace_id = Ids.trace_id
        st.root_parent_span_id = nil
        st.sampled = sample_decision(st.trace_id)
      end

      # Anchor wall-clock <-> monotonic clocks together.
      st.wall_anchor_ns = wall_clock_ns
      st.mono_anchor_ns = mono_ns

      return unless st.sampled # not sampled: stay cheap, record nothing

      st.root_span = Span.new(
        trace_id: st.trace_id,
        span_id: Ids.span_id,
        parent_span_id: st.root_parent_span_id,
        name: name,
        kind: Span::KIND_SERVER,
        start_unix_nano: now_ns,
        end_unix_nano: now_ns
      )
    end

    # Create a CLIENT child span over an absolute [start_ns, end_ns] window.
    #
    # DB/HTTP/cache instrumentation often only learns of a span AFTER it finished
    # (e.g. sql.active_record reports elapsed time), so callers back-date the start.
    # Returns nil when not sampled or when the buffer cap is hit (telemetry must
    # never grow unbounded).
    def add_child_span(name, start_ns, end_ns, kind = Span::KIND_CLIENT)
      st = state
      return nil unless st && st.enabled && st.sampled && st.root_span
      return nil if st.spans.length >= @max_spans

      span = Span.new(
        trace_id: st.trace_id,
        span_id: Ids.span_id,
        parent_span_id: st.root_span.span_id,
        name: name,
        kind: kind,
        start_unix_nano: start_ns,
        end_unix_nano: end_ns
      )
      st.spans << span
      span
    end

    def increment_db_query_count
      st = state
      st.db_query_count += 1 if st
    end

    # Close the root span, compute self-time rollups, and flush the batch.
    #
    # Self-time = interval-union of child spans per category (db/http/cache), and
    # app = root duration - union(ALL children). We attach these to the root SERVER
    # span as restlytics.self_ns.* so the dashboard's time breakdown is correct even
    # when children overlap.
    def finish_server_span
      st = state
      unless st && st.enabled && st.sampled && st.root_span
        reset
        return
      end

      st.root_span.set_end(now_ns)

      attach_self_time(st)
      st.root_span.set_int("restlytics.db_query_count", st.db_query_count)
      st.root_span.set_string("restlytics.category", "app")

      flush(st)
      reset
    end

    # Build the OTLP payload and hand it to the transport (fire-and-forget).
    # Resilient: any failure is swallowed so flushing telemetry can't break the app.
    def flush(st = state)
      return if st.nil? || st.root_span.nil?

      all = [st.root_span] + st.spans
      payload = Otlp.build(@service_name, @environment, all)
      @transport.send_payload(payload)
    rescue StandardError
      # Telemetry must never raise into the host application.
      nil
    end

    # Absolute current time in epoch nanoseconds, derived from the monotonic clock
    # so durations are immune to wall-clock jumps mid-request.
    def now_ns
      st = state
      return wall_clock_ns unless st

      st.wall_anchor_ns + (mono_ns - st.mono_anchor_ns)
    end

    private

    def state
      Thread.current[STATE_KEY]
    end

    # Compute and attach restlytics.self_ns.{db,http,cache,app} to the root span.
    def attach_self_time(st)
      root_span = st.root_span
      return if root_span.nil?

      root_start = root_span.start_unix_nano
      root_dur = root_span.duration_ns

      by_cat = { "db" => [], "http" => [], "cache" => [], "app" => [] }
      all = []

      st.spans.each do |s|
        # Normalize to offsets from root start; clamp inverted intervals (skew).
        start = s.start_unix_nano - root_start
        finish = s.end_unix_nano - root_start
        finish = start if finish < start
        all << [start, finish]

        cat = category_of(s)
        by_cat[cat] << [start, finish]
      end

      self_db = Intervals.union_length(by_cat["db"])
      self_http = Intervals.union_length(by_cat["http"])
      self_cache = Intervals.union_length(by_cat["cache"])
      # app self-time = explicit app-category child time + the root's own exclusive
      # (uncovered) time. Mirrors the ingestion service's computation.
      app_uncovered = root_dur - Intervals.union_length(all)
      app_uncovered = 0 if app_uncovered.negative?
      self_app = Intervals.union_length(by_cat["app"]) + app_uncovered

      root_span.set_int("restlytics.self_ns.db", self_db)
      root_span.set_int("restlytics.self_ns.http", self_http)
      root_span.set_int("restlytics.self_ns.cache", self_cache)
      root_span.set_int("restlytics.self_ns.app", self_app)
    end

    # Read a span's restlytics.category attribute for self-time bucketing.
    # Falls back to 'app' so an uncategorized child still contributes sensibly.
    def category_of(span)
      cat = span.attr_string("restlytics.category")
      %w[db http cache app].include?(cat) ? cat : "app"
    end

    # Head-based trace-id-ratio sampling. Deterministic in the trace id so the
    # decision is stable and unbiased: hash the id into [0,1) and keep it if it
    # falls under the configured rate.
    def sample_decision(trace_id)
      return true if @sample_rate >= 1.0
      return false if @sample_rate <= 0.0

      # Use the last 8 hex chars (32 bits) as the entropy source.
      tail = trace_id[-8, 8] || "0"
      bucket = tail.to_i(16) # 0 .. 2^32-1
      ratio = bucket.to_f / 0xFFFFFFFF
      ratio < @sample_rate
    end

    def mono_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    # Wall-clock epoch nanoseconds (nanosecond resolution).
    def wall_clock_ns
      Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    end
  end
end
