module Demos
  # Runs one scenario against its provider and records how it ended.
  #
  # The job itself never retries: every retry would call the provider and pay
  # again. RubyLLM already retries timeouts, rate limits, and server errors
  # inside one run.
  class RunJob < ApplicationJob
    queue_as :default

    # How often a run checks on the work it left with a provider, until the
    # work ends. A batch takes minutes to hours, and a check costs only a
    # request.
    CHECK_INTERVAL = 1.minute

    class << self
      # The run a job serialized by Active Job was for, or nil for another job.
      def run_from(serialized_job)
        return unless serialized_job["job_class"] == name

        ActiveJob::Arguments.deserialize(serialized_job["arguments"]).first
      rescue ActiveJob::DeserializationError
        nil
      end

      # Hands the runs of the given Solid Queue jobs, which a dead worker had
      # claimed and Solid Queue will not run again, to Run.fail_abandoned!,
      # which fails each run or queues its job again.
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
      # Likewise, a run that left work with a provider goes on from that
      # work, whose state the provider holds.
      return continue_remote_job(run, scenario) if run.remote_job? && !chat

      # Solid Queue puts a job back in the queue when its worker stops
      # gracefully. A scenario that must not start over, and has neither a
      # chat nor work with a provider to continue, has nothing to go on with.
      if run.started_at && !scenario.retryable && !chat
        run.fail_as!(FailureKinds::INTERRUPTED)
        return
      end

      # A continued run keeps its started_at: it tells a job that ran again
      # from a first run.
      run.update!(started_at: Time.current) unless chat
      outcome = in_workflow(run, scenario) do
        record_trace(run)
        chat ? scenario.resume(chat) : scenario.perform(run.input)
      end
      record(run, scenario, outcome)
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

    def in_workflow(run, scenario, &)
      RubyLLM.workflow(workflow_name(scenario), metadata: { conversation_id: run.conversation_id }, &)
    end

    # Checks on the work outside any workflow: a check every minute, for as
    # long as a day, would otherwise leave a trace each time. The work is
    # collected, inside the workflow, once it has ended, however it ended:
    # an expired or cancelled batch keeps the part the provider finished,
    # and an expired one bills it. The trace of a collection is recorded
    # only once it got through, as a failed one is tried again a minute
    # later.
    #
    # Only a handler that has .check leaves work that ends on its own time.
    def continue_remote_job(run, scenario)
      state = scenario.check(run.remote_job)
      run.record_remote_check!(state)
      return check_later(run) if state.pending?

      result = in_workflow(run, scenario) { scenario.resume(run.remote_job).tap { record_trace(run) } }
      finish_remote_job(run, state, result)
    rescue StandardError => error
      raise unless FailureKinds.provider_call?(error)

      carry_over(run, error)
    end

    # A provider the run cannot reach now may be reachable a minute later:
    # RubyLLM's own retries are over within about a second, while the work
    # goes on at the provider regardless, and checking and collecting it
    # again are safe. Past the run's deadline, it gives up with the error.
    def carry_over(run, error)
      if run.remote_job_overdue?
        run.fail_with!(error)
      else
        run.record_remote_check_failure!(error)
        check_later(run)
      end
    end

    def check_later(run)
      self.class.set(wait: CHECK_INTERVAL).perform_later(run)
    end

    def finish_remote_job(run, state, result)
      if state.succeeded?
        run.succeed!(result)
      elsif state.cancelled?
        run.cancel!(remote_failure(FailureKinds::REMOTE_JOB_CANCELLED, state), result:)
      else
        run.fail!(remote_failure(FailureKinds::REMOTE_JOB_FAILED, state), result:)
      end
    end

    def remote_failure(kind, state)
      {
        "provider" => Demos.provider_name(state.provider),
        "kind" => kind.name,
        "raw_status" => state.raw_status,
        "message" => "プロバイダーが返した状態: #{state.raw_status}",
        "hint" => kind.hint
      }
    end

    # A span is open only while its instrumented block runs, so the trace
    # exists only inside the workflow. Without tracing there is none to keep.
    def record_trace(run)
      span_context = OpenTelemetry::Trace.current_span.context
      run.add_trace_id!(span_context.hex_trace_id) if span_context.valid?
    end

    # A scenario hands back its result, the chat it stopped on for a
    # person's approval, or the work it left with a provider. What to keep
    # of each, such as the files a result holds, is the run's to decide;
    # the job only hands it over.
    def record(run, scenario, outcome)
      if outcome.is_a?(Chat)
        run.await_approval!(outcome)
      elsif remote_job?(outcome)
        run.keep_remote_job!(scenario.remote_state(outcome))
        check_later(run)
      else
        run.succeed!(outcome)
      end
    end

    # Work left with a provider, such as RubyLLM's Batch, ResearchJob, and
    # VideoJob, has an id to find it by and a status. It is told by those
    # methods rather than by its class, as a generated file is by to_blob
    # and mime_type.
    def remote_job?(outcome)
      outcome.respond_to?(:id) && outcome.respond_to?(:status)
    end
  end
end
