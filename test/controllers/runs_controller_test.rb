require "test_helper"

class RunsControllerTest < ActionDispatch::IntegrationTest
  SENTRY = { "SENTRY_ORG" => "example-org", "SENTRY_DSN" => "https://public-key@o1.ingest.sentry.io/42" }.freeze
  NO_SENTRY = { "SENTRY_ORG" => "", "SENTRY_DSN" => "" }.freeze
  TRACE_IDS = %w[11111111111111111111111111111111 22222222222222222222222222222222].freeze

  test "shows a running run, polls it, and says to check the worker" do
    run = create_run

    get run_path(run)

    assert_response :success
    assert_select "h1", text: "顧客からの問い合わせに回答する"
    assert_select "[data-run-status]", text: "実行中"
    assert_select "[data-controller='poll'][data-poll-active-value='true'][data-poll-url-value=?]", run_status_path(run)
    assert_select "*", text: /ワーカー/
  end

  test "shows the answer and the model that gave it" do
    run = create_run.tap { |r| r.succeed!({ "answer" => "Your order ships tomorrow.", "model" => "gpt-5-nano-2025-08-07" }) }

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-controller='poll'][data-poll-active-value='false']"
    assert_select "*", text: "Your order ships tomorrow."
    assert_select "*", text: /gpt-5-nano-2025-08-07/
  end

  test "shows the ticket workflow's result under headings named and ordered like its steps" do
    run = create_ticket_workflow_run("verdict" => "要修正", "findings" => [ "交換の条件を案内する", "連絡先を添える" ])

    get run_path(run)

    assert_select "[data-ticket-workflow] h2" do |headings|
      assert_equal %w[分類 回答の下書き レビュー], headings.map { |heading| heading.text.strip }
    end
    assert_select "[data-ticket-workflow]" do
      assert_select "*", text: "商品の不具合"
      assert_select "*", text: "電源が入らないという訴えのため"
      assert_select "*", text: /ご不便をおかけしております/
      assert_select "*", text: "要修正"
      assert_select "li", text: "交換の条件を案内する"
      assert_select "li", text: "連絡先を添える"
      assert_select "*", text: /gpt-5-nano-2025-08-07/
      assert_select "*", text: "指摘なし", count: 0
    end
  end

  test "says the review found nothing when the draft passed" do
    run = create_ticket_workflow_run("verdict" => "合格", "findings" => [])

    get run_path(run)

    assert_select "[data-ticket-workflow]" do
      assert_select "*", text: "合格"
      assert_select "*", text: "指摘なし"
      assert_select "li", count: 0
    end
  end

  test "asks for a decision on the proposed refund and stops polling" do
    run = create_awaiting_run(order_id: 7)

    get run_path(run)

    assert_select "[data-run-status]", text: "承認待ち"
    assert_select "[data-controller='poll'][data-poll-active-value='false']"
    assert_select "[data-approval]" do
      assert_select "code", text: "issue_refund"
      assert_select "dt", text: "order_id"
      assert_select "dd", text: "7"
      assert_select "dt", text: "reason"
      assert_select "dd", text: "商品が破損していた"
      assert_select "form[action=?] button[type=submit].btn-primary", run_decision_path(run), text: "承認する"
      assert_select "form[action=?] button[type=submit].btn-secondary", run_decision_path(run), text: "却下する"
      assert_select "input[name='tool_call_id'][value='call_1']", 2
      assert_select "input[name='decision'][value='approve']"
      assert_select "input[name='decision'][value='deny']"
      assert_select "*", text: /却下するとツールは実行されず/
      assert_select "*", text: /履歴からこの実行を開いて決められる/
    end
  end

  test "shows the decision instead of the buttons for a request already decided, while another waits" do
    run = create_awaiting_run(tool_call_id: "call_2")
    run.update!(approval_requests: [
      { "tool_call_id" => "call_1", "name" => "issue_refund", "arguments" => { "order_id" => 1, "reason" => "最初の提案" }, "decision" => "approved" }
    ] + run.approval_requests)

    get run_path(run)

    assert_select "[data-approval-request='call_1']" do
      assert_select "*", text: /決定: 承認/
      assert_select "button", count: 0
    end
    assert_select "[data-approval-request='call_2']" do
      assert_select "*", text: /決定:/, count: 0
      assert_select "button", text: "承認する"
      assert_select "button", text: "却下する"
    end
  end

  test "drops the approval section once the run continues" do
    run = create_awaiting_run
    run.resume!("call_1", "approved")

    get run_path(run)

    assert_select "[data-run-status]", text: "実行中"
    assert_select "[data-controller='poll'][data-poll-active-value='true']"
    assert_select "[data-approval]", count: 0
    assert_select "button", text: "承認する", count: 0
  end

  test "shows the approved refund: the proposal, the decision, the order, and the answer" do
    run = create_refund_run("approved", order_status: "refunded", refund_reason: "商品が破損していた", refunded_at: "2026-09-22T10:00:00+09:00")

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-refund-decision]" do
      assert_select "[data-proposal] code", text: "issue_refund"
      assert_select "[data-proposal] dd", text: "7"
      assert_select "[data-decision]", text: "承認"
      assert_select "[data-order]" do
        assert_select "dd", text: "注文番号 C-1、7,980 円"
        assert_select "dd", text: "返金済み"
        assert_select "dd", text: "商品が破損していた"
        assert_select "dd", text: "2026-09-22 10:00:00"
      end
      assert_select "*", text: "返金を承りました。"
      assert_select "*", text: /gpt-5-nano-2025-08-07/
    end
  end

  test "shows the denied refund with the order still paid" do
    run = create_refund_run("denied", order_status: "paid")

    get run_path(run)

    assert_select "[data-refund-decision]" do
      assert_select "[data-decision]", text: "却下"
      assert_select "[data-order] dd", text: "支払い済み"
      assert_select "[data-order] dd", text: "返金済み", count: 0
    end
  end

  test "says when the model proposed no refund" do
    run = create_run(scenario_key: "approve_refund", input: { "inquiry" => "x", "order" => "y" })
    run.succeed!({ "answer" => "返金の対象ではありません。", "order" => order_result("paid"), "model" => "gpt-5-nano-2025-08-07" })

    get run_path(run)

    assert_select "[data-refund-decision]" do
      assert_select "*", text: "返金の提案なし"
      assert_select "[data-decision]", count: 0
      assert_select "[data-order] dd", text: "支払い済み"
    end
  end

  test "says when the order the model named was not found" do
    run = create_refund_run("approved", order: nil)

    get run_path(run)

    assert_select "[data-refund-decision]" do
      assert_select "*", text: "注文が見つからない"
      assert_select "[data-order]", count: 0
    end
  end

  test "shows the web search answer with the searches, the sources, and the model" do
    run = create_web_search_run(
      "searches" => [
        { "type" => "web_search_call", "action" => "search", "queries" => [ "特定商取引法 改正", "返品特約 表示" ], "url" => nil },
        { "type" => "web_search_call", "action" => "open_page", "queries" => [], "url" => "https://www.caa.go.jp/policies/" }
      ],
      "citations" => [
        { "url" => "https://www.caa.go.jp/policies/", "title" => "特定商取引法ガイド", "text" => "返品の特約の表示", "start_index" => 0, "end_index" => 8 }
      ]
    )

    get run_path(run)

    assert_select "[data-web-search-answer]" do
      assert_select "h2" do |headings|
        assert_equal %w[回答 行われた検索 出典], headings.map { |heading| heading.text.strip }
      end
      assert_select "*", text: "返品の特約の表示が変わりました。"
      assert_select "[data-search]", 2
      assert_select "[data-search] code", text: "search"
      assert_select "[data-search]", text: /特定商取引法 改正/
      assert_select "[data-search]", text: /返品特約 表示/
      assert_select "[data-search] code", text: "open_page"
      assert_select "[data-search] a[href='https://www.caa.go.jp/policies/'][target='_blank'][rel='noopener']"
      assert_select "[data-citation] a[href='https://www.caa.go.jp/policies/'][target='_blank'][rel='noopener']", text: "特定商取引法ガイド"
      assert_select "[data-citation]", text: %r{https://www\.caa\.go\.jp/policies/}
      assert_select "[data-citation]", text: /返品の特約の表示/
      assert_select "*", text: /gpt-5-nano-2025-08-07/
      assert_select "*", text: "検索なし", count: 0
      assert_select "*", text: "出典なし", count: 0
    end
  end

  test "shows a URL the model returned that is neither http nor https as text, and the rest as usual" do
    run = create_web_search_run(
      "searches" => [ { "type" => "web_search_call", "action" => "open_page", "queries" => [], "url" => "javascript:alert(1)" } ],
      "citations" => [
        { "url" => "javascript:alert(2)", "title" => "不正な出典", "text" => "返品の特約の表示" },
        { "url" => "https://www.caa.go.jp/", "title" => "消費者庁", "text" => nil }
      ]
    )

    get run_path(run)

    assert_select "a[href^='javascript']", count: 0
    assert_select "[data-web-search-answer]" do
      assert_select "*", text: "返品の特約の表示が変わりました。"
      assert_select "[data-search]", text: /javascript:alert\(1\)/
      assert_select "[data-citation]", text: /不正な出典/
      assert_select "[data-citation]", text: /javascript:alert\(2\)/
      assert_select "[data-citation] a[href='https://www.caa.go.jp/']", text: "消費者庁"
      assert_select "*", text: /gpt-5-nano-2025-08-07/
    end
  end

  test "says when the model neither searched nor cited, and still shows the answer" do
    run = create_web_search_run("searches" => [], "citations" => [])

    get run_path(run)

    assert_select "[data-web-search-answer]" do
      assert_select "*", text: "返品の特約の表示が変わりました。"
      assert_select "*", text: "検索なし"
      assert_select "*", text: "出典なし"
      assert_select "[data-search]", count: 0
      assert_select "[data-citation]", count: 0
    end
  end

  test "links a source without a title by its URL, and names a source without a URL by its title" do
    run = create_web_search_run("citations" => [
      { "url" => "https://example.com/returns", "title" => nil, "text" => nil },
      { "url" => nil, "title" => "URL のない出典", "text" => "返品の特約の表示" }
    ])

    get run_path(run)

    assert_select "[data-citation] a[href='https://example.com/returns']", text: "https://example.com/returns"
    assert_select "[data-citation]", text: /URL のない出典/
    assert_select "[data-citation] a", count: 1
  end

  test "shows a source that has neither a title nor a URL by its cited span alone, and drops the span when there is none" do
    run = create_web_search_run("citations" => [
      { "url" => nil, "title" => nil, "text" => "返品の特約の表示" },
      { "url" => "https://example.com/returns", "title" => "返品について", "text" => nil }
    ])

    get run_path(run)

    assert_select "[data-citation]" do |citations|
      assert_equal 2, citations.size
      assert_equal "回答の該当箇所: 返品の特約の表示", citations.first.text.strip
      assert_select citations.first, "a", count: 0
      assert_select citations.last, "a[href='https://example.com/returns']", text: "返品について"
      assert_no_match(/回答の該当箇所/, citations.last.text)
    end
  end

  test "treats a source whose title is blank as having none and links it by its URL" do
    run = create_web_search_run("citations" => [ { "url" => "https://example.com/returns", "title" => "", "text" => nil } ])

    get run_path(run)

    assert_select "[data-citation] a[href='https://example.com/returns']", text: "https://example.com/returns"
  end

  test "shows a search step without an action by its item type" do
    run = create_web_search_run("searches" => [ { "type" => "web_search_call", "action" => nil, "queries" => [], "url" => nil } ])

    get run_path(run)

    assert_select "[data-search] code", text: "web_search_call"
  end

  test "shows the code execution answer with each step's number, status, code, and printed output, the container, and the model" do
    run = create_code_execution_run([
      code_step("import pandas as pd\nprint(totals)", outputs: [ { "type" => "logs", "logs" => "キッチン家電    11460\n生活家電      28780\n" } ]),
      code_step("print(refunds)", outputs: [ { "type" => "logs", "logs" => "2 11960\n" } ])
    ])

    get run_path(run)

    assert_select "[data-code-execution-answer]" do
      assert_select "h2" do |headings|
        assert_equal %w[回答 実行されたコード], headings.map { |heading| heading.text.strip }
      end
      assert_select "*", text: "カテゴリごとの売上は、キッチン家電が 11,460 円です。"
      assert_select "[data-step]", 2
      assert_select "[data-step-number]" do |numbers|
        assert_equal [ "ステップ 1", "ステップ 2" ], numbers.map { |number| number.text.strip }
      end
      assert_select "[data-step-status]", { text: "completed", count: 2 }
      # Compared on the pre, since assert_select squeezes the whitespace of
      # any other element's text.
      assert_select "[data-step] pre:not([data-output])", text: "import pandas as pd\nprint(totals)" do
        assert_select "code", 1
      end
      assert_select "[data-step] pre code", text: "print(refunds)"
      assert_select "[data-output='logs']", text: "キッチン家電    11460\n生活家電      28780\n"
      assert_select "[data-output='logs']", text: "2 11960\n"
      assert_select "[data-container]", { text: "cntr_1", count: 1 }
      assert_select "*", text: /gpt-5-nano-2025-08-07/
      assert_select "*", text: "コードの実行なし", count: 0
      assert_select "*", text: "出力なし", count: 0
    end
  end

  test "shows code and outputs the container returned as text, and neither links nor shows the URL of an image output" do
    run = create_code_execution_run([
      code_step("print('<script>alert(1)</script>')", status: "<b>completed</b>", outputs: [
        { "type" => "logs", "logs" => "<img src=x onerror=alert(2)>\n" },
        { "type" => "image", "url" => "javascript:alert(3)" }
      ])
    ])

    get run_path(run)

    assert_select "[data-code-execution-answer]" do
      assert_select "script", count: 0
      assert_select "img", count: 0
      assert_select "b", count: 0
      assert_select "[data-step] pre code", text: "print('<script>alert(1)</script>')"
      assert_select "[data-output='logs']", text: "<img src=x onerror=alert(2)>\n"
      assert_select "[data-step-status]", text: "<b>completed</b>"
      assert_select "[data-output='image']", text: "画像の出力（このアプリでは取得しない）"
    end
    assert_select "a[href^='javascript']", count: 0
    assert_no_match(/alert\(3\)/, response.body)
  end

  test "says when the model ran no code, shows no container, and still shows the answer" do
    run = create_code_execution_run([])

    get run_path(run)

    assert_select "[data-code-execution-answer]" do
      assert_select "*", text: "カテゴリごとの売上は、キッチン家電が 11,460 円です。"
      assert_select "*", text: "コードの実行なし"
      assert_select "[data-step]", count: 0
      assert_select "[data-container]", count: 0
      assert_select "*", text: /コンテナ/, count: 0
    end
  end

  test "says when a step printed nothing, and names image and unknown outputs without their content" do
    run = create_code_execution_run([
      code_step("x = 1", outputs: []),
      code_step("plot()", outputs: [ { "type" => "image", "url" => "https://example.com/plot.png" }, { "type" => "files", "files" => [ { "name" => "a.csv" } ] } ])
    ])

    get run_path(run)

    assert_select "[data-step]" do |steps|
      assert_select steps.first, "*", text: "出力なし"
      assert_select steps.first, "[data-output]", count: 0
      assert_select steps.last, "[data-output='image']", text: "画像の出力（このアプリでは取得しない）"
      assert_select steps.last, "[data-output='other']", text: "その他の出力（files）"
      assert_select steps.last, "*", text: "出力なし", count: 0
    end
    assert_select "a[href='https://example.com/plot.png']", count: 0
    assert_no_match %r{example\.com/plot\.png}, response.body
    assert_no_match(/a\.csv/, response.body)
  end

  test "shows a step without code by its item type alone" do
    run = create_code_execution_run([ code_step(nil, outputs: [ { "type" => "logs", "logs" => "hidden\n" } ]) ])

    get run_path(run)

    assert_select "[data-step]" do
      assert_select "[data-step-type]", text: "code_interpreter_call"
      assert_select "pre", count: 0
      assert_select "[data-output]", count: 0
      assert_select "*", text: "出力なし", count: 0
    end
  end

  test "shows a step's status only when it has one, and as the provider returned it" do
    run = create_code_execution_run([ code_step("x = 1", status: nil), code_step("y = 2", status: "failed") ])

    get run_path(run)

    assert_select "[data-step]" do |steps|
      assert_select steps.first, "[data-step-status]", count: 0
      assert_select steps.last, "[data-step-status]", text: "failed"
    end
  end

  test "shows each container once, and none when no step names one" do
    run = create_code_execution_run([ code_step("a = 1", container_id: "cntr_1"), code_step("b = 2", container_id: "cntr_1"), code_step("c = 3", container_id: "cntr_2"), code_step("d = 4", container_id: nil) ])

    get run_path(run)

    assert_select "[data-container]" do |containers|
      assert_equal %w[cntr_1 cntr_2], containers.map { |container| container.text.strip }
    end

    run = create_code_execution_run([ code_step("a = 1", container_id: nil), code_step("b = 2", container_id: nil) ])

    get run_path(run)

    assert_select "[data-step]", 2
    assert_select "[data-container]", count: 0
    assert_select "[data-code-execution-answer] *", text: /コンテナ/, count: 0
  end

  test "plays the generated speech, offers it to save, and says it is AI-generated" do
    run = create_speech_run

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_shows_speech(run)
  end

  test "says the speech is missing when its attachment is gone, and shows the rest" do
    run = create_speech_run
    run.generated_files.sole.purge

    get run_path(run)

    assert_select "[data-speech]" do
      assert_select "[data-speech-missing]", text: "音声が見つからない"
      assert_select "audio", count: 0
      assert_select "a", text: "音声を保存する", count: 0
      assert_select "dd", text: "gpt-4o-mini-tts"
      assert_select "dd", text: "marin"
      assert_select "dd", text: "mp3"
      assert_select "dd", text: "16 文字"
      assert_select "dd", text: "46.9 KB"
      assert_select "*", text: /AI が生成したもの/
    end
  end

  # An audio element plays only what is served inline, and seeks with ranges.
  test "serves the generated speech inline, and in part when a range is asked for" do
    run = create_speech_run

    get rails_blob_path(run.generated_files.sole, only_path: true)
    follow_redirect!

    assert_response :success
    assert_equal "audio/mpeg", response.media_type
    assert_match(/\Ainline/, response.headers["Content-Disposition"])

    get request.url, headers: { "Range" => "bytes=1000-1999" }

    assert_response :partial_content
    assert_equal 1000, response.body.bytesize
  end

  test "marks a run waiting for approval in the history and on its demo" do
    run = create_awaiting_run

    get runs_path
    assert_select "[data-run='#{run.id}'] [data-run-status]", text: "承認待ち"

    get demo_path("tool-approval")
    assert_select "a[href=?] [data-run-status]", run_path(run), text: "承認待ち"
  end

  test "shows the token count, the model's limits, what is left, and that it fits" do
    run = create_token_count_run("input_tokens" => 1_234, "context_window" => 400_000, "max_output_tokens" => 128_000, "remaining" => 398_766, "fits" => true)

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-token-count] [data-verdict]", text: "収まる"
    assert_equal [ "入力トークン数", "1,234" ], token_count_row("input-tokens")
    assert_equal [ "コンテキストウィンドウ", "400,000" ], token_count_row("context-window")
    assert_equal [ "余地", "398,766" ], token_count_row("remaining")
    assert_equal [ "最大出力トークン数", "128,000" ], token_count_row("max-output-tokens")
    assert_select "[data-token-count]", text: /数えたモデル: gpt-5-nano/
    assert_select "[data-token-count] [data-limit-unknown]", count: 0
  end

  test "shows an input over the context window as not fitting, and by how much" do
    run = create_token_count_run("input_tokens" => 401_234, "context_window" => 400_000, "max_output_tokens" => 128_000, "remaining" => -1_234, "fits" => false)

    get run_path(run)

    assert_select "[data-token-count] [data-verdict]", text: "収まらない"
    assert_equal [ "入力トークン数", "401,234" ], token_count_row("input-tokens")
    assert_equal [ "余地", "1,234 トークン超過" ], token_count_row("remaining")
  end

  test "shows an input as large as the context window as not fitting, with nothing left" do
    run = create_token_count_run("input_tokens" => 400_000, "context_window" => 400_000, "max_output_tokens" => 128_000, "remaining" => 0, "fits" => false)

    get run_path(run)

    assert_select "[data-token-count] [data-verdict]", text: "収まらない"
    assert_equal [ "余地", "0" ], token_count_row("remaining")
  end

  test "says the limit is unknown and gives no verdict when the model has no context window" do
    run = create_token_count_run("input_tokens" => 1_234, "context_window" => nil, "max_output_tokens" => 128_000, "remaining" => nil, "fits" => nil)

    get run_path(run)

    assert_select "[data-token-count]" do
      assert_select "[data-limit-unknown]"
      assert_select "[data-verdict]", count: 0
      assert_select "[data-context-window]", count: 0
      assert_select "[data-remaining]", count: 0
      assert_select "dt", text: "コンテキストウィンドウ", count: 0
      assert_select "dt", text: "余地", count: 0
    end
    assert_equal [ "入力トークン数", "1,234" ], token_count_row("input-tokens")
    assert_equal [ "最大出力トークン数", "128,000" ], token_count_row("max-output-tokens")
    assert_select "[data-token-count]", text: /数えたモデル: gpt-5-nano/
  end

  test "leaves out the maximum output when the model has none" do
    known = create_token_count_run("input_tokens" => 1_234, "context_window" => 400_000, "max_output_tokens" => nil, "remaining" => 398_766, "fits" => true)
    unknown = create_token_count_run("input_tokens" => 1_234, "context_window" => nil, "max_output_tokens" => nil, "remaining" => nil, "fits" => nil)

    get run_path(known)
    assert_select "[data-token-count] [data-verdict]", text: "収まる"
    assert_select "[data-token-count] [data-max-output-tokens]", count: 0
    assert_select "[data-token-count] dt", text: "最大出力トークン数", count: 0

    get run_path(unknown)
    assert_select "[data-token-count] [data-limit-unknown]"
    assert_select "[data-token-count] [data-max-output-tokens]", count: 0
    assert_select "[data-token-count] dt", text: "最大出力トークン数", count: 0
  end

  test "shows the fallback answer, the model that gave it, the main model with its host, and the switch" do
    run = create_fallback_run([ fallback_record ])

    get run_path(run)

    assert_select "[data-fallback-answer]" do
      assert_select "*", text: "配送予定日は注文履歴から確認できます。"
      assert_select "[data-answered-by]", text: /claude-haiku-4-5-20251001/
      assert_select "[data-primary-model]", text: "gpt-5-nano"
      assert_select "[data-primary-api-base]", text: "https://api.openai.invalid/v1"
      assert_select "[data-no-fallback]", count: 0
      assert_select "[data-fallback]", 1 do
        assert_select "*", text: /試行 1/
        assert_select "[data-fallback-from]", text: "OpenAI gpt-5-nano"
        assert_select "[data-fallback-to]", text: "Anthropic claude-haiku-4-5"
        assert_select "[data-error-kind]", text: "接続の失敗"
        assert_select "code", text: "Faraday::ConnectionFailed"
        assert_select "*", text: /api\.openai\.invalid:443/
        assert_select "[data-fallback-outcome]", text: "予備モデルが応答した"
      end
    end
  end

  # The switch is what the demo is about, so a long answer must not push it
  # out of sight.
  test "puts the model that answered and the switches above the answer" do
    get run_path(create_fallback_run([ fallback_record ]))

    assert_before "[data-answered-by]", "[data-answer]"
    assert_before "[data-fallback]", "[data-answer]"

    get run_path(create_fallback_run([], model: "gpt-5-nano-2025-08-07"))

    assert_before "[data-no-fallback]", "[data-answer]"
  end

  test "says the main model answered when nothing fell back" do
    run = create_fallback_run([], model: "gpt-5-nano-2025-08-07")

    get run_path(run)

    assert_select "[data-fallback-answer]" do
      assert_select "[data-answered-by]", text: /gpt-5-nano-2025-08-07/
      assert_select "[data-no-fallback]", text: /主モデルが応答した/
      assert_select "[data-fallback]", count: 0
    end
  end

  test "names an error outside the failure kinds by its class alone" do
    run = create_fallback_run([ fallback_record(error_class: "RubyLLM::ToolCallParseError") ])

    get run_path(run)

    assert_select "[data-fallback]" do
      assert_select "[data-error-kind]", count: 0
      assert_select "code", text: "RubyLLM::ToolCallParseError"
    end
  end

  test "shows a switch whose fallback model failed as failed" do
    run = create_fallback_run([ fallback_record(succeeded: false) ])

    get run_path(run)

    assert_select "[data-fallback] [data-fallback-outcome]", text: "予備モデルも失敗した"
  end

  test "shows what failed, where, and the likely causes" do
    run = create_run.tap { |r| r.fail_with!(RubyLLM::RateLimitError.new("You exceeded your current quota")) }

    get run_path(run)

    assert_select "[data-run-status]", text: "失敗"
    assert_select "[data-failure]" do
      assert_select "*", text: /レート制限/
      assert_select "*", text: /OpenAI/
      assert_select "*", text: /You exceeded your current quota/
      assert_select "*", text: /残高/
    end
  end

  test "shows the input as it was sent" do
    get run_path(create_run)

    assert_select "*", text: "顧客からの問い合わせ文"
    assert_select "*", text: "Where is my order?"
  end

  test "opens the newest trace first, the older ones and the conversation beside it" do
    run = create_run(trace_ids: %w[11111111111111111111111111111111 22222222222222222222222222222222])

    with_env(SENTRY) { get run_path(run) }

    assert_select "a.btn-primary[href*='/explore/traces/trace/22222222222222222222222222222222/']", text: "Sentry でトレースを開く"
    assert_select "a.btn-secondary[href*='/explore/traces/trace/11111111111111111111111111111111/']"
    assert_select "a[href*='/explore/agents/conversations/#{run.conversation_id}/']", text: "Sentry で会話を開く"
  end

  test "offers only the conversation when no trace was recorded" do
    with_env(SENTRY) { get run_path(create_run) }

    assert_select "a", text: "Sentry でトレースを開く", count: 0
    assert_select "a", text: "Sentry で会話を開く"
  end

  test "puts the Sentry links above the ticket workflow's result" do
    run = create_ticket_workflow_run("verdict" => "合格", "findings" => [])
    run.update!(trace_ids: TRACE_IDS)

    with_env(SENTRY) { get run_path(run) }

    assert_select "[data-run-result] [data-ticket-workflow]"
    assert_before "[data-sentry-links]", "[data-run-result]"
    assert_select "[data-sentry-links] a.btn-primary", text: "Sentry でトレースを開く"
  end

  test "puts the Sentry links above the refund's result" do
    run = create_refund_run("approved", order_status: "refunded")
    run.update!(trace_ids: TRACE_IDS)

    with_env(SENTRY) { get run_path(run) }

    assert_select "[data-run-result] [data-refund-decision]"
    assert_before "[data-sentry-links]", "[data-run-result]"
    assert_select "[data-sentry-links] a.btn-primary", text: "Sentry でトレースを開く"
  end

  test "puts the Sentry links above the decision, leaving 承認する the only primary action" do
    run = create_awaiting_run
    run.update!(trace_ids: TRACE_IDS)

    with_env(SENTRY) { get run_path(run) }

    assert_before "[data-sentry-links]", "[data-approval]"
    assert_select "[data-sentry-links] a.btn-secondary", 3
    assert_select "[data-sentry-links] a:not(.btn-secondary)", count: 0
    assert_select ".btn-primary" do |primaries|
      assert_equal [ "承認する" ], primaries.map { |primary| primary.text.strip }
    end
    assert_select "[data-approval] button.btn-secondary", text: "却下する"
  end

  test "puts the Sentry links above what failed" do
    run = create_run(trace_ids: TRACE_IDS.first(1))
    run.fail_with!(RubyLLM::RateLimitError.new("You exceeded your current quota"))

    with_env(SENTRY) { get run_path(run) }

    assert_before "[data-sentry-links]", "[data-failure]"
  end

  test "shows the Sentry links beside the status of a running run, which keeps polling" do
    run = create_run

    with_env(SENTRY) { get run_path(run) }

    assert_select "[data-run-status-row] [data-run-status]", text: "実行中"
    assert_select "[data-run-status-row]", text: /実行を指示してから \d+ 秒/
    assert_select "*", text: /ワーカー/
    assert_select "[data-run-status-row]", text: /ワーカー/, count: 0
    assert_select "[data-run-status-row] [data-sentry-links] a", 1
    assert_select "[data-sentry-links] a", text: "Sentry で会話を開く"
    assert_select "[data-controller='poll'][data-poll-active-value='true']"
  end

  test "explains the settings the Sentry links need, in the place of the links" do
    run = create_run.tap { |r| r.succeed!({ "answer" => "Your order ships tomorrow.", "model" => "gpt-5-nano-2025-08-07" }) }

    with_env(NO_SENTRY) { get run_path(run) }

    assert_select "[data-run-status-row] [data-run-status]"
    assert_select "[data-run-status-row] [data-sentry-links]", text: /\.env.*SENTRY_ORG.*SENTRY_DSN/
    assert_select "[data-sentry-links] a", count: 0
    assert_before "[data-run-status]", "[data-sentry-links]"
    assert_before "[data-sentry-links]", "[data-run-result]"
  end

  test "opens the demo with this input, or the demo alone" do
    run = create_run

    get run_path(run)

    assert_select "a[href=?]", demo_path("responses-api", from_run: run.id, anchor: "answer_inquiry"), text: "この入力でデモを開く"
    assert_select "a[href=?]", demo_path("responses-api"), text: "デモに戻る"
  end

  test "shows the key of a scenario that is no longer defined, without links to its demo" do
    run = create_run(scenario_key: "removed_scenario")

    get run_path(run)

    assert_select "h1", text: "removed_scenario"
    assert_select "a", text: "この入力でデモを開く", count: 0
    assert_select "a", text: "デモに戻る", count: 0
  end

  test "says a missing run was not found and leads to the history" do
    get run_path(id: 0)

    assert_response :not_found
    assert_select "a[href=?]", runs_path
  end

  test "lists runs newest first" do
    older = create_run(created_at: 2.minutes.ago)
    newer = create_run(created_at: 1.minute.ago)

    get runs_path

    assert_select "[data-run]" do |rows|
      assert_equal [ newer.id, older.id ].map(&:to_s), rows.map { |row| row["data-run"] }
    end
  end

  test "narrows the history to one demo" do
    create_run
    other = create_run(scenario_key: "removed_scenario")

    get runs_path(demo: "responses-api")

    assert_select "[data-run]", 1
    assert_select "[data-run='#{other.id}']", 0
  end

  test "leads to the demos when there is no run at all" do
    get runs_path

    assert_select "*", text: /まだ実行がない/
    assert_select "main a[href=?]", root_path
  end

  test "leads to the demo when it has no run" do
    get runs_path(demo: "citations")

    assert_select "*", text: /このデモの実行はまだない/
    assert_select "main a[href=?]", demo_path("citations")
  end

  test "splits a long history into pages" do
    21.times { |i| create_run(created_at: i.minutes.ago) }

    get runs_path

    assert_select "[data-run]", 20
    assert_select "a[href=?]", runs_path(page: 2)
  end

  private

  def order_result(status, refund_reason: nil, refunded_at: nil)
    { "description" => "注文番号 C-1、7,980 円", "status" => status, "refund_reason" => refund_reason, "refunded_at" => refunded_at }
  end

  # A finished refund run: it stopped once for the decision, then the model
  # answered.
  def create_refund_run(decision, order: :from_status, order_status: "paid", refund_reason: nil, refunded_at: nil)
    run = create_awaiting_run(order_id: 7)
    run.resume!("call_1", decision)
    order = order_result(order_status, refund_reason:, refunded_at:) if order == :from_status
    run.succeed!({ "answer" => "返金を承りました。", "order" => order, "model" => "gpt-5-nano-2025-08-07" })
    run
  end

  def create_web_search_run(result)
    run = create_run(scenario_key: "search_web", input: { "question" => "返品の制度は変わりましたか" })
    run.succeed!({
      "answer" => "返品の特約の表示が変わりました。",
      "model" => "gpt-5-nano-2025-08-07",
      "searches" => [],
      "citations" => []
    }.merge(result))
    run
  end

  def create_code_execution_run(steps)
    run = create_run(scenario_key: "run_code", input: { "orders" => "注文番号,金額\nE-1,4980", "request" => "合計を求めてください" })
    run.succeed!({ "answer" => "カテゴリごとの売上は、キッチン家電が 11,460 円です。", "model" => "gpt-5-nano-2025-08-07", "steps" => steps })
    run
  end

  def code_step(code, status: "completed", container_id: "cntr_1", outputs: [])
    { "type" => "code_interpreter_call", "status" => status, "container_id" => container_id, "code" => code, "outputs" => outputs }
  end

  # The label and the value of one row of the token count.
  def token_count_row(field)
    value = css_select("[data-token-count] [data-#{field}]").sole
    [ value.previous_element.text.strip, value.text.strip ]
  end

  def create_token_count_run(result)
    run = create_run(scenario_key: "count_tokens", input: { "instructions" => "サポートの担当者です。", "question" => "返品できますか。" })
    run.succeed!(result.merge("model" => "gpt-5-nano"))
    run
  end

  def create_ticket_workflow_run(review)
    run = create_run(scenario_key: "run_ticket_workflow", input: { "ticket" => "電気ケトルの電源が入りません。" })
    run.succeed!({
      "category" => "商品の不具合",
      "reason" => "電源が入らないという訴えのため",
      "draft" => "ご不便をおかけしております。交換の手続きをご案内します。",
      "model" => "gpt-5-nano-2025-08-07"
    }.merge(review))
    run
  end

  # A fallback run as the action records it: the answer, the model that gave
  # it, the main model with the host its requests were sent to, and each
  # switch to the fallback model.
  def create_fallback_run(fallbacks, model: "claude-haiku-4-5-20251001")
    run = create_run(scenario_key: "fall_back_to_another_provider", input: { "inquiry" => "配送予定日を教えてください。" })
    run.succeed!({
      "answer" => "配送予定日は注文履歴から確認できます。",
      "model" => model,
      "primary_model" => "gpt-5-nano",
      "primary_api_base" => "https://api.openai.invalid/v1",
      "fallbacks" => fallbacks
    })
    run
  end

  def fallback_record(error_class: "Faraday::ConnectionFailed", succeeded: true)
    {
      "attempt" => 1,
      "from" => { "provider" => "openai", "model" => "gpt-5-nano" },
      "to" => { "provider" => "anthropic", "model" => "claude-haiku-4-5" },
      "error_class" => error_class,
      "error_message" => "Failed to open TCP connection to api.openai.invalid:443 (getaddrinfo(3): Name or service not known)",
      "succeeded" => succeeded
    }
  end
end
