# frozen_string_literal: true

module Restlytics
  # SQL normalization -> a literal-free template string.
  #
  # Two jobs:
  #  1. PII / redaction -- strip every literal so we NEVER ship customer values
  #     (emails, tokens, ids) inside `db.query.summary`. Only the shape survives.
  #  2. N+1 grouping -- collapse the query down to a stable fingerprint so that
  #     `SELECT * FROM users WHERE id = 1` and `... id = 2` map to the same key.
  #     `IN (?, ?, ?)` lists of varying length also collapse to `IN (?)` so a
  #     batched query and its single-row cousin don't fragment the grouping.
  #
  # This is deliberately a best-effort lexical normalizer, not a real SQL parser --
  # it must be fast (runs on every query) and never raise.
  module Sql
    STRING_SINGLE  = /'(?:[^'\\]|\\.|'')*'/m.freeze
    STRING_DOUBLE  = /"(?:[^"\\]|\\.|"")*"/m.freeze
    NAMED_BIND     = /[:$]\w+/.freeze        # :name, $1
    NUMBERED_BIND  = /\?\d+/.freeze          # ?1, ?2 (some drivers)
    HEX_LITERAL    = /\b0x[0-9a-fA-F]+\b/.freeze
    FLOAT_LITERAL  = /\b\d+\.\d+(?:[eE][+-]?\d+)?\b/.freeze
    INT_LITERAL    = /\b\d+\b/.freeze
    IN_LIST        = /\bin\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i.freeze
    VALUES_TUPLES  = /\(\s*\?(?:\s*,\s*\?)*\s*\)(?:\s*,\s*\(\s*\?(?:\s*,\s*\?)*\s*\))+/.freeze
    SINGLE_TUPLE   = /\(\s*\?(?:\s*,\s*\?)+\s*\)/.freeze
    WHITESPACE     = /\s+/.freeze

    module_function

    # Normalize a raw SQL string into a stable, literal-free template.
    def normalize(sql)
      s = sql.to_s

      # Drop string literals: single- and double-quoted, with escaped-quote support.
      # Replace with `?` so they read like positional bindings.
      s = s.gsub(STRING_SINGLE, "?")
      s = s.gsub(STRING_DOUBLE, "?")

      # Normalize existing placeholders FIRST, before numeric stripping -- otherwise
      # the digit in `$1`/`?2` would be eaten by the numeric-literal pass and leave
      # a stray sigil behind.
      s = s.gsub(NAMED_BIND, "?")
      s = s.gsub(NUMBERED_BIND, "?")

      # Drop numeric literals (ints, decimals, scientific, hex). Use word
      # boundaries so we don't mangle identifiers like `column2`.
      s = s.gsub(HEX_LITERAL, "?")
      s = s.gsub(FLOAT_LITERAL, "?")
      s = s.gsub(INT_LITERAL, "?")

      # Collapse `IN (?, ?, ?)` -> `IN (?)` so list length doesn't fragment groups.
      s = s.gsub(IN_LIST, "IN (?)")

      # Collapse multi-row VALUES tuples: (?, ?), (?, ?) -> (?)
      s = s.gsub(VALUES_TUPLES, "(?)")
      s = s.gsub(SINGLE_TUPLE, "(?)")

      # Squash all whitespace runs (incl. newlines) into single spaces, then trim.
      s = s.gsub(WHITESPACE, " ").strip

      # Lowercase so casing differences don't fragment the grouping key.
      s.downcase
    end
  end
end
