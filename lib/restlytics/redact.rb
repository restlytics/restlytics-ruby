# frozen_string_literal: true

require "uri"

module Restlytics
  # Fail-closed privacy boundary shared by every framework integration.
  module Redact
    SENSITIVE_SEGMENTS = %w[
      authorization auth cookie cookies setcookie password passwd secret token
      accesstoken refreshtoken apikey credential credentials body payload form
      stack stacktrace log
    ].freeze

    module_function

    def sensitive_attribute_key?(key)
      normalized = key.to_s.strip.downcase.tr("-_", "..")
      return false if %w[
        http.request.method http.response.status.code restlytics.bindings.count
      ].include?(normalized)

      normalized.split(".").any? { |segment| SENSITIVE_SEGMENTS.include?(segment) }
    end

    # Remove credentials/fragments and redact every query value. redact_keys is
    # retained for config compatibility; unknown keys are equally safe.
    def url(raw, _redact_keys = [])
      uri = URI.parse(raw)
      uri.user = nil if uri.respond_to?(:user=)
      uri.password = nil if uri.respond_to?(:password=)
      uri.fragment = nil
      unless uri.query.nil? || uri.query.empty?
        pairs = URI.decode_www_form(uri.query)
        uri.query = URI.encode_www_form(pairs.map { |key, _value| [key, "REDACTED"] })
      end
      uri.to_s
    rescue StandardError
      clean = raw.to_s.split(/[?#]/, 2).first.to_s
      clean.sub(%r{\A(https?://)[^/@]+@}i, "\\1")
    end

    # Exception content is intentionally omitted; Restlytics is not a crash tracker.
    def exception_message(_message)
      nil
    end
  end
end
