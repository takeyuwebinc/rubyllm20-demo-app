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

  test "shows the ticket workflow as runnable with its explanation, sources, code, and default ticket" do
    with_openai_key("sk-test") { get root_path }

    assert_select "[data-demo='workflow-instrumentation'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { get demo_path("workflow-instrumentation") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /どのステップが時間とコストを使っているかを知りたい/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /3 つの chat のイベントは/
    assert_select "a[href='https://rubyllm.com/instrumentation/#workflows-and-steps'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/agentic-workflows/'][target='_blank']"
    assert_select "#run_ticket_workflow" do
      assert_select "pre code", text: /RubyLLM\.workflow\("サポートチケットへの回答"\)/
      assert_select "pre code", text: /workflow\.step\("レビュー"\)/
      assert_select "textarea[name='run[input][ticket]']", text: /B-20517/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps the ticket workflow from running without OpenAI settings" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='workflow-instrumentation'] [data-availability]", text: "設定値が足りない（OpenAI）"

    with_openai_key(nil) { get demo_path("workflow-instrumentation") }

    assert_select "#run_ticket_workflow [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#run_ticket_workflow input[type=submit][value='実行する'][disabled]"
  end

  test "shows the refund approval as runnable with its explanation, sources, code, and default inputs" do
    with_openai_key("sk-test") { get root_path }

    assert_select "[data-demo='tool-approval'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { get demo_path("tool-approval") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /人の決定があるまで実行されない/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /ループを自分で進める/
    assert_select "a[href='https://rubyllm.com/tool-execution/#requiring-approval'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/durable-agents/#parking-for-a-human-decision'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/agents/#rails-backed-agents'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#human-approval-for-tools'][target='_blank']"
    assert_select "#approve_refund" do
      assert_select "pre code", text: /requires_approval/
      assert_select "pre code", text: /class RefundAgent < RubyLLM::Agent/
      assert_select "pre code", text: /RefundAgent\.find/
      assert_select "textarea[name='run[input][inquiry]']", text: /C-30871/
      assert_select "textarea[name='run[input][order]']", text: /7,980 円/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps the refund approval from running without OpenAI settings" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='tool-approval'] [data-availability]", text: "設定値が足りない（OpenAI）"

    with_openai_key(nil) { get demo_path("tool-approval") }

    assert_select "#approve_refund [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#approve_refund input[type=submit][value='実行する'][disabled]"
  end

  test "shows the web search as runnable with its explanation, sources, code, and default question, and keeps code execution in preparation" do
    with_openai_key("sk-test") { get root_path }

    assert_select "[data-demo='provider-tools'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { get demo_path("provider-tools") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /プロバイダーの側で検索とページの閲覧を行い/
    assert_select "*", text: /検索の回数の課金を含まない/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /検索エンジンの API を選んで契約し/
    assert_select "a[href='https://rubyllm.com/provider-tools/'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#provider-tools'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/docs/guides/tools-web-search'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/docs/pricing#built-in-tools'][target='_blank']"
    assert_select "#search_web" do
      assert_select "pre code", text: /with_provider_tools\(:web_search\)/
      assert_select "pre code", text: /server_tool_calls/
      assert_select "pre code", text: /citations/
      assert_select "textarea[name='run[input][question]']", text: /返品/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
    assert_select "#run_code" do
      assert_select "*", text: /準備中/
      assert_select "textarea", count: 0
      assert_select "input[type=submit]", count: 0
    end
  end

  test "shows reading the answer aloud as runnable with its explanation, sources, code, and default answer" do
    with_openai_key("sk-test") { get root_path }

    assert_select "[data-demo='video-and-speech'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { get demo_path("video-and-speech") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /自動音声応答の文面を読み上げたい/
    assert_select "*", text: /2,000 トークンの入力の上限/
    assert_select "*", text: /2026-09-22 に実際の API で確かめた/
    assert_select "*", text: /AI が生成した音声であることを聞き手に明示する/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /書き直しになる/
    assert_select "a[href='https://rubyllm.com/text-to-speech/'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#video-and-speech-generation'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/video-generation/'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/docs/guides/text-to-speech'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create'][target='_blank']"
    assert_select "#speak_answer" do
      assert_select "pre code", text: /RubyLLM\.speak/
      assert_select "pre code", text: /instructions:/
      assert_select "textarea[name='run[input][text]']", text: /A-10234/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
    assert_select "#generate_product_video" do
      assert_select "*", text: /準備中/
      assert_select "input[type=submit]", count: 0
    end
  end

  test "keeps the web search from running without OpenAI settings" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='provider-tools'] [data-availability]", text: "設定値が足りない（OpenAI）"

    with_openai_key(nil) { get demo_path("provider-tools") }

    assert_select "#search_web [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#search_web input[type=submit][value='実行する'][disabled]"
  end

  test "keeps reading the answer aloud from running without OpenAI settings" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='video-and-speech'] [data-availability]", text: "設定値が足りない（OpenAI）"

    with_openai_key(nil) { get demo_path("video-and-speech") }

    assert_select "#speak_answer [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#speak_answer input[type=submit][value='実行する'][disabled]"
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
