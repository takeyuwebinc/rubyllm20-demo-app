module Demos
  # Runs one scenario against its provider and records how it ended.
  #
  # The job itself never retries a call that starts work: every retry would
  # call the provider and pay again. RubyLLM already retries timeouts, rate
  # limits, and server errors inside one run. Waiting on work kept at the
  # provider is different: it only fetches the work's state, which costs
  # nothing, so a failure that may pass is tried again later.
  class RunJob < ApplicationJob
    queue_as :default

    # How long a run waiting on the provider rests before it is tried again.
    RETRY_INTERVAL = 1.minute

    class << self
      # The run a job serialized by Active Job was for, or nil for another job.
      def run_from(serialized_job)
        return unless serialized_job["job_class"] == name

        ActiveJob::Arguments.deserialize(serialized_job["arguments"]).first
      rescue ActiveJob::DeserializationError
        nil
      end

      # Queues the job that tries the run again after RETRY_INTERVAL.
      def retry_later(run)
        set(wait: RETRY_INTERVAL).perform_later(run)
      end

      # Queues again or fails the runs of the given Solid Queue jobs, which a
      # dead worker had claimed and Solid Queue will not run again.
      def recover_abandoned(solid_queue_job_ids, error = nil)
        runs = SolidQueue::Job.where(id: solid_queue_job_ids, class_name: name).filter_map { |job| run_from(job.arguments) }
        Run.recover_abandoned!(runs.map(&:id), message: error&.message)
      end
    end

    # A run waiting for approval is left alone: the decision queues the job
    # that continues it.
    def perform(run)
      return if run.finished? || run.awaiting_approval?

      scenario = run.scenario or raise ArgumentError, "Scenario #{run.scenario_key} is not defined"
      # A run continues from what it kept of where it got to: the chat that
      # stopped for approval, whose records hold how far it got, or the ID of
      # the work it left with the provider. Either is safe however often the
      # job runs. A chat, when there is one, is what the run stopped on.
      handle = run.chat_id ? Chat.find(run.chat_id) : run.remote_job_id
      # Solid Queue puts a job back in the queue when its worker stops
      # gracefully. A scenario that must not start over, and has nothing to
      # continue from, has nothing to go on with.
      if run.started_at && !scenario.retryable && !handle
        run.fail_as!(FailureKinds::INTERRUPTED)
        return
      end

      # A continued run keeps its started_at: it tells a job that ran again
      # from a first run, and dates the links to the run's traces.
      run.update!(started_at: Time.current) unless handle
      outcome = RubyLLM.workflow(workflow_name(scenario), metadata: { conversation_id: run.conversation_id }) do
        record_trace(run)
        handle ? scenario.resume(handle) : start(run, scenario)
      end
      record(run, outcome)
    rescue StandardError => error
      record_failure(run, error)
    end

    private

    def workflow_name(scenario)
      "#{scenario.demo&.name}: #{scenario.name}"
    end

    # A scenario that leaves work with the provider hands back the work, and
    # its ID is kept before the wait, so that a job that runs again waits for
    # the same work. Until the ID is kept, a job put back has nothing to
    # continue from, and the work it started goes unused.
    def start(run, scenario)
      started = scenario.perform(run.input)
      return started unless remote_work?(started)

      run.keep_remote_job_id!(started.id)
      scenario.resume(started.id)
    end

    # Work kept at the provider is told by what it can do rather than by its
    # class, as RubyLLM's ResearchJob has an id and knows whether it is
    # still pending.
    def remote_work?(value)
      value.respond_to?(:id) && value.respond_to?(:pending?)
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

    # Cancellation, expiry, and trying again are what the provider answered,
    # not bugs of this app, so none of them is reported. Only a run waiting
    # on work kept at the provider expires or is tried again: a chat is
    # continued by calling the model, which would pay again.
    def record_failure(run, error)
      waiting_on_provider = run.remote_job_id.present? && run.chat_id.nil?

      if FailureKinds.cancelled?(error)
        run.cancel_with!(error)
      elsif waiting_on_provider && FailureKinds.not_found?(error)
        run.fail_with!(error, kind: FailureKinds::EXPIRED)
      elsif waiting_on_provider && FailureKinds.retry_later?(error) && run.retry_later!(error)
        self.class.retry_later(run)
      else
        run.fail_with!(error)
        # A provider failure is shown on the run page with its likely causes.
        # Only an error that points to a bug in this app is reported.
        unless FailureKinds.provider_call?(error)
          Rails.error.report(error, context: { run_id: run.id, scenario_key: run.scenario_key, conversation_id: run.conversation_id })
        end
      end
    end
  end
end
