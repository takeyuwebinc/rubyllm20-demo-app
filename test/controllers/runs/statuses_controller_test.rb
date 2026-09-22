require "test_helper"

module Runs
  class StatusesControllerTest < ActionDispatch::IntegrationTest
    test "returns only the part of the run page that changes" do
      run = create_run.tap { |r| r.succeed!({ "answer" => "Your order ships tomorrow.", "model" => "gpt-5-nano" }) }

      get run_status_path(run)

      assert_response :success
      assert_no_match(/<html/, response.body)
      assert_select "[data-run-status]", text: "成功"
      assert_select "*", text: "Your order ships tomorrow."
    end

    test "returns the approval request while the run waits for a decision" do
      run = create_awaiting_run

      get run_status_path(run)

      assert_select "[data-run-status]", text: "承認待ち"
      assert_select "[data-approval] button[type=submit]", text: "承認する"
    end
  end
end
