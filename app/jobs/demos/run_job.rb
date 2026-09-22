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

    def perform(run)
      return if run.finished?

      scenario = run.scenario or raise ArgumentError, "Scenario #{run.scenario_key} is not defined"
      # Solid Queue puts a job back in the queue when its worker stops
      # gracefully. Starting over would repeat what the first attempt did.
      # TODO(when the first scenario with retryable: false is implemented):
      # the run is left running here; that scenario decides how to resume or
      # fail it.
      return if run.started_at && !scenario.retryable

      run.update!(started_at: Time.current)
      result = RubyLLM.workflow(workflow_name(scenario), metadata: { conversation_id: run.conversation_id }) do
        record_trace(run)
        scenario.perform(run.input)
      end
      run.succeed!(result)
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
  end
end
