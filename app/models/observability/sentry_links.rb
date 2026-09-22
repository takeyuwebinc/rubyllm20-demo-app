module Observability
  # Links from a run to its traces and its conversation in Sentry. The URL
  # shapes follow the Sentry UI. The organization is not part of the DSN, so
  # it is set on its own; the project id is the last path segment of the DSN.
  class SentryLinks
    # Sentry filters by time. A margin keeps a run's spans inside the range
    # even when the clocks of this machine and Sentry disagree a little.
    MARGIN = 10.minutes

    def self.from_env
      new(organization: ENV["SENTRY_ORG"].presence, dsn: ENV["SENTRY_DSN"].presence)
    end

    def initialize(organization:, dsn:)
      @organization = organization
      @project_id = project_id_from(dsn)
    end

    def available?
      @organization.present? && @project_id.present?
    end

    def trace_url(trace_id, at:)
      url("explore/traces/trace/#{trace_id}/", project: @project_id, timestamp: at.to_i)
    end

    def conversation_url(conversation_id, from:, to:)
      url(
        "explore/agents/conversations/#{conversation_id}/",
        project: @project_id, start: iso8601(from - MARGIN), end: iso8601(to + MARGIN)
      )
    end

    private

    def url(path, query)
      "https://#{@organization}.sentry.io/#{path}?#{query.to_query}"
    end

    def iso8601(time)
      time.utc.iso8601(3)
    end

    def project_id_from(dsn)
      return if dsn.blank?

      uri = URI.parse(dsn)
      uri.path.delete_prefix("/").presence if uri.host
    rescue URI::InvalidURIError
      nil
    end
  end
end
