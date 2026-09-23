module Demos
  # Runs one scenario against its provider and records how it ended.
  #
  # The job itself never retries a call that starts work: every retry would
  # call the provider and pay again. RubyLLM already retries timeouts, rate
  # limits, and server errors inside one run. Waiting on, or checking on,
  # work kept at the provider is different: it only fetches the work's
  # state, which costs nothing, so a failure that may pass is tried again
  # later.
  class RunJob < ApplicationJob
    queue_as :default

    # How long a run waiting on the provider rests before it is tried again.
    RETRY_INTERVAL = 1.minute

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

      # Queues the job that tries the run again after RETRY_INTERVAL.
      def retry_later(run)
        set(wait: RETRY_INTERVAL).perform_later(run)
      end

      # Hands the runs of the given Solid Queue jobs, which a dead worker had
      # claimed and Solid Queue will not run again, to the run to fail or to
      # queue again.
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
      # hold how far it got, so this is safe however often the job runs. A
      # run that left work with the provider waits for it by the id it
      # keeps, which is just as safe.
      chat = Chat.find(run.chat_id) if run.chat_id
      continued = chat || run.remote_job_id
      # Work the scenario checks on rather than waits for, such as a batch,
      # is checked on and collected outside the workflow that started it.
      return continue_remote_job(run, scenario) if run.remote_job_id && !chat && scenario.checks_remote_job?

      # Solid Queue puts a job back in the queue when its worker stops
      # gracefully. A scenario that must not start over, and has neither a
      # chat to continue nor work to wait for, has nothing to go on with.
      if run.started_at && !scenario.retryable && !continued
        run.fail_as!(FailureKinds::INTERRUPTED)
        return
      end

      # A continued run keeps its started_at: it tells a job that ran again
      # from a first run, and dates the links to the run's traces.
      run.update!(started_at: Time.current) unless continued
      # One workflow per job, so a run that is not interrupted leaves its
      # work with the provider and collects it in one trace. A job that runs
      # again adds a trace of its own to the same conversation.
      outcome = in_workflow(run, scenario) do
        record_trace(run)
        run_scenario(run, scenario, chat)
      end
      record(run, scenario, outcome)
    rescue StandardError => error
      record_failure(run, error)
    end

    private

    def in_workflow(run, scenario, &)
      RubyLLM.workflow(workflow_name(scenario), metadata: { conversation_id: run.conversation_id }, &)
    end

    # Work left with the provider is waited for in this job, right after its
    # id is kept. Waiting with RubyLLM.animate would keep no id, so a result
    # that finished while the app was down could not be collected. Checking
    # from a job scheduled every so often would open a workflow, and a trace,
    # for every check, where waiting here keeps a run in one trace unless it
    # is interrupted. The wait holds one of the worker's threads for as long
    # as the work takes.
    def run_scenario(run, scenario, chat)
      return scenario.resume(chat) if chat
      return scenario.resume_remote_job(run.remote_job_id) if run.remote_job_id

      outcome = scenario.perform(run.input)
      return outcome unless remote_job?(outcome)
      # Work the scenario checks on is handed back as it is, to be kept and
      # checked on by later jobs.
      return outcome if scenario.checks_remote_job?

      # Kept before waiting, so that a job stopped while it waits goes on
      # from the id instead of leaving the work, and paying for it, again.
      run.record_remote_job_id!(outcome.id)
      scenario.resume_remote_job(outcome.id)
    end

    # Work left with the provider, such as RubyLLM's VideoJob, ResearchJob,
    # and Batch, told apart by what it answers to rather than by its class,
    # as a generated file is by to_blob and mime_type. A result is a Hash
    # and a chat has no status, so neither is mistaken for one.
    def remote_job?(outcome)
      outcome.respond_to?(:id) && outcome.respond_to?(:status)
    end

    # Checks on the work outside any workflow: a check every minute, for as
    # long as a day, would otherwise leave a trace each time. The work is
    # collected, inside the workflow, once it has ended, however it ended:
    # an expired or cancelled batch keeps the part the provider finished,
    # and an expired one bills it. The trace of a collection is recorded
    # only once it got through, as a failed one is tried again a minute
    # later.
    def continue_remote_job(run, scenario)
      state = scenario.check_remote_job(run.remote_job_id)
      run.record_remote_check!(state)
      return check_later(run) if state.pending?

      result = in_workflow(run, scenario) { scenario.collect_remote_job(run.remote_job_id).tap { record_trace(run) } }
      finish_remote_job(run, state, result)
    rescue StandardError => error
      raise unless FailureKinds.provider_call?(error)

      carry_over(run, error)
    end

    # A provider the run cannot reach now may be reachable a minute later:
    # RubyLLM's own retries are over within about a second, while the work
    # goes on at the provider regardless, and checking and collecting it
    # again are safe. Past the run's deadline, it gives up with the error.
    # The deadline is a time rather than the count of retries a waited-for
    # run has: a batch is checked on every minute for up to a day, so a
    # count would be reached by a short outage.
    def carry_over(run, error)
      if run.remote_job_overdue?
        run.fail_with!(error)
      else
        run.record_remote_check_failure!(error)
        check_later(run)
      end
    end

    # Each check is a job of its own, scheduled a minute later rather than
    # a wait inside one job: a batch may take a day, and the schedule is
    # kept in Solid Queue's database, so a batch that ended while the app
    # was stopped is collected by the first check after it starts. The run
    # page's polling would stop once the reader left the page. Two checks
    # of one run run at once only when a worker stops between scheduling
    # the next check and finishing its job; a collection is not guarded
    # against that, as the window is small.
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

    def workflow_name(scenario)
      "#{scenario.demo&.name}: #{scenario.name}"
    end

    # A span is open only while its instrumented block runs, so the trace
    # exists only inside the workflow. Without tracing there is none to keep.
    def record_trace(run)
      span_context = OpenTelemetry::Trace.current_span.context
      run.add_trace_id!(span_context.hex_trace_id) if span_context.valid?
    end

    # A scenario hands back its result, the chat it stopped on for a
    # person's approval, or the work it left with a provider to be checked
    # on. What to keep of each, such as the files a result holds, is the
    # run's to decide; the job only hands it over.
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
