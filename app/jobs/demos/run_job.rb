module Demos
  # Runs one scenario against its provider and records how it ended.
  #
  # The job itself never retries: every retry would call the provider and pay
  # again. RubyLLM already retries timeouts, rate limits, and server errors
  # inside one run.
  class RunJob < ApplicationJob
    queue_as :default

    class << self
      # The run a job serialized by Active Job was for, or nil for another job.
      def run_from(serialized_job)
        return unless serialized_job["job_class"] == name

        ActiveJob::Arguments.deserialize(serialized_job["arguments"]).first
      rescue ActiveJob::DeserializationError
        nil
      end

      # Fails the runs of the given Solid Queue jobs, which a dead worker had
      # claimed and Solid Queue will not run again.
      def fail_abandoned(solid_queue_job_ids, error = nil)
        runs = SolidQueue::Job.where(id: solid_queue_job_ids, class_name: name).filter_map { |job| run_from(job.arguments) }
        Run.fail_abandoned!(runs.map(&:id), message: error&.message)
      end
    end

    # A run waiting for approval is left alone: the decision queues the job
    # that continues it.
    def perform(run)
      return if run.finished? || run.awaiting_approval?

      scenario = run.scenario or raise ArgumentError, "Scenario #{run.scenario_key} is not defined"
      # A run that stopped for approval continues its chat, whose records
      # hold how far it got, so this is safe however often the job runs.
      chat = Chat.find(run.chat_id) if run.chat_id
      # Solid Queue puts a job back in the queue when its worker stops
      # gracefully. A scenario that must not start over, and has no chat to
      # continue, has nothing to go on with.
      # TODO(when the first scenario that leaves work with the provider is
      # implemented, F4, F6b, or F8): continue from the provider-side record
      # the same way a chat is continued, instead of failing.
      if run.started_at && !scenario.retryable && !chat
        run.fail_as!(FailureKinds::INTERRUPTED)
        return
      end

      # A continued run keeps its started_at: it tells a job that ran again
      # from a first run, and dates the links to the run's traces.
      run.update!(started_at: Time.current) unless chat
      outcome = RubyLLM.workflow(workflow_name(scenario), metadata: { conversation_id: run.conversation_id }) do
        record_trace(run)
        chat ? scenario.resume(chat) : scenario.perform(run.input)
      end
      record(run, outcome)
    rescue StandardError => error
      run.fail_with!(error)
      # A provider failure is shown on the run page with its likely causes.
      # Only an error that points to a bug in this app is reported.
      unless FailureKinds.provider_call?(error)
        Rails.error.report(error, context: { run_id: run.id, scenario_key: run.scenario_key, conversation_id: run.conversation_id })
      end
    end

    private

    def workflow_name(scenario)
      "#{scenario.demo&.name}: #{scenario.name}"
    end

    # A span is open only while its instrumented block runs, so the trace
    # exists only inside the workflow. Without tracing there is none to keep.
    def record_trace(run)
      span_context = OpenTelemetry::Trace.current_span.context
      run.add_trace_id!(span_context.hex_trace_id) if span_context.valid?
    end

    # A scenario hands back its result, or the chat it stopped on for a
    # person's approval. What to keep of either, such as the files a result
    # holds, is the run's to decide; the job only hands it over.
    def record(run, outcome)
      if outcome.is_a?(Chat)
        run.await_approval!(outcome)
      else
        run.succeed!(outcome)
      end
    end
  end
end
