# Tracing is OpenTelemetry; Sentry receives it over OTLP and also captures
# errors. See docs/api-keys.md for the DSN.
#
# Tests must not send anything: dotenv loads the real DSN in the test
# environment too.
unless Rails.env.test?
  # With no span processor registered, the OpenTelemetry SDK installs an OTLP
  # exporter aimed at localhost:4318. Sentry adds the only exporter we want,
  # after the SDK is configured.
  ENV["OTEL_TRACES_EXPORTER"] ||= "none"

  # The SDK must be configured before Sentry.init: the OTLP integration adds its
  # span processor to the tracer provider that exists at that moment.
  OpenTelemetry::SDK.configure do |config|
    config.service_name = "rubyllm20-demo-app"
    config.logger = Rails.logger
  end

  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"].presence
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

    # Application code reports through Rails.error only, never the Sentry SDK.
    # sentry-rails leaves this subscriber off by default, which would silently
    # drop every Rails.error.report.
    config.rails.register_error_subscriber = true

    # Both default to false in sentry-opentelemetry 7.0. The exporter's endpoint
    # and auth header are derived from the DSN.
    config.otlp.enabled = true
    config.otlp.setup_otlp_traces_exporter = true

    # traces_sample_rate is left unset on purpose. Setting it would turn on
    # Sentry's own tracing beside OpenTelemetry and produce every span twice.
    # OpenTelemetry's default sampler keeps every trace, which agent runs need:
    # sampling drops a whole run, not a fraction of each.
  end

  # Spans are exported in batches on a timer. A short-lived process (a runner
  # script, a job worker shutting down) would exit with spans still queued.
  at_exit { OpenTelemetry.tracer_provider.shutdown }

  # to_prepare runs again on every code reload in development, so the previous
  # subscription is removed first. Otherwise each reload would add one more
  # subscriber and every event would produce duplicate spans.
  ruby_llm_span_subscription = nil
  Rails.application.config.to_prepare do
    ActiveSupport::Notifications.unsubscribe(ruby_llm_span_subscription) if ruby_llm_span_subscription

    ruby_llm_span_subscription = ActiveSupport::Notifications.subscribe(
      /\.ruby_llm\z/,
      Observability::RubyLLMSpanSubscriber.new(
        tracer: OpenTelemetry.tracer_provider.tracer("rubyllm20-demo-app"),
        # Prompts and responses are sent so an agent run can be read in Sentry.
        # The demo data is fictional; never enter real or personal data.
        capture_content: true
      )
    )
  end
end
