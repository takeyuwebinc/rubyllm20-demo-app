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

    # Answers each question with the next scripted answer, in place of a chat
    # with a provider, and keeps the questions it was asked.
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
    end

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
