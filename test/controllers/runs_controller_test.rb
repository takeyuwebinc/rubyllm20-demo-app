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

  test "marks the answer where each cited span ends, and lists each source's pages, quote, and a link to its page" do
    run = create_cited_answer_run(
      "answer" => "返品できます。送料はお客様の負担です。",
      "citations" => [
        citation("text" => "返品できます。", "start_index" => 0, "end_index" => 7, "start_page" => 1, "end_page" => 1,
          "cited_text" => "未開封の商品は、理由を問わず返品できます。"),
        citation("text" => "送料はお客様の負担です。", "start_index" => 7, "end_index" => 19, "start_page" => 2, "end_page" => 3,
          "cited_text" => "返送の送料はお客様の負担となります。")
      ]
    )

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-run-result] [data-cited-answer]" do
      assert_select "h2" do |headings|
        assert_equal %w[回答 出典], headings.map { |heading| heading.text.strip }
      end
      assert_select "[data-answer] sup a[href='#citation-1']", text: "[1]"
      assert_select "[data-answer] sup a[href='#citation-2']", text: "[2]"
      assert_select "li[data-citation]" do |items|
        assert_equal %w[citation-1 citation-2], items.map { |item| item["id"] }
      end
      assert_select "#citation-1 [data-pages]", text: "1 ページ"
      assert_select "#citation-1 [data-cited-text]", text: "未開封の商品は、理由を問わず返品できます。"
      assert_select "#citation-1 [data-document] a[href='/documents/return-policy.pdf#page=1'][target='_blank'][rel='noopener']", text: "return-policy.pdf"
      assert_select "#citation-2 [data-pages]", text: "2〜3 ページ"
      assert_select "#citation-2 [data-cited-text]", text: "返送の送料はお客様の負担となります。"
      assert_select "#citation-2 [data-document] a[href='/documents/return-policy.pdf#page=2']", text: "return-policy.pdf"
      assert_select "[data-cited-span]", count: 0
      assert_select "*", text: "出典なし", count: 0
      assert_select "*", text: /応答したモデル: claude-sonnet-5/
    end
    assert_equal "返品できます。[1]送料はお客様の負担です。[2]", css_select("[data-answer]").sole.text
    assert_before "#citation-1 [data-pages]", "#citation-1 [data-cited-text]"
    assert_before "#citation-1 [data-cited-text]", "#citation-1 [data-document]"
  end

  test "lists a source whose end is negative or not a whole number with its span instead of a mark, and escapes the answer and the quotes" do
    run = create_cited_answer_run(
      "answer" => "<b>返品</b>できます。",
      "citations" => [
        citation("text" => "<b>返品</b>", "start_index" => 0, "end_index" => 9, "cited_text" => "<script>alert(1)</script>"),
        citation("text" => "できます。", "end_index" => -1),
        citation("text" => "返品", "end_index" => "9"),
        citation("text" => "できます。", "end_index" => 9.5)
      ]
    )

    get run_path(run)

    assert_equal "<b>返品</b>[1]できます。", css_select("[data-answer]").sole.text
    assert_select "[data-cited-answer]" do
      assert_select "b", count: 0
      assert_select "script", count: 0
      assert_select "[data-answer] sup", 1
      assert_select "#citation-1 [data-cited-text]", text: "<script>alert(1)</script>"
      assert_select "#citation-1 [data-cited-span]", count: 0
      assert_select "#citation-2 [data-cited-span]", text: "回答の該当箇所: できます。"
      assert_select "#citation-3 [data-cited-span]", text: "回答の該当箇所: 返品"
      assert_select "#citation-4 [data-cited-span]", text: "回答の該当箇所: できます。"
    end
  end

  test "says there are no sources and still shows the answer" do
    run = create_cited_answer_run("answer" => "ポリシーには書かれていません。", "citations" => [])

    get run_path(run)

    assert_select "[data-cited-answer]" do
      assert_select "[data-answer]", text: "ポリシーには書かれていません。"
      assert_select "*", text: "出典なし"
      assert_select "[data-citation]", count: 0
      assert_select "sup", count: 0
    end
  end

  test "marks a source that ends with the answer, lists one with no place in the answer by its span, and orders marks at the same place by number" do
    run = create_cited_answer_run(
      "answer" => "返品できます。",
      "citations" => [
        citation("text" => "返品できます。", "end_index" => 7),
        citation("text" => "返品", "end_index" => 2),
        citation("text" => "できます。", "end_index" => 7),
        citation("text" => "範囲の外", "end_index" => 8),
        citation("text" => "位置なし", "end_index" => nil),
        citation("text" => nil, "end_index" => nil)
      ]
    )

    get run_path(run)

    assert_equal "返品[2]できます。[1][3]", css_select("[data-answer]").sole.text
    assert_select "[data-cited-answer]" do
      assert_select "#citation-4 [data-cited-span]", text: "回答の該当箇所: 範囲の外"
      assert_select "#citation-5 [data-cited-span]", text: "回答の該当箇所: 位置なし"
      assert_select "#citation-6 [data-cited-span]", count: 0
      assert_select "[data-cited-span]", 2
    end
  end

  test "shows a page, a range of pages, or no page as each source's pages allow" do
    run = create_cited_answer_run("citations" => [
      citation("start_page" => 2, "end_page" => 2),
      citation("start_page" => 1, "end_page" => 3),
      citation("start_page" => 2, "end_page" => nil),
      citation("start_page" => 3, "end_page" => 2),
      citation("start_page" => nil, "end_page" => nil)
    ])

    get run_path(run)

    assert_select "#citation-1 [data-pages]", text: "2 ページ"
    assert_select "#citation-2 [data-pages]", text: "1〜3 ページ"
    assert_select "#citation-3 [data-pages]", text: "2 ページ"
    assert_select "#citation-4 [data-pages]", text: "3 ページ"
    assert_select "#citation-5 [data-pages]", count: 0
    assert_select "#citation-5 [data-document] a[href='/documents/return-policy.pdf']", text: "return-policy.pdf"
    assert_select "#citation-3 [data-document] a[href='/documents/return-policy.pdf#page=2']"
  end

  test "drops the quote of a source without one, and names a source without a title by the document it was given" do
    run = create_cited_answer_run("citations" => [
      citation("cited_text" => nil),
      citation("cited_text" => ""),
      citation("title" => nil, "start_page" => 3),
      citation("title" => "", "start_page" => 1)
    ])

    get run_path(run)

    assert_select "#citation-1 [data-cited-text]", count: 0
    assert_select "#citation-2 [data-cited-text]", count: 0
    assert_select "#citation-3 [data-document] a[href='/documents/return-policy.pdf#page=3']", text: "return-policy.pdf"
    assert_select "#citation-4 [data-document] a[href='/documents/return-policy.pdf#page=1']", text: "return-policy.pdf"
  end

  test "names a source without a title by the document the run recorded, even when the scenario defines another" do
    run = create_cited_answer_run("document" => "old-return-policy.pdf", "citations" => [ citation("title" => nil) ])

    get run_path(run)

    assert_select "#citation-1 [data-document]", text: "old-return-policy.pdf"
    assert_select "#citation-1 [data-document] a", count: 0
  end

  test "names a source without a link when the scenario defines no document of its filename, and shows the rest" do
    run = create_cited_answer_run("citations" => [
      citation("title" => "old-return-policy.pdf", "start_page" => 1, "cited_text" => "返品を受け付けます。")
    ])

    get run_path(run)

    assert_select "#citation-1 [data-document]", text: "old-return-policy.pdf"
    assert_select "#citation-1 [data-document] a", count: 0
    assert_select "#citation-1 [data-pages]", text: "1 ページ"
    assert_select "#citation-1 [data-cited-text]", text: "返品を受け付けます。"

    run = create_cited_answer_run("citations" => [
      citation("title" => "return-policy.pdf", "start_page" => 1, "cited_text" => "返品を受け付けます。")
    ])

    with_demos(demos_without_policy) { get run_path(run) }

    assert_select "#citation-1 [data-document]", text: "return-policy.pdf"
    assert_select "[data-cited-answer] a[href^='/documents/']", count: 0
    assert_select "[data-run-documents]", count: 0
    assert_select "#citation-1 [data-pages]", text: "1 ページ"
    assert_select "#citation-1 [data-cited-text]", text: "返品を受け付けます。"
  end

  test "shows the result of a cited answer whose scenario is no longer defined as it was recorded, and none while it runs" do
    removed = create_run(scenario_key: "removed_scenario")
    removed.succeed!(cited_answer_result("citations" => [ citation ]))

    get run_path(removed)

    assert_select "[data-cited-answer]", count: 0
    assert_select "[data-run-result] pre", text: /return-policy\.pdf/

    get run_path(create_run(scenario_key: "cite_return_policy", input: { "inquiry" => "返品できますか" }))

    assert_select "[data-run-status]", text: "実行中"
    assert_select "[data-run-result]", count: 0
  end

  test "links the return policy under the input of a cited answer run, and serves it as a PDF" do
    get run_path(create_cited_answer_run)

    assert_select "[data-run-documents] a[href='/documents/return-policy.pdf'][target='_blank']", text: "返品ポリシー文書（PDF、3 ページ）"

    get "/documents/return-policy.pdf"

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert response.body.start_with?("%PDF-")
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

  test "links the documents of the scenario after the input, in a new tab" do
    with_demos(demos_with_documents(TWO_DOCUMENTS)) do
      get run_path(create_run(scenario_key: "answer_from_documents", input: { "inquiry" => "返品できますか" }))
    end

    assert_select "[data-run-documents] a[target='_blank'][rel='noopener']" do |links|
      assert_equal [ "返品ポリシー文書（PDF、3 ページ）", "利用規約" ], links.map { |link| link.text.strip }
      assert_equal [ "/documents/return-policy.pdf", "/documents/%E5%88%A9%E7%94%A8%20%E8%A6%8F%E7%B4%84.pdf" ], links.map { |link| link["href"] }
    end
    assert_match "返品できますか", css_select("[data-run-documents]").sole.previous_element.text
  end

  test "shows no documents on the run page of a scenario without them, or no longer defined" do
    get run_path(create_run)

    assert_select "*", text: "Where is my order?"
    assert_select "[data-run-documents]", count: 0

    with_demos(demos_with_documents([])) do
      get run_path(create_run(scenario_key: "answer_from_documents", input: { "inquiry" => "返品できますか" }))
    end

    assert_select "*", text: "返品できますか"
    assert_select "[data-run-documents]", count: 0

    get run_path(create_run(scenario_key: "removed_scenario"))

    assert_select "[data-run-documents]", count: 0
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

  # A source as the Citations scenario records it, with the given fields in
  # place of those of a quote from the first page of the return policy.
  def citation(overrides = {})
    {
      "title" => "return-policy.pdf", "cited_text" => "商品の到着から 30 日以内であれば、返品を受け付けます。", "text" => "返品できます。",
      "start_index" => nil, "end_index" => nil, "start_page" => 1, "end_page" => 1, "source_index" => 0
    }.merge(overrides)
  end

  def cited_answer_result(result = {})
    { "answer" => "返品できます。", "model" => "claude-sonnet-5", "document" => "return-policy.pdf", "citations" => [] }.merge(result)
  end

  def create_cited_answer_run(result = {})
    run = create_run(scenario_key: "cite_return_policy", input: { "inquiry" => "返品できますか" })
    run.succeed!(cited_answer_result(result))
    run
  end

  # The catalog, with the Citations scenario defining no document.
  def demos_without_policy
    attributes = YAML.load_file(Demos::Catalog::PATH)
    attributes.find { |demo| demo["key"] == "citations" }["scenarios"].sole.delete("documents")
    Demos::Catalog.build(attributes)
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
end
