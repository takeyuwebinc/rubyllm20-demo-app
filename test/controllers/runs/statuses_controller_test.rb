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

    test "returns the research report and the job ID of a run that succeeded" do
      run = create_research_run(result: research_result)

      get run_status_path(run)

      assert_no_match(/<html/, response.body)
      assert_select "[data-remote-job-id]", text: /v1_research/
      assert_select "[data-research-report] [data-report]", text: /通信販売には法定のクーリング・オフがない。/
      assert_select "[data-research-report] [data-citation]", 1
      assert_select "[data-research-report] [data-cost]", text: /不明/
    end

    test "returns that a run waiting on the provider will be tried again" do
      run = create_research_run.tap { |r| r.retry_later!(Faraday::ConnectionFailed.new("refused")) }

      get run_status_path(run)

      assert_select "[data-retry]", text: /1 回目、上限 60 回/
      assert_select "[data-controller='poll'][data-poll-active-value='true']"
    end

    test "returns the generated product video of a run that succeeded" do
      run = create_product_video_run

      get run_status_path(run)

      assert_no_match(/<html/, response.body)
      assert_shows_product_video(run)
    end

    test "returns the approval request while the run waits for a decision" do
      run = create_awaiting_run

      get run_status_path(run)

      assert_select "[data-run-status]", text: "承認待ち"
      assert_select "[data-approval] button[type=submit]", text: "承認する"
    end

    # The job keeps the id right after leaving the work with the provider,
    # so the next poll is what shows it.
    test "returns the id of the work a running run left with the provider" do
      run = create_run(remote_job_id: "video-1")

      get run_status_path(run)

      assert_select "[data-run-status]", text: "実行中"
      assert_select "[data-remote-job-id] code", text: "video-1"
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
