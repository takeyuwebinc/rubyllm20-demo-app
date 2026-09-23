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

    test "returns the generated speech of a run that succeeded" do
      run = create_speech_run

      get run_status_path(run)

      assert_no_match(/<html/, response.body)
      assert_shows_speech(run)
    end

    test "returns the approval request while the run waits for a decision" do
      run = create_awaiting_run

      get run_status_path(run)

      assert_select "[data-run-status]", text: "承認待ち"
      assert_select "[data-approval] button[type=submit]", text: "承認する"
    end

    test "returns the Sentry links above the result" do
      run = create_run(trace_ids: %w[11111111111111111111111111111111])
      run.succeed!({ "answer" => "Your order ships tomorrow.", "model" => "gpt-5-nano" })

      with_env("SENTRY_ORG" => "example-org", "SENTRY_DSN" => "https://public-key@o1.ingest.sentry.io/42") do
        get run_status_path(run)
      end

      assert_before "[data-sentry-links]", "[data-run-result]"
    end
  end
end
