require "test_helper"

module Demos
  class RunsControllerTest < ActionDispatch::IntegrationTest
    test "records the run, queues it, and shows it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("responses-api"), params: { run: { scenario_key: "answer_inquiry", input: { inquiry: "Where is my order?" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "inquiry" => "Where is my order?" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "shows a blank required input beside its field and records nothing" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("responses-api"), params: { run: { scenario_key: "answer_inquiry", input: { inquiry: " " } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#answer_inquiry [data-input-error='inquiry']", text: "入力してください"
    end

    test "records a ticket workflow run with its ticket and queues it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("workflow-instrumentation"), params: { run: { scenario_key: "run_ticket_workflow", input: { ticket: "電源が入りません。" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "ticket" => "電源が入りません。" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a blank ticket for the ticket workflow" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("workflow-instrumentation"), params: { run: { scenario_key: "run_ticket_workflow", input: { ticket: "\n " } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#run_ticket_workflow [data-input-error='ticket']", text: "入力してください"
    end

    test "records a refund run with its inquiry and order, and queues it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tool-approval"), params: { run: { scenario_key: "approve_refund", input: { inquiry: "返金してください", order: "注文番号 C-1" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "inquiry" => "返金してください", "order" => "注文番号 C-1" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a refund run whose inquiry or order is blank, and says which" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tool-approval"), params: { run: { scenario_key: "approve_refund", input: { inquiry: " ", order: "注文番号 C-1" } } }
        end
      end
      assert_response :unprocessable_entity
      assert_select "#approve_refund [data-input-error='inquiry']", text: "入力してください"
      assert_select "#approve_refund [data-input-error='order']", count: 0

      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tool-approval"), params: { run: { scenario_key: "approve_refund", input: { inquiry: "返金してください", order: "\n" } } }
        end
      end
      assert_response :unprocessable_entity
      assert_select "#approve_refund [data-input-error='order']", text: "入力してください"
    end

    test "says in the scenario why it cannot run any more" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key(nil) do
          post demo_runs_path("responses-api"), params: { run: { scenario_key: "answer_inquiry", input: { inquiry: "Hi" } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#answer_inquiry [data-scenario-error]", text: /設定値が足りない: OpenAI/
    end

    test "is not found for a scenario of another demo" do
      post demo_runs_path("citations"), params: { run: { scenario_key: "answer_inquiry", input: { inquiry: "Hi" } } }

      assert_response :not_found
    end
  end
end
