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

    enum :status, {
      running: "running",
      awaiting_approval: "awaiting_approval",
      succeeded: "succeeded",
      failed: "failed",
      cancelled: "cancelled"
    }, validate: true

    has_many_attached :generated_files

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
          run.errors.add(:"input.#{name}", "入力してください")
        end
        return run if run.errors.any?

        run.save!
        RunJob.perform_later(run)
        run
      end

      def transition?(from, to)
        TRANSITIONS.fetch(from, []).include?(to)
      end

      # Solid Queue does not run a dead worker's jobs again, so their runs
      # would otherwise stay running forever.
      def fail_abandoned!(run_ids, message: nil)
        running.where(id: run_ids).find_each do |run|
          run.fail!(
            "kind" => FailureKinds::WORKER_LOST.name,
            "message" => message,
            "hint" => FailureKinds::WORKER_LOST.hint
          )
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

    def succeed!(result)
      update!(status: :succeeded, result: result, finished_at: Time.current)
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

    def add_trace_id!(trace_id)
      update!(trace_ids: trace_ids + [ trace_id ]) unless trace_ids.include?(trace_id)
    end

    private

    # Sentry puts the id in a URL path, so it is limited to letters, digits,
    # hyphens, and underscores.
    def issue_conversation_id
      self.conversation_id ||= "run-#{SecureRandom.hex(8)}"
    end

    def status_transition
      from, to = status_change_to_be_saved
      errors.add(:status, :invalid_transition, message: "は #{from} から #{to} に変えられない") unless self.class.transition?(from, to)
    end
  end
end
