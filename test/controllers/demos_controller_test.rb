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
    assert_select "[data-demo='batches'] [data-availability]", text: "準備中"
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

  test "shows the web search as runnable with its explanation, sources, code, and default question" do
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
  end

  test "shows the code execution as runnable with its explanation, sources, code, and default order data and request" do
    with_openai_key("sk-test") { get demo_path("provider-tools") }

    assert_select "*", text: /コードを実行する隔離環境を自前で構築、運用したくない場合にも役立つ/
    assert_select "*", text: /include に code_interpreter_call\.outputs を足すと/
    assert_select "*", text: /コンテナの課金を含まない/
    assert_select "*", text: /コードを受け取って実行し、出力をモデルに返す往復/
    %w[
      https://rubyllm.com/provider-tools/
      https://rubyllm.com/whats-new-in-2-0/#provider-tools
      https://rubyllm.com/chat-request-control/#provider-options
      https://developers.openai.com/api/docs/guides/tools-web-search
      https://developers.openai.com/api/docs/guides/tools-code-interpreter
      https://developers.openai.com/api/reference/resources/responses/methods/create
      https://developers.openai.com/api/docs/pricing#built-in-tools
    ].each { |url| assert_select "a[href='#{url}'][target='_blank']", 1 }
    sources_heading = css_select("h2").find { |heading| heading.text.strip == "出典" }
    assert_equal 7, sources_heading.next_element.css("li a").size
    assert_select "a[href='https://developers.openai.com/api/docs/pricing#built-in-tools']", text: /Web 検索とコンテナの課金/
    assert_select "#run_code" do
      assert_select "[data-availability]", text: "実行できる"
      assert_select "pre code", text: /with_provider_tools\(:code_execution\)/
      assert_select "pre code", text: /with_provider_options/
      assert_select "pre code", text: /code_interpreter_call\.outputs/
      assert_select "pre code", text: /tool_choice/
      assert_select "textarea[name='run[input][orders]']", text: /E-50104,2026-09-05,キッチン家電,コーヒーメーカー,7980,返金済み/
      assert_select "textarea[name='run[input][request]']", text: /カテゴリごとの売上金額の合計/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
    assert_select "#search_web" do
      assert_select "[data-availability]", text: "実行できる"
      assert_select "pre code", text: /with_provider_tools\(:web_search\)/
    end
  end

  test "keeps the code execution from running without OpenAI settings" do
    with_openai_key(nil) { get demo_path("provider-tools") }

    assert_select "#run_code [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#run_code input[type=submit][value='実行する'][disabled]"
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
  end

  test "shows generating the product video as runnable with its explanation, sources, code, and default description" do
    with_xai_key("xai-test") { with_openai_key(nil) { get root_path } }

    assert_select "[data-demo='video-and-speech'] [data-availability]", text: "実行できる"

    with_xai_key("xai-test") { get demo_path("video-and-speech") }

    assert_select "*", text: /短い紹介動画を用意したい場合にも役立つ/
    assert_select "*", text: /480p が 1 秒 0\.08 ドル、720p が 0\.14 ドル、1080p が 0\.25 ドル/
    assert_select "*", text: /ID から `?VideoJob`? を開き直す公開の API がない/
    assert_select "*", text: /一時的な URL/
    assert_select "*", text: /cost_in_usd_ticks/
    assert_select "*", text: /状態の問い合わせの繰り返し/
    assert_select "*", text: /:completed/
    assert_select "h2 + ul > li > a[target='_blank']", 8
    assert_select "a[href='https://docs.x.ai/developers/model-capabilities/video/generation'][target='_blank']"
    assert_select "a[href='https://docs.x.ai/developers/model-capabilities/imagine'][target='_blank']"
    assert_select "a[href='https://docs.x.ai/developers/models/grok-imagine-video-1.5'][target='_blank']"
    assert_select "#generate_product_video" do
      assert_select "[data-availability]", text: "実行できる"
      assert_select "pre code", text: /RubyLLM\.animate_later/
      assert_select "pre code", text: /\.wait\(/
      assert_select "textarea[name='run[input][description]']", text: /電気ケトル/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps generating the product video from running without xAI settings" do
    with_xai_key(nil) { get demo_path("video-and-speech") }

    assert_select "#generate_product_video [data-availability]", text: "設定値が足りない（xAI）"
    assert_select "#generate_product_video input[type=submit][value='実行する'][disabled]"
  end

  test "names both providers in the list when neither speech nor video has its settings" do
    with_xai_key(nil) { with_openai_key(nil) { get root_path } }

    assert_select "[data-demo='video-and-speech'] [data-availability]", text: "設定値が足りない（OpenAI、xAI）"
  end

  test "keeps the web search from running without OpenAI settings" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='provider-tools'] [data-availability]", text: "設定値が足りない（OpenAI）"

    with_openai_key(nil) { get demo_path("provider-tools") }

    assert_select "#search_web [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#search_web input[type=submit][value='実行する'][disabled]"
  end

  # The demo is as runnable as its most runnable scenario, and the video
  # needs only xAI.
  test "keeps reading the answer aloud from running without OpenAI settings, while the video can still run" do
    with_openai_key(nil) { get root_path }

    assert_select "[data-demo='video-and-speech'] [data-availability]", text: "実行できる"

    with_openai_key(nil) { get demo_path("video-and-speech") }

    assert_select "#speak_answer [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#speak_answer input[type=submit][value='実行する'][disabled]"
    assert_select "#generate_product_video input[type=submit][value='実行する']:not([disabled])"
  end

  # xAI settings are left out, so that the listing is runnable through the
  # token count alone.
  test "shows the token count as runnable with its explanation, sources, code, and default inputs" do
    with_openai_key("sk-test") { with_xai_key(nil) { get root_path } }

    assert_select "[data-demo='tokenization'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { with_xai_key(nil) { get demo_path("tokenization") } }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /質問は会話に加えない/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /ContextLengthExceededError/
    assert_select "a[href='https://rubyllm.com/tokenization/#counting-a-chat-request'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#tokenization-and-token-counting'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/docs/guides/token-counting'][target='_blank']"
    assert_select "a[href='https://developers.openai.com/api/reference/resources/responses/subresources/input_tokens/methods/count'][target='_blank']"
    assert_select "#count_tokens" do
      assert_select "pre code", text: /count_tokens\(@question\)/
      assert_select "pre code", text: /context_window/
      assert_select "textarea[name='run[input][instructions]']", text: /返品ポリシー/
      assert_select "textarea[name='run[input][question]']", text: /D-40518/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "shows the text tokenization as runnable with its explanation, sources, code, and default text" do
    with_openai_key("sk-test") { with_xai_key("xai-test") { get demo_path("tokenization") } }

    assert_select "*", text: /テキストの分割は、テキストがどのトークンに割れるか/
    assert_select "*", text: /文字列が空になるので、バイト列で読む/
    assert_select "*", text: /Perplexity のモデルに解決される/
    assert_select "*", text: /モデルの語彙に合うトークナイザーを手元に用意して保守する/
    assert_select "h2", text: "出典" do |heading|
      assert_equal 6, heading.first.next_element.css("li a[target='_blank']").size
    end
    assert_select "a[href='https://rubyllm.com/tokenization/#tokenizing-text'][target='_blank']"
    assert_select "a[href='https://docs.x.ai/developers/rest-api-reference/inference/other#tokenize-text'][target='_blank']"
    assert_select "#tokenize_text" do
      assert_select "[data-availability]", text: "実行できる"
      assert_select "pre code", text: /RubyLLM\.tokenize\(@text, model: @model, provider: :xai\)/
      assert_select "textarea[name='run[input][text]']", text: /D-40518.*よろしくお願いします🙏/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps the text tokenization from running without xAI settings, and the token count runnable" do
    with_openai_key("sk-test") { with_xai_key(nil) { get root_path } }

    assert_select "[data-demo='tokenization'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { with_xai_key(nil) { get demo_path("tokenization") } }

    assert_select "#tokenize_text [data-availability]", text: "設定値が足りない（xAI）"
    assert_select "#tokenize_text input[type=submit][value='実行する'][disabled]"
    assert_select "#count_tokens [data-availability]", text: "実行できる"
    assert_select "#count_tokens input[type=submit][value='実行する']:not([disabled])"
  end

  test "keeps both tokenization scenarios from running without OpenAI and xAI settings" do
    with_openai_key(nil) { with_xai_key(nil) { get root_path } }

    assert_select "[data-demo='tokenization'] [data-availability]", text: "設定値が足りない（OpenAI、xAI）"

    with_openai_key(nil) { with_xai_key(nil) { get demo_path("tokenization") } }

    assert_select "#count_tokens [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#count_tokens input[type=submit][value='実行する'][disabled]"
    assert_select "#tokenize_text [data-availability]", text: "設定値が足りない（xAI）"
    assert_select "#tokenize_text input[type=submit][value='実行する'][disabled]"
  end

  test "keeps only the token count from running with xAI settings alone" do
    with_openai_key(nil) { with_xai_key("xai-test") { get root_path } }

    assert_select "[data-demo='tokenization'] [data-availability]", text: "実行できる"

    with_openai_key(nil) { with_xai_key("xai-test") { get demo_path("tokenization") } }

    assert_select "#count_tokens [data-availability]", text: "設定値が足りない（OpenAI）"
    assert_select "#count_tokens input[type=submit][value='実行する'][disabled]"
    assert_select "#tokenize_text [data-availability]", text: "実行できる"
    assert_select "#tokenize_text input[type=submit][value='実行する']:not([disabled])"
  end

  test "shows the research as runnable with its explanation, sources, code, and default topic" do
    with_vertexai_config("demo-project") { get root_path }

    assert_select "[data-demo='deep-research'] [data-availability]", text: "実行できる"

    with_vertexai_config("demo-project") { get demo_path("deep-research") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /RubyLLM::ResearchJob\.find/
    assert_select "*", text: /120 分/
    assert_select "*", text: /レポートの本文、トークン数、コストはトレースに載らず/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /Interactions API/
    assert_select "a[href='https://rubyllm.com/hosted-research/'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#hosted-research'][target='_blank']"
    assert_select "a[href='https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/use-deep-research'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/provider-coverage/'][target='_blank']"
    assert_select "#research_topic" do
      assert_select "pre code", text: /research_later/
      assert_select "pre code", text: /ResearchJob\.find/
      assert_select "textarea[name='run[input][topic]']", text: /特定商取引法/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps the research from running without Vertex AI settings" do
    with_vertexai_config(nil) { get root_path }

    assert_select "[data-demo='deep-research'] [data-availability]", text: "設定値が足りない（VertexAI）"

    with_vertexai_config(nil) { get demo_path("deep-research") }

    assert_select "#research_topic [data-availability]", text: "設定値が足りない（VertexAI）"
    assert_select "#research_topic input[type=submit][value='実行する'][disabled]"
  end

  test "shows answering from the return policy as runnable with its explanation, sources, code, default inquiry, and the policy" do
    with_anthropic_key("sk-ant-test") { get root_path }

    assert_select "[data-demo='citations'] [data-availability]", text: "実行できる"

    with_anthropic_key("sk-ant-test") { get demo_path("citations") }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /回答の根拠を読み手が確かめる必要がある/
    assert_select "*", text: /スキャンだけの PDF と、画像は引用できない/
    assert_select "*", text: /添付した文書と出典は載らない/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /引用が文書に実在するかを照合する仕組み/
    assert_select "a[href='https://rubyllm.com/citations/'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#citations'][target='_blank']"
    assert_select "a[href='https://platform.claude.com/docs/en/build-with-claude/citations'][target='_blank']"
    assert_select "a[href='https://platform.claude.com/docs/en/build-with-claude/pdf-support'][target='_blank']"
    assert_select "#cite_return_policy" do
      assert_select "pre code", text: /\.with_citations/
      assert_select "pre code", text: /ask\(@inquiry, with: @policy\)/
      assert_select "pre code", text: /citations/
      assert_select "[data-scenario-documents] a[href='/documents/return-policy.pdf'][target='_blank']", text: "返品ポリシー文書（PDF、3 ページ）"
      assert_select "textarea[name='run[input][inquiry]']", text: /E-50712/
      assert_select "textarea[name='run[input][policy]']", count: 0
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "keeps answering from the return policy from running without Anthropic settings, even with OpenAI's" do
    with_anthropic_key(nil) do
      with_openai_key("sk-test") { get root_path }
    end

    assert_select "[data-demo='citations'] [data-availability]", text: "設定値が足りない（Anthropic）"

    with_anthropic_key(nil) do
      with_openai_key("sk-test") { get demo_path("citations") }
    end

    assert_select "#cite_return_policy [data-availability]", text: "設定値が足りない（Anthropic）"
    assert_select "#cite_return_policy input[type=submit][value='実行する'][disabled]"
  end

  test "shows the fallback as runnable with its explanation, sources, code, and default inquiry" do
    with_openai_key("sk-test") { with_anthropic_key("sk-ant-test") { get root_path } }

    assert_select "[data-demo='model-fallbacks'] [data-availability]", text: "実行できる"

    with_openai_key("sk-test") { with_anthropic_key("sk-ant-test") { get demo_path("model-fallbacks") } }

    assert_select "h2", text: "役立つケース"
    assert_select "*", text: /max_retries/
    assert_select "*", text: /予備モデルも失敗したとき/
    assert_select "h2", text: "使わない場合に困ること"
    assert_select "*", text: /rescue/
    assert_select "a[href='https://rubyllm.com/error-handling/#model-fallbacks'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/whats-new-in-2-0/#model-fallbacks'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/configuration-connection/#timeouts--retries'][target='_blank']"
    assert_select "a[href='https://rubyllm.com/instrumentation/#usage-events'][target='_blank']"
    assert_select "#fall_back_to_another_provider" do
      assert_select "pre code", text: /RubyLLM\.context/
      assert_select "pre code", text: /with_fallbacks\(@fallback_model\)/
      assert_select "pre code", text: /after_fallback/
      assert_select "textarea[name='run[input][inquiry]']", text: /E-61294/
      assert_select "input[type=submit][value='実行する']:not([disabled])"
    end
  end

  test "names the provider whose settings the fallback lacks, and keeps it from running" do
    {
      [ nil, "sk-ant-test" ] => "設定値が足りない（OpenAI）",
      [ "sk-test", nil ] => "設定値が足りない（Anthropic）",
      [ nil, nil ] => "設定値が足りない（OpenAI、Anthropic）"
    }.each do |(openai_key, anthropic_key), availability|
      with_openai_key(openai_key) { with_anthropic_key(anthropic_key) { get root_path } }

      assert_select "[data-demo='model-fallbacks'] [data-availability]", text: availability

      with_openai_key(openai_key) { with_anthropic_key(anthropic_key) { get demo_path("model-fallbacks") } }

      assert_select "#fall_back_to_another_provider [data-availability]", text: availability
      assert_select "#fall_back_to_another_provider input[type=submit][value='実行する'][disabled]"
    end
  end

  test "shows a scenario being prepared without code or input" do
    get demo_path("batches")

    assert_select "#classify_tickets" do
      assert_select "*", text: /準備中/
      assert_select "pre", count: 0
      assert_select "textarea", count: 0
      assert_select "input[type=submit]", count: 0
    end
  end

  # TODO(once every demo has its explanation): remove this test, which then
  # has no demo left to show it on.
  test "says the explanation comes with the scenario when a demo has none yet" do
    get demo_path("batches")

    assert_select "h2", text: "役立つケース", count: 0
    assert_select "*", text: /すぐに応答を返す必要がない/
    assert_select "a[href='https://rubyllm.com/batches/']"
  end

  test "links each document of a scenario before its inputs, in a new tab, in the order of the definition" do
    with_demos(demos_with_documents(TWO_DOCUMENTS)) do
      with_openai_key("sk-test") { get demo_path("documents-demo") }
    end

    assert_select "#answer_from_documents [data-scenario-documents] a[target='_blank'][rel='noopener']" do |links|
      assert_equal [ "返品ポリシー文書（PDF、3 ページ）", "利用規約" ], links.map { |link| link.text.strip }
      assert_equal [ "/documents/return-policy.pdf", "/documents/%E5%88%A9%E7%94%A8%20%E8%A6%8F%E7%B4%84.pdf" ], links.map { |link| link["href"] }
    end
    assert_before "#answer_from_documents [data-scenario-documents]", "#answer_from_documents textarea"
  end

  test "shows no documents for a scenario without them, or with an empty list of them" do
    with_openai_key("sk-test") { get demo_path("responses-api") }

    assert_select "#answer_inquiry textarea"
    assert_select "[data-scenario-documents]", count: 0

    with_demos(demos_with_documents([])) do
      with_openai_key("sk-test") { get demo_path("documents-demo") }
    end

    assert_select "#answer_from_documents textarea"
    assert_select "[data-scenario-documents]", count: 0
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
