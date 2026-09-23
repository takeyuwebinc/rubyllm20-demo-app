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

    test "records a web search run with its question and queues it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("provider-tools"), params: { run: { scenario_key: "search_web", input: { question: "返品の制度は変わりましたか" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "question" => "返品の制度は変わりましたか" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a blank question for the web search" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("provider-tools"), params: { run: { scenario_key: "search_web", input: { question: " \n" } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#search_web [data-input-error='question']", text: "入力してください"
    end

    test "records a speech run with the answer to read aloud, and queues it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("video-and-speech"), params: { run: { scenario_key: "speak_answer", input: { text: "明日お届けします。" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "text" => "明日お届けします。" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a blank answer to read aloud" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("video-and-speech"), params: { run: { scenario_key: "speak_answer", input: { text: " \n" } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#speak_answer [data-input-error='text']", text: "入力してください"
    end

    test "records a token count run with its instructions and question, and queues it" do
      assert_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tokenization"), params: { run: { scenario_key: "count_tokens", input: { instructions: "サポートの担当者です。", question: "返品できますか。" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "instructions" => "サポートの担当者です。", "question" => "返品できますか。" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a token count whose instructions or question is blank, and says which" do
      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tokenization"), params: { run: { scenario_key: "count_tokens", input: { instructions: " ", question: "返品できますか。" } } }
        end
      end
      assert_response :unprocessable_entity
      assert_select "#count_tokens [data-input-error='instructions']", text: "入力してください"
      assert_select "#count_tokens [data-input-error='question']", count: 0

      assert_no_difference(-> { Run.count }) do
        with_openai_key("sk-test") do
          post demo_runs_path("tokenization"), params: { run: { scenario_key: "count_tokens", input: { instructions: "サポートの担当者です。", question: "\n" } } }
        end
      end
      assert_response :unprocessable_entity
      assert_select "#count_tokens [data-input-error='question']", text: "入力してください"
    end

    test "records a research run with its topic and queues it" do
      assert_difference(-> { Run.count }) do
        with_vertexai_config("demo-project") do
          post demo_runs_path("deep-research"), params: { run: { scenario_key: "research_topic", input: { topic: "返品の法制度を整理してほしい" } } }
        end
      end

      run = Run.last
      assert_redirected_to run_path(run)
      assert_equal({ "topic" => "返品の法制度を整理してほしい" }, run.input)
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses a blank research topic" do
      assert_no_difference(-> { Run.count }) do
        with_vertexai_config("demo-project") do
          post demo_runs_path("deep-research"), params: { run: { scenario_key: "research_topic", input: { topic: " " } } }
        end
      end

      assert_response :unprocessable_entity
      assert_select "#research_topic [data-input-error='topic']", text: "入力してください"
    end

    test "records no research run without Vertex AI settings" do
      assert_no_difference(-> { Run.count }) do
        with_vertexai_config(nil) do
          post demo_runs_path("deep-research"), params: { run: { scenario_key: "research_topic", input: { topic: "返品の法制度" } } }
        end
      end

      assert_no_enqueued_jobs
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
