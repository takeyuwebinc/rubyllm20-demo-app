require "test_helper"

module Demos
  class RunTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ScreenHelpers

    test "starts a run with the given input and queues its job" do
      run = Run.start(runnable_scenario, "inquiry" => "Where is my order?")

      assert_predicate run, :persisted?
      assert_predicate run, :running?
      assert_equal({ "inquiry" => "Where is my order?" }, run.input)
      assert_equal [], run.trace_ids
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "issues a conversation id that Sentry can put in a URL" do
      first = Run.start(runnable_scenario, {})
      second = Run.start(runnable_scenario, {})

      assert_match(/\A[A-Za-z0-9_-]+\z/, first.conversation_id)
      refute_equal first.conversation_id, second.conversation_id
    end

    test "does not record a run whose scenario cannot run" do
      run = assert_no_difference(-> { Run.count }) { Run.start(runnable_scenario(providers: %w[nowhere]), {}) }

      refute_predicate run, :persisted?
      assert_predicate run.errors[:base], :any?
      assert_no_enqueued_jobs
    end

    test "does not record a run with a blank required input, and says which one" do
      run = assert_no_difference(-> { Run.count }) { Run.start(runnable_scenario, "inquiry" => "  ") }

      refute_predicate run, :persisted?
      assert_predicate run.input_errors("inquiry"), :any?
      assert_no_enqueued_jobs
    end

    test "records the result and when it finished" do
      run = create_run

      run.succeed!({ "answer" => "Hello" })

      assert_predicate run.reload, :succeeded?
      assert_equal({ "answer" => "Hello" }, run.result)
      assert_not_nil run.finished_at
    end

    test "never rewrites a finished run" do
      run = create_run
      run.succeed!({ "answer" => "Hello" })

      assert_raises(ActiveRecord::RecordInvalid) { run.fail_with!(RuntimeError.new("late")) }
      assert_predicate run.reload, :succeeded?
    end

    test "allows the transitions a run can make" do
      assert Run.transition?("running", "awaiting_approval")
      assert Run.transition?("awaiting_approval", "running")
      assert Run.transition?("awaiting_approval", "cancelled")
      refute Run.transition?("succeeded", "running")
      refute Run.transition?("failed", "running")
      refute Run.transition?("cancelled", "failed")
    end

    test "records a provider failure with its kind and likely causes" do
      run = create_run

      run.fail_with!(RubyLLM::RateLimitError.new("You exceeded your current quota"))

      assert_predicate run.reload, :failed?
      assert_not_nil run.finished_at
      assert_equal "レート制限", run.failure["kind"]
      assert_equal "RubyLLM::RateLimitError", run.failure["error_class"]
      assert_equal "You exceeded your current quota", run.failure["message"]
      assert_match "残高", run.failure["hint"]
      assert_equal "OpenAI", run.failure["provider"]
    end

    test "records an error outside the table by its class, without causes" do
      run = create_run

      run.fail_with!(ArgumentError.new("bad"))

      assert_equal "ArgumentError", run.failure["kind"]
      assert_nil run.failure["hint"]
    end

    test "adds each trace id once" do
      run = create_run

      2.times { run.add_trace_id!("0af7651916cd43dd8448eb211c80319c") }

      assert_equal [ "0af7651916cd43dd8448eb211c80319c" ], run.reload.trace_ids
    end

    test "fails the runs a dead worker left running, and only those" do
      abandoned = create_run
      finished = create_run.tap { |run| run.succeed!({ "answer" => "done" }) }
      awaiting = create_awaiting_run

      Run.fail_abandoned!([ abandoned.id, finished.id, awaiting.id ])

      assert_predicate abandoned.reload, :failed?
      assert_equal "ワーカーの異常終了", abandoned.failure["kind"]
      assert_predicate finished.reload, :succeeded?
      assert_predicate awaiting.reload, :awaiting_approval?
    end

    test "lists the runs of a demo, newest first" do
      older = create_run(scenario_key: "answer_inquiry", created_at: 2.minutes.ago)
      newer = create_run(scenario_key: "answer_inquiry", created_at: 1.minute.ago)
      create_run(scenario_key: "cite_return_policy")

      assert_equal [ newer, older ], Run.for_demo(Catalog.demo("responses-api")).latest_first.to_a
    end

    test "keeps a run whose scenario is no longer defined" do
      run = create_run(scenario_key: "removed_scenario")

      assert_nil run.scenario
      assert_predicate run.reload, :persisted?
    end

    test "stops for approval with the chat and what it asked" do
      chat = create_refund_chat
      create_pending_refund_call(chat, tool_call_id: "call_1", order_id: 7, reason: "商品が破損していた")
      run = create_run

      run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id))

      assert_predicate run.reload, :awaiting_approval?
      assert_equal chat.id, run.chat_id
      assert_equal [ {
        "tool_call_id" => "call_1", "name" => "issue_refund",
        "arguments" => { "order_id" => 7, "reason" => "商品が破損していた" }, "decision" => nil
      } ], run.approval_requests
    end

    test "keeps the decision and continues" do
      run = create_awaiting_run

      run.resume!("call_1", "approved")

      assert_predicate run.reload, :running?
      assert_equal "approved", run.approval_requests.sole["decision"]
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses to continue on a request it never made" do
      run = create_awaiting_run

      assert_raises(ArgumentError) { run.resume!("call_9", "approved") }

      assert_predicate run.reload, :awaiting_approval?
      assert_nil run.approval_requests.sole["decision"]
      assert_no_enqueued_jobs
    end

    test "keeps earlier requests and their decisions when it stops again" do
      chat = create_refund_chat
      run = create_awaiting_run(chat: chat, tool_call_id: "call_1")
      ToolApproval::AnswerRefundRequest.decide(Chat.find(chat.id), "call_1", approved: true)
      run.resume!("call_1", "approved")
      create_pending_refund_call(chat, tool_call_id: "call_2", order_id: 8)

      run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id))

      assert_equal [ [ "call_1", "approved" ], [ "call_2", nil ] ],
        run.reload.approval_requests.map { |request| request.values_at("tool_call_id", "decision") }
    end

    test "refuses to stop for approval with nothing to decide" do
      chat = create_refund_chat
      run = create_run

      assert_raises(ArgumentError) { run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id)) }

      assert_predicate run.reload, :running?
      assert_nil run.chat_id
    end

    test "never stops a finished run for approval" do
      chat = create_refund_chat
      create_pending_refund_call(chat)
      run = create_run.tap { |r| r.succeed!({ "answer" => "done" }) }

      assert_raises(ActiveRecord::RecordInvalid) { run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id)) }
      assert_predicate run.reload, :succeeded?
    end

    test "fails for a reason that is not a provider error" do
      run = create_run

      run.fail_as!(FailureKinds::INTERRUPTED)

      assert_predicate run.reload, :failed?
      assert_equal "ジョブの中断", run.failure["kind"]
      assert_match "もう一度実行", run.failure["hint"]
    end

    private

    def runnable_scenario(**overrides)
      Scenario.new(
        key: "answer_inquiry",
        demo_key: "responses-api",
        name: "問い合わせに回答する",
        providers: [],
        models: {},
        inputs: [ Scenario::Input.new(name: "inquiry", label: "問い合わせ", default: "Hi", required: true) ],
        handler_name: "Object",
        result_kind: "text_answer",
        retryable: true,
        **overrides
      )
    end

    def create_run(**attributes)
      Run.create!(scenario_key: "answer_inquiry", input: { "inquiry" => "Hi" }, **attributes)
    end
  end
end
