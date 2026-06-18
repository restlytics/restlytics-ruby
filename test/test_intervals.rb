# frozen_string_literal: true

require "minitest/autorun"
require "restlytics/intervals"

# Interval-union self-time contract (SPEC section 1). Overlapping child spans must
# not double-count wall-clock time. Runs with stdlib minitest only.
class TestIntervals < Minitest::Test
  U = Restlytics::Intervals

  def test_empty_is_zero
    assert_equal 0, U.union_length([])
  end

  def test_nil_is_zero
    assert_equal 0, U.union_length(nil)
  end

  def test_single_interval
    assert_equal 10, U.union_length([[0, 10]])
  end

  def test_disjoint_intervals_sum
    # [0,10] + [20,25] = 10 + 5
    assert_equal 15, U.union_length([[0, 10], [20, 25]])
  end

  def test_overlapping_intervals_are_unioned_not_summed
    # [0,10] and [5,15] overlap -> union is [0,15] = 15 (NOT 10+10=20).
    assert_equal 15, U.union_length([[0, 10], [5, 15]])
  end

  def test_fully_contained_interval
    # [2,4] inside [0,10] -> just 10.
    assert_equal 10, U.union_length([[0, 10], [2, 4]])
  end

  def test_adjacent_touching_intervals_merge
    # [0,10] and [10,20] touch at 10 -> continuous [0,20] = 20.
    assert_equal 20, U.union_length([[0, 10], [10, 20]])
  end

  def test_unsorted_input_is_handled
    assert_equal 15, U.union_length([[20, 25], [0, 10]])
  end

  def test_multiple_overlaps_chained
    # [0,5],[3,8],[7,12] all chain -> [0,12] = 12.
    assert_equal 12, U.union_length([[0, 5], [3, 8], [7, 12]])
  end

  def test_zero_length_intervals
    # Cache markers are zero-length; they contribute nothing on their own.
    assert_equal 0, U.union_length([[5, 5], [10, 10]])
  end

  def test_large_nanosecond_values
    # Ruby integers are arbitrary precision; epoch-ns values must not overflow.
    base = 1_700_000_000_000_000_000
    assert_equal 1_000, U.union_length([[base, base + 1_000]])
  end
end
