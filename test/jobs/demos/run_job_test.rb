require "test_helper"

module Demos
  class RunJobTest < ActiveSupport::TestCase
    # Stands in for a scenario handler so that no provider is called.
    class FakeHandler
      class << self
        attr_accessor :calls, :outcome, :resumed, :resume_outcome

        def perform(**arguments)
          calls << arguments
          outcome.respond_to?(:call) ? outcome.call : outcome
        end

        def resume(chat)
          resumed << chat
          resume_outcome.respond_to?(:call) ? resume_outcome.call : resume_outcome
        end
      end
    end

    # Work left with the provider as RubyLLM's ResearchJob is: an id, and
    # whether it is still pending. An error of a job's wait holds it.
    RemoteWork = Data.define(:id, :status) do
      def pending? = status == :pending
      def cancelled? = status == :cancelled
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

    setup do
      FakeHandler.calls = []
      FakeHandler.outcome = { "answer" => "Your order ships tomorrow." }
      FakeHandler.resumed = []
      FakeHandler.resume_outcome = { "answer" => "Refunded." }
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

    test "keeps the ID of work the scenario left with the provider, then waits for it in the same workflow" do
      FakeHandler.outcome = RemoteWork.new("interactions/abc", :pending)
      seen_while_waiting = {}
      FakeHandler.resume_outcome = lambda do
        seen_while_waiting[:remote_job_id] = @run.reload.remote_job_id
        seen_while_waiting[:trace_id] = OpenTelemetry::Trace.current_span.context.hex_trace_id
        { "report" => "調査の結果" }
      end

      workflow_span = with_tracing { perform(retryable: false) }

      assert_equal 1, FakeHandler.calls.size
      assert_equal [ "interactions/abc" ], FakeHandler.resumed
      assert_equal "interactions/abc", seen_while_waiting[:remote_job_id]
      assert_equal workflow_span.hex_trace_id, seen_while_waiting[:trace_id]
      @run.reload
      assert_predicate @run, :succeeded?
      assert_equal({ "report" => "調査の結果" }, @run.result)
      assert_equal "interactions/abc", @run.remote_job_id
      assert_equal [ workflow_span.hex_trace_id ], @run.trace_ids
    end

    test "waits for the work kept at the provider when the job runs again, instead of starting over" do
      started_at = 5.minutes.ago.round
      @run.update!(started_at: started_at)
      @run.keep_remote_job_id!("interactions/abc")

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_equal [ "interactions/abc" ], FakeHandler.resumed
      @run.reload
      assert_predicate @run, :succeeded?
      assert_equal({ "answer" => "Refunded." }, @run.result)
      assert_equal started_at, @run.started_at
    end

    test "continues the chat of a run that also kept the ID of work at the provider" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.keep_remote_job_id!("interactions/abc")

      perform(retryable: false)

      assert_equal [ @run.chat_id ], FakeHandler.resumed.map(&:id)
      assert_predicate @run.reload, :succeeded?
    end

    test "does not try a chat again when continuing it fails in a way that may pass" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.keep_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "boom" }

      # Deciding queued a job already; only what continuing the chat queues counts.
      assert_no_enqueued_jobs(only: RunJob) { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "サーバー側のエラー", @run.failure["kind"]
    end

    test "fails a run whose research failed, keeping its ID, without reporting it" do
      @run.keep_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research failed: boom (job abc)", job: RemoteWork.new("abc", :failed)) }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_equal "調査の失敗", @run.failure["kind"]
      assert_equal "Research failed: boom (job abc)", @run.failure["message"]
      assert_equal "interactions/abc", @run.remote_job_id
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails a run whose wait ran past its deadline" do
      @run.keep_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::TimeoutError.new("Research timed out (job abc)", job: RemoteWork.new("abc", :pending)) }

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "待ち時間の上限", @run.failure["kind"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "tries a run waiting on the provider again a minute later when fetching the work fails in a way that may pass" do
      job = RemoteWork.new("abc", :pending)
      [
        -> { raise RubyLLM::UnauthorizedError, "invalid_grant" },
        -> { raise Faraday::ConnectionFailed, "refused" },
        -> { raise RubyLLM::ServerError, "boom" },
        -> { raise RubyLLM::ResearchJob::TimeoutError.new("Research request timed out (job abc)", job: job), cause: Faraday::TimeoutError.new("slow") }
      ].each.with_index(1) do |failure, count|
        FakeHandler.resume_outcome = failure
        @run.keep_remote_job_id!("interactions/abc")

        freeze_time do
          assert_no_error_reported { perform(retryable: false) }

          assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
        end
        @run.reload
        assert_predicate @run, :running?, count
        assert_nil @run.finished_at
        assert_equal count, @run.retries
      end
      assert_equal "タイムアウト", @run.failure["kind"]
    end

    test "tries again a minute later when the wait that follows the submission fails in a way that may pass" do
      FakeHandler.outcome = RemoteWork.new("interactions/abc", :pending)
      FakeHandler.resume_outcome = -> { raise RubyLLM::UnauthorizedError, "invalid_rapt" }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :running?
      assert_equal "interactions/abc", @run.remote_job_id
      assert_equal "認証の失敗", @run.failure["kind"]
      assert_enqueued_with(job: RunJob, args: [ @run ])
    end

    test "fails a submission that fails in a way that may pass, as nothing was left at the provider" do
      FakeHandler.outcome = -> { raise RubyLLM::RateLimitError, "Quota exceeded" }

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "レート制限", @run.failure["kind"]
      assert_nil @run.remote_job_id
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails a run waiting on the provider once it has been tried again as often as allowed" do
      @run.update!(failure: { "kind" => "接続の失敗", "retries" => Run::MAX_RETRIES - 1 })
      @run.keep_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise Faraday::ConnectionFailed, "refused" }

      perform(retryable: false)

      assert_predicate @run.reload, :running?
      assert_equal Run::MAX_RETRIES, @run.retries
      assert_enqueued_with(job: RunJob, args: [ @run ])
      clear_enqueued_jobs

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "接続の失敗", @run.failure["kind"]
      assert_equal "refused", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "records that the provider cancelled the work, without reporting it" do
      @run.keep_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research cancelled: stopped by user (job abc)", job: RemoteWork.new("abc", :cancelled)) }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :cancelled?
      assert_not_nil @run.finished_at
      assert_equal "取り消し", @run.failure["kind"]
      assert_equal "Research cancelled: stopped by user (job abc)", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails as expired a run whose work the provider no longer has" do
      @run.keep_remote_job_id!("interactions/abc")
      not_found = RubyLLM::Error.new("Requested entity was not found.", response: Data.define(:status, :body).new(404, ""))
      FakeHandler.resume_outcome = -> { raise not_found }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_equal "期限切れ", @run.failure["kind"]
      assert_equal "Requested entity was not found.", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails as its kind, not as expired, a 404 on a run that kept no ID" do
      FakeHandler.outcome = -> { raise RubyLLM::Error.new("Not found", response: Data.define(:status, :body).new(404, "")) }

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "RubyLLM::Error", @run.failure["kind"]
    end

    test "records a cancellation whether or not the run kept an ID" do
      FakeHandler.outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research cancelled:  (job abc)", job: RemoteWork.new("abc", :cancelled)) }

      perform(retryable: false)

      assert_predicate @run.reload, :cancelled?
      assert_nil @run.remote_job_id
      assert_equal "取り消し", @run.failure["kind"]
    end

    test "queues a run again after a minute" do
      freeze_time do
        RunJob.retry_later(@run)

        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "fails the run when its scenario is no longer defined" do
      @run.update!(scenario_key: "removed_scenario")

      assert_error_reported { RunJob.perform_now(@run) }

      assert_predicate @run.reload, :failed?
    end

    test "runs the scenario inside a workflow that carries the conversation id, and records its trace" do
      workflow_span = with_tracing { perform }

      assert_equal @run.conversation_id, workflow_span.attributes["gen_ai.conversation.id"]
      assert_equal [ workflow_span.hex_trace_id ], @run.reload.trace_ids
    end

    test "records the trace of a run that stopped for approval" do
      chat = create_refund_chat
      create_pending_refund_call(chat)
      FakeHandler.outcome = -> { ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id) }

      workflow_span = with_tracing { perform(retryable: false) }

      assert_predicate @run.reload, :awaiting_approval?
      assert_equal [ workflow_span.hex_trace_id ], @run.trace_ids
    end

    test "records no trace id when tracing is off" do
      perform

      assert_equal [], @run.reload.trace_ids
    end

    test "finds the run a queued job was for" do
      serialized = RunJob.new(@run).serialize

      assert_equal @run, RunJob.run_from(serialized)
      assert_nil RunJob.run_from(ApplicationJob.new.serialize)
    end

    private

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
