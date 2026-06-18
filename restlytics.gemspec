# frozen_string_literal: true

require_relative "lib/restlytics/version"

Gem::Specification.new do |spec|
  spec.name        = "restlytics"
  spec.version     = Restlytics::VERSION
  spec.authors     = ["restlytics"]
  spec.email       = ["support@restlytics.com"]

  spec.summary     = "Framework-native performance + error tracing for Rails, in OTLP/JSON."
  spec.description = <<~DESC
    restlytics is a zero-config tracing SDK for Rails 7. It emits the shared
    restlytics OTLP/JSON wire format: a root SERVER span per request plus CLIENT
    child spans for DB queries (and optionally outbound HTTP), with per-category
    self-time. Pure Ruby stdlib core (json + zlib + net/http), fire-and-forget
    transport, head-based sampling, and safe-by-default redaction. Rails wiring is
    an integration-time concern -- the gem has no hard runtime gem dependencies.
  DESC

  spec.homepage = "https://github.com/restlytics/restlytics-ruby"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md LICENSE]
  spec.require_paths = ["lib"]

  # No runtime gem dependencies: the core is pure stdlib (json, zlib, net/http,
  # securerandom, uri). `rails` / `activesupport` are integration-time only --
  # the Railtie loads conditionally when Rails is present -- so they are NOT
  # declared as hard runtime deps here.

  # Test/dev tooling is intentionally minimal; the shipped unit tests
  # (test/test_sql.rb, test/test_intervals.rb) run on stdlib minitest alone.
end
