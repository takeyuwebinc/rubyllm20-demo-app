require "test_helper"

class DemosControllerTest < ActionDispatch::IntegrationTest
  test "lists the ten demos with their summaries and whether they can run" do
    with_openai_key("sk-test") { get root_path }

    assert_response :success
    assert_select "[data-demo]", 10
    assert_select "[data-demo='responses-api']" do
      assert_select "a[href=?]", demo_path("responses-api"), text: "Responses API"
      assert_select "*", text: /推論、ツール、プロバイダー側のツール/
      assert_select "[data-availability]", text: "実行できる"
    end
    assert_select "[data-demo='citations'] [data-availability]", text: "準備中"
  end

  test "names the missing provider in the list" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='responses-api'] [data-availability]", text: "設定値が足りない（OpenAI）"
  end

  test "shows the explanation, the sources, the code, and the input of a runnable scenario" do
    with_openai_key("sk-test") { get demo_path("responses-api") }

    assert_response :success
    assert_select "h2", text: "役立つケース"
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "a[href='https://rubyllm.com/upgrading/'][target='_blank']"
    assert_select "#answer_inquiry" do
      assert_select "pre code", text: /class AnswerInquiry/
      assert_select "textarea[name='run[input][inquiry]']", text: /A-10234/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
      assert_select "a", text: "入力を既定に戻す"
      assert_select "*", text: /Sentry に送られる/
    end
  end

  test "keeps a scenario that lacks settings from running and points to the setup guide" do
    with_openai_key(nil) { get demo_path("responses-api") }

    assert_select "#answer_inquiry" do
      assert_select "input[type=submit][value='実行する'][disabled]"
      assert_select "*", text: /OpenAI/
      assert_select "*", text: %r{docs/api-keys\.md}
      assert_select "*", text: %r{bin/check_keys}
    end
  end

  test "shows a scenario being prepared without code or input" do
    get demo_path("citations")

    assert_select "#cite_return_policy" do
      assert_select "*", text: /準備中/
      assert_select "pre", count: 0
      assert_select "textarea", count: 0
      assert_select "input[type=submit]", count: 0
    end
  end

  test "says the explanation comes with the scenario when a demo has none yet" do
    get demo_path("citations")

    assert_select "h2", text: "役立つケース", count: 0
    assert_select "*", text: /規約や契約のように/
    assert_select "a[href='https://rubyllm.com/citations/']"
  end

  test "lists the recent runs of the demo" do
    run = create_run

    get demo_path("responses-api")

    assert_select "a[href=?]", run_path(run), text: /実行中/
  end

  test "says there is no run yet" do
    get demo_path("responses-api")

    assert_select "*", text: /まだ実行がない/
  end

  test "fills the input from an earlier run" do
    run = create_run

    get demo_path("responses-api", from_run: run.id)

    assert_select "textarea[name='run[input][inquiry]']", text: "Where is my order?"
  end

  test "is not found for an unknown demo" do
    get demo_path("missing")

    assert_response :not_found
  end
end
