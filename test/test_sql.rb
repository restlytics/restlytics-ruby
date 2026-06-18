# frozen_string_literal: true

require "minitest/autorun"
require "restlytics/sql"

# Mirrors the cross-language SQL normalization contract (SPEC section 5).
# Runs with stdlib minitest only -- no gems, no DB, no network.
class TestSql < Minitest::Test
  N = Restlytics::Sql

  def test_strips_numeric_literals
    assert_equal "select * from users where id = ?",
                 N.normalize("SELECT * FROM users WHERE id = 1")
  end

  def test_strips_string_literals
    assert_equal "select * from users where email = ?",
                 N.normalize("SELECT * FROM users WHERE email = 'alice@example.com'")
  end

  def test_two_different_literals_produce_the_same_template
    # The whole point: id=1 and id=2 must group together (N+1 fingerprint).
    a = N.normalize("SELECT * FROM users WHERE id = 1")
    b = N.normalize("SELECT * FROM users WHERE id = 2")
    assert_equal a, b
  end

  def test_collapses_in_lists_to_single_placeholder
    assert_equal "select * from users where id in (?)",
                 N.normalize("SELECT * FROM users WHERE id IN (1, 2, 3, 4, 5)")

    short = N.normalize("SELECT * FROM users WHERE id IN (1, 2)")
    long = N.normalize("SELECT * FROM users WHERE id IN (1, 2, 3, 4)")
    assert_equal short, long
  end

  def test_collapses_existing_placeholders_and_in_lists
    assert_equal "select * from t where id in (?)",
                 N.normalize("SELECT * FROM t WHERE id IN (?, ?, ?)")
  end

  def test_squashes_whitespace_and_newlines
    assert_equal "select id from users where active = ?",
                 N.normalize("SELECT   id\n  FROM users\n\tWHERE active   =   1")
  end

  def test_collapses_values_tuples
    assert_equal "insert into t (a, b) values (?)",
                 N.normalize("INSERT INTO t (a, b) VALUES (1, 2), (3, 4), (5, 6)")
  end

  def test_handles_named_and_positional_bindings
    assert_equal "select * from users where id = ? and name = ?",
                 N.normalize("SELECT * FROM users WHERE id = :id AND name = $1")
  end

  def test_does_not_mangle_identifiers_with_trailing_digits
    out = N.normalize("SELECT column2 FROM table1 WHERE column2 = 5")
    assert_includes out, "column2"
    assert_includes out, "= ?"
  end

  def test_strips_decimal_and_hex_literals
    assert_equal "select * from t where price > ? and flag = ?",
                 N.normalize("SELECT * FROM t WHERE price > 19.99 AND flag = 0xFF")
  end

  def test_postgres_dollar_placeholders
    assert_equal "select * from users where id = ?",
                 N.normalize("SELECT * FROM users WHERE id = $1")
  end

  def test_never_raises_on_garbage
    # Best-effort normalizer must tolerate anything thrown at it.
    assert_equal "", N.normalize("")
    refute_nil N.normalize("'''unterminated")
  end
end
