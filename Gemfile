# frozen_string_literal: true

source "https://rubygems.org"

# The gem itself has NO runtime dependencies (pure stdlib core). This Gemfile
# only declares the gemspec so `bundle` resolves the package metadata.
gemspec

# Rails is an INTEGRATION-time dependency, not a runtime one -- the Railtie loads
# conditionally only when Rails is present. Uncomment to develop against Rails
# locally (requires network to install):
#
# group :development, :test do
#   gem "rails", "~> 7.0"
# end
#
# The shipped unit tests (test/test_sql.rb, test/test_intervals.rb) use the
# minitest that ships with Ruby's stdlib, so no extra gems are needed to run them:
#
#   ruby -Ilib -Itest test/test_sql.rb
#   ruby -Ilib -Itest test/test_intervals.rb
