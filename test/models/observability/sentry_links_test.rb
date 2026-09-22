require "test_helper"

module Observability
  class SentryLinksTest < ActiveSupport::TestCase
    DSN = "https://public-key@o1.ingest.us.sentry.io/42".freeze

    setup do
      @links = SentryLinks.new(organization: "example-org", dsn: DSN)
    end

    test "links a trace in the project, around the time it ran" do
      url = @links.trace_url("0af7651916cd43dd8448eb211c80319c", at: Time.utc(2026, 9, 19, 6, 41, 11))

      assert_equal "https://example-org.sentry.io/explore/traces/trace/0af7651916cd43dd8448eb211c80319c/" \
                   "?project=42&timestamp=1789800071", url
    end

    test "links a conversation, searching a little before and after the run" do
      url = @links.conversation_url("run-0123456789abcdef", from: Time.utc(2026, 9, 19, 5, 51, 5), to: Time.utc(2026, 9, 19, 7, 31, 11))

      assert_equal "https://example-org.sentry.io/explore/agents/conversations/run-0123456789abcdef/" \
                   "?end=2026-09-19T07%3A41%3A11.000Z&project=42&start=2026-09-19T05%3A41%3A05.000Z", url
    end

    test "is unavailable without an organization or a DSN" do
      assert_predicate @links, :available?
      refute_predicate SentryLinks.new(organization: nil, dsn: DSN), :available?
      refute_predicate SentryLinks.new(organization: "example-org", dsn: nil), :available?
      refute_predicate SentryLinks.new(organization: "example-org", dsn: "not a dsn"), :available?
    end
  end
end
