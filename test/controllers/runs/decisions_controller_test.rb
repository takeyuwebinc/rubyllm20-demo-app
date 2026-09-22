require "test_helper"

module Runs
  class DecisionsControllerTest < ActionDispatch::IntegrationTest
    test "records an approval on the tool call and continues the run" do
      run = create_awaiting_run

      post run_decision_path(run), params: { tool_call_id: "call_1", decision: "approve" }

      assert_redirected_to run_path(run)
      assert_equal "approved", refund_call_approval("call_1")
      assert_predicate run.reload, :running?
      assert_equal "approved", run.approval_requests.sole["decision"]
      assert_enqueued_with(job: Demos::RunJob, args: [ run ])
    end

    test "records a denial on the tool call and continues the run" do
      run = create_awaiting_run

      post run_decision_path(run), params: { tool_call_id: "call_1", decision: "deny" }

      assert_redirected_to run_path(run)
      assert_equal "denied", refund_call_approval("call_1")
      assert_predicate run.reload, :running?
      assert_equal "denied", run.approval_requests.sole["decision"]
      assert_enqueued_with(job: Demos::RunJob, args: [ run ])
    end

    test "refuses a decision on a request the run never made" do
      run = create_awaiting_run

      post run_decision_path(run), params: { tool_call_id: "call_9", decision: "approve" }

      assert_refused run, /その提案はこの実行にない/
    end

    test "refuses a decision that is neither approve nor deny" do
      run = create_awaiting_run

      post run_decision_path(run), params: { tool_call_id: "call_1", decision: "maybe" }

      assert_refused run, /承認か却下/
    end

    test "refuses a decision on a run that is not waiting for one" do
      running = create_run
      finished = create_run.tap { |r| r.succeed!({ "answer" => "done" }) }
      failed = create_run.tap { |r| r.fail_with!(RubyLLM::ServerError.new("boom")) }

      post run_decision_path(running), params: { tool_call_id: "call_1", decision: "approve" }
      assert_response :unprocessable_entity
      assert_select "[data-decision-refused]", text: /承認待ちではない/
      assert_predicate running.reload, :running?

      post run_decision_path(finished), params: { tool_call_id: "call_1", decision: "approve" }
      assert_response :unprocessable_entity
      assert_predicate finished.reload, :succeeded?

      post run_decision_path(failed), params: { tool_call_id: "call_1", decision: "approve" }
      assert_response :unprocessable_entity
      assert_predicate failed.reload, :failed?
      assert_no_enqueued_jobs
    end

    test "refuses a decision on a run whose scenario is no longer defined" do
      run = create_awaiting_run
      run.update_column(:scenario_key, "removed_scenario")

      post run_decision_path(run), params: { tool_call_id: "call_1", decision: "approve" }

      assert_refused run, /定義がない/
    end

    private

    def assert_refused(run, reason)
      assert_response :unprocessable_entity
      assert_select "[data-decision-refused]", text: reason
      assert_select "[data-approval]"
      assert_nil refund_call_approval("call_1")
      assert_predicate run.reload, :awaiting_approval?
      assert_nil run.approval_requests.sole["decision"]
      assert_no_enqueued_jobs
    end
  end
end
