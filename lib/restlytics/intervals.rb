# frozen_string_literal: true

module Restlytics
  # Interval-union (sweep-line) helper used to compute per-category "self time".
  #
  # Why union and not a plain sum: child spans can overlap (parallel HTTP calls,
  # async queries, nested instrumentation). Summing their durations double-counts
  # the wall-clock time. The union of intervals gives the real wall-clock time
  # actually spent inside that category, which is what the dashboard breakdown and
  # the ingestion service's self-time rollups expect.
  #
  # We work in plain integer nanoseconds. Ruby integers are arbitrary precision,
  # so durations within a single request comfortably fit.
  module Intervals
    module_function

    # Total wall-clock length covered by the union of [start, end] intervals.
    #
    # @param intervals [Array<Array(Integer, Integer)>] pairs of [start_ns, end_ns]
    # @return [Integer]
    def union_length(intervals)
      return 0 if intervals.nil? || intervals.empty?

      # Sort by start so a single forward sweep can merge overlaps.
      sorted = intervals.sort_by { |iv| iv[0] }

      total = 0
      cur_start, cur_end = sorted[0]

      sorted.each_with_index do |iv, i|
        next if i.zero?

        s, e = iv
        if s > cur_end
          # Disjoint: bank the current run and start a new one.
          total += cur_end - cur_start
          cur_start = s
          cur_end = e
        elsif e > cur_end
          # Overlapping: extend the current run.
          cur_end = e
        end
      end

      total + (cur_end - cur_start)
    end
  end
end
