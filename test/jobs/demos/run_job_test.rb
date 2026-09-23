require "test_helper"

module Demos
  class RunJobTest < ActiveSupport::TestCase
    # Stands in for a scenario handler so that no provider is called.
    class FakeHandler
      class << self
        attr_accessor :calls, :outcome, :resumed, :resume_outcome, :checked, :check_outcome, :traced

        def perform(**arguments)
          calls << arguments
          outcome.respond_to?(:call) ? outcome.call : outcome
        end

        # Given the chat of a run that stopped for approval, or the id of
        # the work a run left with the provider.
        def resume(chat_or_id)
          resumed << chat_or_id
          traced << [ :resume, in_span? ]
          resume_outcome.respond_to?(:call) ? resume_outcome.call : resume_outcome
        end

        def check(id)
          checked << id
          traced << [ :check, in_span? ]
          check_outcome.respond_to?(:call) ? check_outcome.call : check_outcome
        end

        private

        def in_span?
          OpenTelemetry::Trace.current_span.context.valid?
        end
      end
    end

    # Answers each question, or each count, with the next scripted answer, in
    # place of a chat with a provider, and keeps the questions it was given.
    class ScriptedChat
      attr_reader :questions

      def initialize(*answers)
        @answers = answers
        @questions = []
      end

      def with_instructions(_instructions) = self
      def with_schema(_schema) = self

      def ask(question)
        @questions << question
        @answers.fetch(@questions.size - 1).call
      end
      alias_method :count_tokens, :ask
    end

    include ActiveJob::TestHelper
    include ScreenHelpers
    include ChatHelpers
    include BatchHelpers

    RESULT = { "tickets" => [ { "text" => "届かない", "status" => "succeeded", "category" => "配送", "reason" => "未着のため" } ] }.freeze

    setup do
      FakeHandler.calls = []
      FakeHandler.outcome = { "answer" => "Your order ships tomorrow." }
      FakeHandler.resumed = []
      FakeHandler.resume_outcome = { "answer" => "Refunded." }
      FakeHandler.checked = []
      FakeHandler.check_outcome = nil
      FakeHandler.traced = []
      @run = Run.create!(scenario_key: "answer_inquiry", input: { "inquiry" => "Where is my order?" })
    end

    test "records the result of the scenario" do
      perform

      assert_predicate @run.reload, :succeeded?
      assert_equal({ "answer" => "Your order ships tomorrow." }, @run.result)
      assert_not_nil @run.finished_at
    end

    test "passes the inputs and the models to the handler as keywords" do
      perform

      assert_equal [ { inquiry: "Where is my order?", model: "gpt-5-nano" } ], FakeHandler.calls
    end

    test "records a provider failure without reporting it" do
      FakeHandler.outcome = -> { raise RubyLLM::UnauthorizedError, "Incorrect API key provided" }

      assert_no_error_reported { perform }

      assert_predicate @run.reload, :failed?
      assert_nil @run.result
      assert_equal "認証の失敗", @run.failure["kind"]
      assert_equal "Incorrect API key provided", @run.failure["message"]
    end

    test "treats a timeout from the HTTP client as a provider failure" do
      FakeHandler.outcome = -> { raise Faraday::TimeoutError, "execution expired" }

      assert_no_error_reported { perform }

      assert_equal "タイムアウト", @run.reload.failure["kind"]
    end

    test "records and reports an unexpected error" do
      FakeHandler.outcome = -> { raise NoMethodError, "undefined method 'content'" }

      assert_error_reported(NoMethodError) { perform }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
    end

    test "fails and reports a run whose generated files could not all be stored, keeping none of them" do
      FakeHandler.outcome = { "speech" => fake_speech, "slow_speech" => fake_speech }
      uploads = 0
      failing_second = lambda do |upload, *args, **options|
        uploads += 1
        raise IOError, "disk full" if uploads == 2

        upload.call(*args, **options)
      end

      with_storage_upload(failing_second) do
        assert_error_reported(IOError) { perform }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "IOError", @run.failure["kind"]
      assert_equal "disk full", @run.failure["message"]
      assert_nil @run.result
      assert_empty @run.generated_files
    end

    test "fails a ticket workflow run whose step fails, and asks nothing after that step" do
      run = Run.create!(scenario_key: "run_ticket_workflow", input: { "ticket" => "電気ケトルの電源が入りません。" })
      chat = ScriptedChat.new(
        -> { RubyLLM::Message.new(role: :assistant, content: '{"category":"商品の不具合","reason":"電源が入らないため"}', model: "gpt-5-nano") },
        -> { raise RubyLLM::RateLimitError, "Rate limit reached" }
      )

      with_chat(chat) do
        assert_no_error_reported { RunJob.perform_now(run) }
      end

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal "RubyLLM::RateLimitError", run.failure["error_class"]
      assert_equal 2, chat.questions.size, "the review step must not ask after the draft step failed"
    end

    test "fails a token count whose input exceeds the model's limit, as that kind of failure" do
      run = Run.create!(scenario_key: "count_tokens", input: { "instructions" => "サポートの担当者です。", "question" => "返品できますか。" })
      chat = ScriptedChat.new(-> { raise RubyLLM::ContextLengthExceededError, "Your input exceeds the context window of this model." })

      with_chat(chat) do
        assert_no_error_reported { RunJob.perform_now(run) }
      end

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal "入力がモデルの上限を超えた", run.failure["kind"]
      assert_equal "Your input exceeds the context window of this model.", run.failure["message"]
      assert_equal [ "返品できますか。" ], chat.questions
    end

    test "does nothing for a finished run" do
      @run.succeed!({ "answer" => "done" })

      perform

      assert_empty FakeHandler.calls
    end

    test "starts a retryable scenario over when its job runs again" do
      @run.update!(started_at: 1.minute.ago)

      perform

      assert_equal 1, FakeHandler.calls.size
      assert_predicate @run.reload, :succeeded?
    end

    test "fails a scenario that must not run twice, and has no chat to continue, when its job runs again" do
      @run.update!(started_at: 1.minute.ago)

      assert_no_error_reported { perform(retryable: false) }

      assert_empty FakeHandler.calls
      assert_predicate @run.reload, :failed?
      assert_equal "ジョブの中断", @run.failure["kind"]
      assert_match "もう一度実行", @run.failure["hint"]
    end

    test "stops the run for approval when the scenario hands back a waiting chat" do
      chat = create_refund_chat
      create_pending_refund_call(chat, tool_call_id: "call_1", order_id: 7)
      FakeHandler.outcome = -> { ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id) }

      perform(retryable: false)

      assert_predicate @run.reload, :awaiting_approval?
      assert_equal chat.id, @run.chat_id
      assert_equal [ "call_1" ], @run.approval_requests.map { |request| request["tool_call_id"] }
      assert_nil @run.result
    end

    test "leaves a run that waits for approval alone" do
      @run = create_awaiting_run

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_empty FakeHandler.resumed
      assert_predicate @run.reload, :awaiting_approval?
    end

    test "continues the chat of a run that was decided, instead of starting over" do
      @run = create_awaiting_run
      @run.update!(started_at: 2.minutes.ago)
      @run.resume!("call_1", "approved")
      started_at = @run.reload.started_at

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_equal [ @run.chat_id ], FakeHandler.resumed.map(&:id)
      assert_predicate @run.reload, :succeeded?
      assert_equal({ "answer" => "Refunded." }, @run.result)
      assert_equal started_at, @run.started_at
    end

    test "continues the chat even when the run had started and the scenario must not run twice" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.update!(started_at: 1.minute.ago)

      perform(retryable: false)

      assert_equal 1, FakeHandler.resumed.size
      assert_predicate @run.reload, :succeeded?
    end

    test "records a failed resumption and keeps the decision" do
      @run = create_awaiting_run
      @run.resume!("call_1", "denied")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "boom" }

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_nil @run.result
      assert_equal "サーバー側のエラー", @run.failure["kind"]
      assert_equal "denied", @run.approval_requests.sole["decision"]
    end

    test "fails the run when its scenario is no longer defined" do
      @run.update!(scenario_key: "removed_scenario")

      assert_error_reported { RunJob.perform_now(@run) }

      assert_predicate @run.reload, :failed?
    end

    test "runs the scenario inside a workflow that carries the conversation id, and records its trace" do
      workflow_span = with_tracing { perform }

      assert_equal @run.conversation_id, workflow_span.attributes["gen_ai.conversation.id"]
      assert_equal [ workflow_span.hex_trace_id ], @run.reload.traces.map(&:id)
    end

    test "records the trace of a run that stopped for approval" do
      chat = create_refund_chat
      create_pending_refund_call(chat)
      FakeHandler.outcome = -> { ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id) }

      workflow_span = with_tracing { perform(retryable: false) }

      assert_predicate @run.reload, :awaiting_approval?
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
    end

    test "records no trace id when tracing is off" do
      perform

      assert_equal [], @run.reload.trace_ids
    end

    test "fails a submission that failed, and neither keeps work nor checks on any" do
      FakeHandler.outcome = -> { raise RubyLLM::BadRequestError, "Invalid file format" }

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "不正なリクエスト", @run.failure["kind"]
      assert_nil @run.remote_job
      assert_no_enqueued_jobs
    end

    test "keeps the work a scenario left with the provider, checks on it in a minute, and records the submission's trace" do
      FakeHandler.outcome = openai_batch

      freeze_time do
        workflow_span = with_tracing { perform(retryable: false) }

        assert_predicate @run.reload, :running?
        assert_equal %w[batch batch_1 openai validating], @run.remote_job.values_at("kind", "id", "provider", "raw_status")
        assert_equal({ "total" => 5, "completed" => 0, "failed" => 0 }, @run.remote_job["request_counts"])
        assert_nil @run.remote_job["checked_at"]
        assert_equal [ Run::Trace.new(workflow_span.hex_trace_id, Time.current) ], @run.traces
        assert_equal Time.current, @run.started_at
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "checks on unfinished work outside any workflow, keeps what it found, and checks again in a minute" do
      keep_work(started_at: 5.minutes.ago)
      started_at = @run.started_at
      FakeHandler.check_outcome = openai_batch(raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 2, "failed" => 0 })

      freeze_time do
        with_tracing { perform(retryable: false) }

        assert_predicate @run.reload, :running?
        assert_equal [ "batch_1" ], FakeHandler.checked
        assert_equal [ [ :check, false ] ], FakeHandler.traced
        assert_equal "in_progress", @run.remote_job["raw_status"]
        assert_equal({ "total" => 5, "completed" => 2, "failed" => 0 }, @run.remote_job["request_counts"])
        assert_equal Time.current, Time.zone.parse(@run.remote_job["checked_at"])
        assert_empty FakeHandler.calls
        assert_empty FakeHandler.resumed
        assert_empty @run.traces
        assert_equal started_at, @run.started_at
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "collects work that ended inside the workflow, and records the result with the collection's trace" do
      keep_work(started_at: 1.hour.ago)
      started_at = @run.started_at
      FakeHandler.check_outcome = openai_batch(raw_status: "completed", request_counts: { "total" => 5, "completed" => 5, "failed" => 0 })
      FakeHandler.resume_outcome = RESULT

      workflow_span = with_tracing { perform(retryable: false) }

      assert_predicate @run.reload, :succeeded?
      assert_equal RESULT, @run.result
      assert_equal [ "batch_1" ], FakeHandler.resumed
      assert_equal [ [ :check, false ], [ :resume, true ] ], FakeHandler.traced
      assert_equal "completed", @run.remote_job["raw_status"]
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
      assert_equal @run.conversation_id, workflow_span.attributes["gen_ai.conversation.id"]
      assert_equal started_at, @run.started_at
      assert_empty FakeHandler.calls
      assert_no_enqueued_jobs
    end

    test "fails work the provider ended without finishing it, keeping the part it finished" do
      keep_work
      FakeHandler.check_outcome = openai_batch(raw_status: "expired", request_counts: { "total" => 5, "completed" => 3, "failed" => 0 })
      FakeHandler.resume_outcome = RESULT

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "プロバイダー側の処理の失敗", @run.failure["kind"]
      assert_equal "OpenAI", @run.failure["provider"]
      assert_equal "expired", @run.failure["raw_status"]
      assert_match "expired", @run.failure["message"]
      assert_match "24 時間以内", @run.failure["hint"]
      assert_equal RESULT, @run.result
      assert_no_enqueued_jobs
    end

    test "cancels a run whose work was cancelled at the provider, keeping the part it finished" do
      keep_work
      FakeHandler.check_outcome = openai_batch(raw_status: "cancelled")
      FakeHandler.resume_outcome = RESULT

      perform(retryable: false)

      assert_predicate @run.reload, :cancelled?
      assert_equal "プロバイダー側の処理の取り消し", @run.failure["kind"]
      assert_equal "OpenAI", @run.failure["provider"]
      assert_equal "cancelled", @run.failure["raw_status"]
      assert_match "取り消された", @run.failure["hint"]
      assert_equal RESULT, @run.result
      assert_not_nil @run.finished_at
    end

    test "carries a check that could not reach the provider over to the next check" do
      keep_work
      FakeHandler.check_outcome = -> { raise Faraday::ConnectionFailed, "Failed to open TCP connection" }

      freeze_time do
        assert_no_error_reported { with_tracing { perform(retryable: false) } }

        assert_predicate @run.reload, :running?
        assert_equal({ "kind" => "接続の失敗", "message" => "Failed to open TCP connection", "at" => Time.current.iso8601(3) }, @run.remote_job["check_failure"])
        assert_empty @run.traces
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "carries a collection that failed at the provider over to the next check, recording no trace" do
      keep_work
      FakeHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "The server had an error" }

      freeze_time do
        assert_no_error_reported { with_tracing { perform(retryable: false) } }

        assert_predicate @run.reload, :running?
        assert_equal({ "kind" => "サーバー側のエラー", "message" => "The server had an error", "at" => Time.current.iso8601(3) }, @run.remote_job["check_failure"])
        assert_empty @run.traces
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "fails, reports, and stops checking on a collection that fails for an error of this app" do
      keep_work
      FakeHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise NoMethodError, "undefined method 'content' for nil" }

      assert_error_reported(NoMethodError) { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
      assert_nil @run.result
      assert_no_enqueued_jobs
    end

    test "fails, reports, and stops checking on a check that fails for an error of this app" do
      keep_work
      FakeHandler.check_outcome = -> { raise NoMethodError, "undefined method 'refresh'" }

      assert_error_reported(NoMethodError) { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
      assert_no_enqueued_jobs
    end

    test "carries a failed check over until 48 hours after the submission, and then fails with its error" do
      travel_to(Time.zone.local(2026, 9, 21, 10, 0, 0)) { keep_work }
      FakeHandler.check_outcome = -> { raise Faraday::ConnectionFailed, "refused" }

      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 0)) { perform(retryable: false) }

      assert_predicate @run.reload, :running?
      assert_enqueued_jobs 1

      clear_enqueued_jobs
      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 1)) do
        assert_no_error_reported { perform(retryable: false) }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "接続の失敗", @run.failure["kind"]
      assert_equal "refused", @run.failure["message"]
      assert_no_enqueued_jobs
    end

    test "gives up on a collection that fails at the provider more than 48 hours after the submission" do
      travel_to(Time.zone.local(2026, 9, 21, 10, 0, 0)) { keep_work }
      FakeHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "The server had an error" }

      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 1)) do
        assert_no_error_reported { perform(retryable: false) }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "サーバー側のエラー", @run.failure["kind"]
      assert_nil @run.result
      assert_no_enqueued_jobs
    end

    test "leaves the same work and one check each when the check runs twice in a row" do
      keep_work
      FakeHandler.check_outcome = openai_batch(raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 1, "failed" => 0 })

      perform(retryable: false)
      first = @run.reload.remote_job.except("checked_at")
      perform(retryable: false)

      assert_equal first, @run.reload.remote_job.except("checked_at")
      assert_predicate @run, :running?
      assert_enqueued_jobs 2, only: RunJob
    end

    test "finds the run a queued job was for" do
      serialized = RunJob.new(@run).serialize

      assert_equal @run, RunJob.run_from(serialized)
      assert_nil RunJob.run_from(ApplicationJob.new.serialize)
    end

    private

    # The run left a batch with the provider when its job first ran.
    def keep_work(started_at: 1.minute.ago)
      @run.update!(started_at: started_at)
      @run.keep_remote_job!(Scenario.new(**Scenario.members.index_with(nil)).remote_state(openai_batch))
    end

    def perform(retryable: true)
      scenario = Scenario.new(
        key: "answer_inquiry",
        demo_key: "responses-api",
        name: "問い合わせに回答する",
        providers: %w[openai],
        models: { "model" => "gpt-5-nano" },
        inputs: [ Scenario::Input.new(name: "inquiry", label: "問い合わせ", default: "", required: true) ],
        handler_name: FakeHandler.name,
        result_kind: "text_answer",
        retryable: retryable
      )
      @run.define_singleton_method(:scenario) { scenario }
      RunJob.perform_now(@run)
    end

    # Runs the block with spans exported to memory, and returns the workflow's span.
    def with_tracing
      exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
      subscriber = Observability::RubyLLMSpanSubscriber.new(tracer: provider.tracer("test"), capture_content: false)
      subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, subscriber)

      yield
      exporter.finished_spans.find { |span| span.name.start_with?("invoke_agent") }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
      # Shutting down clears the exporter, so the spans are read first.
      provider.shutdown
    end
  end
end
