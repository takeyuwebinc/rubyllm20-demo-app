module Demos
  # One run of a scenario, kept as history whether it succeeded or failed.
  class Run < ApplicationRecord
    self.strict_loading_by_default = true

    FINISHED = %w[succeeded failed cancelled].freeze

    # How long after the run left work with a provider it keeps waiting for
    # that work. OpenAI ends a batch within 24 hours of its submission,
    # whatever became of it, so a run that still cannot reach its batch
    # after twice that gives up rather than wait forever.
    REMOTE_JOB_DEADLINE = 48.hours

    # A trace of the run, and when it was recorded. Sentry looks a trace up
    # around a given time, and a run that collects work left with a
    # provider records its traces hours or days apart.
    Trace = Data.define(:id, :at)

    # A finished run never changes state, so its result cannot be rewritten
    # after the fact.
    TRANSITIONS = {
      "running" => %w[awaiting_approval succeeded failed cancelled],
      "awaiting_approval" => %w[running failed cancelled]
    }.freeze

    # awaiting_approval and cancelled belong to scenarios that wait for a
    # person's decision or for the provider to finish the work.
    enum :status, {
      running: "running",
      awaiting_approval: "awaiting_approval",
      succeeded: "succeeded",
      failed: "failed",
      cancelled: "cancelled"
    }, validate: true

    # Audio and video a scenario generates, kept with the run so the history
    # can play them back.
    has_many_attached :generated_files

    # chat_id is deliberately not an association: the run forbids loading
    # associations late, and the chat is read by id where it is needed.

    validates :scenario_key, :conversation_id, presence: true
    validate :status_transition, on: :update, if: :will_save_change_to_status?

    before_validation :issue_conversation_id, on: :create

    scope :latest_first, -> { order(created_at: :desc, id: :desc) }
    scope :for_demo, ->(demo) { where(scenario_key: demo.scenarios.map(&:key)) }

    class << self
      # Records a run and queues its job, or returns an unsaved run whose
      # errors say why the scenario cannot run now.
      def start(scenario, given_input)
        run = new(scenario_key: scenario.key, input: scenario.input_values(given_input))
        refuse_unrunnable(run, scenario.availability)
        scenario.blank_required_inputs(run.input).each do |name|
          # A message rather than an error type: generating a message from a
          # type reads the attribute, and the run has no attribute per input.
          run.errors.add(input_error_key(name), "入力してください")
        end
        return run if run.errors.any?

        run.save!
        RunJob.perform_later(run)
        run
      end

      def input_error_key(name)
        :"input.#{name}"
      end

      def transition?(from, to)
        TRANSITIONS.fetch(from, []).include?(to)
      end

      # Solid Queue does not run a dead worker's jobs again, so their runs
      # would otherwise stay running forever. A run that left work with a
      # provider is queued again instead: the work goes on at the provider,
      # checking on it costs nothing, and collecting it again adds no answer
      # twice. Only until the deadline, so that a job that kills its worker
      # every time is not queued forever. A run waiting for approval has no
      # job, so it is never among them.
      def fail_abandoned!(run_ids, message: nil)
        running.where(id: run_ids).find_each do |run|
          if run.remote_job? && !run.remote_job_overdue?
            RunJob.perform_later(run)
          else
            run.fail_as!(FailureKinds::WORKER_LOST, message:)
          end
        end
      end

      private

      def refuse_unrunnable(run, availability)
        if availability.preparing?
          run.errors.add(:base, :preparing, message: "この代表シナリオは準備中である")
        elsif availability.missing_config?
          names = availability.missing_providers.map { |slug| Demos.provider_name(slug) }.join("、")
          run.errors.add(:base, :missing_config, message: "設定値が足りない: #{names}")
        end
      end
    end

    def scenario
      Catalog.scenario(scenario_key)
    end

    def finished?
      FINISHED.include?(status)
    end

    def input_errors(name)
      errors[self.class.input_error_key(name)]
    end

    # Records the result. A value of the result that is a generated file
    # (anything with to_blob and mime_type, such as RubyLLM's Speech, Video,
    # and Image) is kept as an attachment named after its key, and the
    # result keeps a reference to it in its place: the filename, the content
    # type, and the byte size. The result stays plain JSON, and the history
    # plays the file back from the attachment. The bytes themselves are not
    # put in the result: the JSON column would grow by the size of every
    # file, and playing one back would need a route of its own.
    #
    # The reference names the file rather than the attachment's id, so a
    # view finds the file from the result's key alone. A key names one file
    # per run.
    #
    # The files are uploaded inside the transaction that records the result,
    # so a failure part way leaves no attachment, no result, and the status
    # as it was. A file already written to the storage may remain there.
    #
    # A Video or an Image that holds only a URL downloads itself from the
    # provider in to_blob, inside that transaction.
    # TODO(when the product video scenario is implemented): decide whether
    # its handler fetches the video first, keeping the download out of the
    # transaction.
    def succeed!(result)
      refuse_transition!("succeeded")

      transaction do
        blobs = []
        kept = result.to_h do |key, value|
          next [ key, value ] unless generated_file?(value)

          blob = upload_generated_file(key.to_s, value)
          blobs << blob
          [ key, { "filename" => blob.filename.to_s, "content_type" => blob.content_type, "byte_size" => blob.byte_size } ]
        end

        assign_attributes(status: :succeeded, result: kept, finished_at: Time.current)
        generated_files.attach(blobs) if blobs.any?
        save!
      end
    rescue StandardError
      # The rollback undoes what was written, but this object would still
      # hold the result and the pending attachments, and the next save, such
      # as the one that records the failure, would write them.
      reload
      raise
    end

    def fail_with!(error)
      kind = FailureKinds.for(error)
      fail!({
        "provider" => scenario&.providers&.map { |slug| Demos.provider_name(slug) }&.join("、"),
        "kind" => kind&.name || error.class.name,
        "error_class" => error.class.name,
        "message" => error.message,
        "hint" => kind&.hint
      })
    end

    # A failed run may still have a result, such as the part of a batch the
    # provider finished before the batch expired, which was billed.
    def fail!(failure, result: nil)
      refuse_transition!("failed")
      update!(status: :failed, failure: failure, result: result, finished_at: Time.current)
    end

    # Records that the provider cancelled the work the run left with it. The
    # reason is kept where a failure's is, and the part the provider
    # finished before it was cancelled, if any, as the result.
    def cancel!(failure, result: nil)
      refuse_unless_running!
      update!(status: :cancelled, failure: failure, result: result, finished_at: Time.current)
    end

    # Fails the run for a reason other than a provider call.
    def fail_as!(kind, message: nil)
      fail!({ "kind" => kind.name, "message" => message, "hint" => kind.hint })
    end

    # Stops the run until a person decides on the chat's pending tool calls.
    # What was asked is kept with the run, so the history shows it without
    # loading the chat through the scenario's tools, and even after the
    # scenario is gone. A run can stop more than once: requests already
    # kept, and the decisions on them, stay.
    def await_approval!(chat)
      pending = chat.pending_approvals.to_a
      # With nothing to decide, the run could never be continued.
      raise ArgumentError, "Chat #{chat.id} has no tool call awaiting approval" if pending.empty?

      known = approval_requests.map { |request| request["tool_call_id"] }
      added = pending.reject { |call| known.include?(call.tool_call_id) }.map do |call|
        { "tool_call_id" => call.tool_call_id, "name" => call.name, "arguments" => call.arguments, "decision" => nil }
      end
      update!(status: :awaiting_approval, chat_id: chat.id, approval_requests: approval_requests + added)
    end

    def approval_request(tool_call_id)
      approval_requests.find { |request| request["tool_call_id"] == tool_call_id }
    end

    # Keeps the person's decision on one request and continues the run.
    # The decision itself is recorded on the chat by the scenario; this is
    # the copy the history shows.
    def resume!(tool_call_id, decision)
      raise ArgumentError, "Run #{id} has no approval request #{tool_call_id}" unless approval_request(tool_call_id)

      requests = approval_requests.map do |request|
        request["tool_call_id"] == tool_call_id ? request.merge("decision" => decision) : request
      end
      update!(status: :running, approval_requests: requests)
      RunJob.perform_later(self)
    end

    def add_trace_id!(trace_id)
      return if traces.any? { |trace| trace.id == trace_id }

      update!(trace_ids: trace_ids + [ { "id" => trace_id, "at" => Time.current.iso8601(3) } ])
    end

    # A trace kept as a bare id, with no time of its own, is dated by the
    # run's start, or by its creation.
    def traces
      trace_ids.map do |entry|
        entry.is_a?(Hash) ? Trace.new(entry["id"], Time.zone.parse(entry["at"])) : Trace.new(entry, started_at || created_at)
      end
    end

    # Keeps what the run left with a provider, such as a batch, so that a
    # later job can check on it and collect it. +state+ is the work as the
    # scenario reads it (kind, id, provider, raw_status, request_counts).
    # The run stays running meanwhile: the work is under way at the
    # provider, and a run has no status of its own for that.
    #
    # The run keeps the work's id rather than a reference to RubyLLM's own
    # record of it: finding the work by id (RubyLLM::Batch.find) is public,
    # and RubyLLM's tables are not. The last state is kept beside it so the
    # history shows it without asking the provider.
    def keep_remote_job!(state)
      refuse_unless_running!
      update!(remote_job: {
        "kind" => state.kind,
        "id" => state.id,
        "provider" => state.provider,
        "submitted_at" => Time.current.iso8601(3),
        "raw_status" => state.raw_status,
        "request_counts" => state.request_counts,
        "checked_at" => nil,
        "check_failure" => nil
      })
    end

    def remote_job?
      remote_job.present?
    end

    # Keeps what a check on the work found. A check that got through clears
    # the last failed one.
    def record_remote_check!(state)
      refuse_unless_running!
      update!(remote_job: remote_job.merge(
        "raw_status" => state.raw_status,
        "request_counts" => state.request_counts,
        "checked_at" => Time.current.iso8601(3),
        "check_failure" => nil
      ))
    end

    # Keeps why the last check on the work could not reach the provider.
    # What the previous check found stays as it was.
    def record_remote_check_failure!(error)
      refuse_unless_running!
      failure = { "kind" => FailureKinds.for(error)&.name || error.class.name, "message" => error.message, "at" => Time.current.iso8601(3) }
      update!(remote_job: remote_job.merge("check_failure" => failure))
    end

    def remote_job_overdue?(now = Time.current)
      now > Time.zone.parse(remote_job.fetch("submitted_at")) + REMOTE_JOB_DEADLINE
    end

    private

    # Sentry puts the id in a URL path, so it is limited to letters, digits,
    # hyphens, and underscores. The span subscriber also replaces any other
    # character, as a guard for ids that come from elsewhere.
    def issue_conversation_id
      self.conversation_id ||= "run-#{SecureRandom.hex(8)}"
    end

    def status_transition
      from, to = status_change_to_be_saved
      add_transition_error(from, to) unless self.class.transition?(from, to)
    end

    # The validation runs only on save, after anything the change stores
    # beside the run has been written, and only when the status changes, so
    # it lets a succeeded run succeed again. This refuses both up front,
    # with the error the validation would raise.
    def refuse_transition!(to)
      return if self.class.transition?(status, to)

      add_transition_error(status, to)
      raise ActiveRecord::RecordInvalid, self
    end

    # Only a running run has work under way with a provider. The transitions
    # would let a run waiting for approval be cancelled, and a save that
    # leaves the status as it is is not validated at all.
    def refuse_unless_running!
      return if running?

      errors.add(:status, :not_running, message: "が running でない（#{status}）")
      raise ActiveRecord::RecordInvalid, self
    end

    def add_transition_error(from, to)
      errors.add(:status, :invalid_transition, message: "は #{from} から #{to} に変えられない")
    end

    def generated_file?(value)
      value.respond_to?(:to_blob) && value.respond_to?(:mime_type)
    end

    # The generator's content type is kept as given rather than guessed
    # from the bytes.
    def upload_generated_file(key, file)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(file.to_blob), filename: generated_filename(key, file), content_type: file.mime_type, identify: false
      )
    end

    # RubyLLM's Speech names its format; Video and Image have only a MIME
    # type. A MIME type Rails does not know leaves the name without an
    # extension.
    def generated_filename(key, file)
      extension = file.respond_to?(:format) ? file.format : (Mime::Type.lookup(file.mime_type).symbol if file.mime_type.present?)
      [ key, extension.presence ].compact.join(".")
    end
  end
end
