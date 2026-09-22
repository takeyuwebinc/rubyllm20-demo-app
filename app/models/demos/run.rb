module Demos
  # One run of a scenario, kept as history whether it succeeded or failed.
  class Run < ApplicationRecord
    self.strict_loading_by_default = true

    FINISHED = %w[succeeded failed cancelled].freeze

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
      # would otherwise stay running forever. A run waiting for approval has
      # no job, so it is never among them.
      def fail_abandoned!(run_ids, message: nil)
        running.where(id: run_ids).find_each { |run| run.fail_as!(FailureKinds::WORKER_LOST, message:) }
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
    # plays the file back from the attachment.
    #
    # The files are uploaded inside the transaction that records the result,
    # so a failure part way leaves no attachment, no result, and the status
    # as it was. A file already written to the storage may remain there.
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
      fail!(
        "provider" => scenario&.providers&.map { |slug| Demos.provider_name(slug) }&.join("、"),
        "kind" => kind&.name || error.class.name,
        "error_class" => error.class.name,
        "message" => error.message,
        "hint" => kind&.hint
      )
    end

    def fail!(failure)
      update!(status: :failed, failure: failure, finished_at: Time.current)
    end

    # Fails the run for a reason other than a provider call.
    def fail_as!(kind, message: nil)
      fail!("kind" => kind.name, "message" => message, "hint" => kind.hint)
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
      update!(trace_ids: trace_ids + [ trace_id ]) unless trace_ids.include?(trace_id)
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
