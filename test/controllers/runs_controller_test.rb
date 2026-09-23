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

  test "shows the batch a running run left with OpenAI, says when it is checked next, and keeps polling" do
    run = create_batch_run

    get run_path(run)

    assert_select "[data-run-status]", text: "実行中"
    assert_select "[data-controller='poll'][data-poll-active-value='true']"
    assert_select "[data-remote-job]" do
      assert_select "*", text: /投入済み/
      assert_select "[data-remote-job-id]", text: "batch_69d2"
      assert_select "dd", text: "OpenAI"
      assert_select "[data-remote-job-status]", text: "in_progress"
      assert_select "[data-remote-job-counts]", text: "成功 1 件、失敗 0 件、全 2 件"
      assert_select "[data-remote-job-submitted-at]", text: Time.zone.parse(run.remote_job["submitted_at"]).strftime("%Y-%m-%d %H:%M:%S")
      assert_select "[data-remote-job-checked-at]", text: Time.zone.parse(run.remote_job["checked_at"]).strftime("%Y-%m-%d %H:%M:%S")
      assert_select "[data-remote-job-next-check]", text: /約 1 分/
      assert_select "*", text: /画面を離れても/
      assert_select "[data-remote-job-check-failure]", count: 0
    end
    assert_select "*", text: /ワーカー/
    assert_before "[data-run-status-row]", "[data-remote-job]"
  end

  test "shows why the last check could not reach OpenAI" do
    run = create_batch_run
    travel_to(Time.zone.local(2026, 9, 23, 11, 0, 0)) { run.record_remote_check_failure!(Faraday::ConnectionFailed.new("Failed to open TCP connection")) }

    get run_path(run)

    assert_select "[data-remote-job-check-failure]" do
      assert_select "*", text: /接続の失敗/
      assert_select "*", text: /Failed to open TCP connection/
      assert_select "*", text: /2026-09-23 11:00:00/
    end
  end

  test "shows a dash for counts not reported yet, and a batch never checked as not checked" do
    run = create_batch_run(checked: false)
    run.update!(remote_job: run.remote_job.merge("request_counts" => nil))

    get run_path(run)

    assert_select "[data-remote-job-counts]", text: "—"
    assert_select "[data-remote-job-checked-at]", text: "未確認"
  end

  test "shows no batch for a run that left none with a provider" do
    get run_path(create_run)

    assert_select "[data-remote-job]", count: 0
  end

  test "shows the classified tickets of a collected batch, in the order they were submitted" do
    run = create_batch_run(raw_status: "completed")
    run.succeed!(batch_result([
      [ "荷物が届かない。", "succeeded", "配送", "未着の問い合わせのため" ],
      [ "返品したい。", "succeeded", "返品・返金", "返品の申し出のため" ]
    ]))

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-controller='poll'][data-poll-active-value='false']"
    assert_select "[data-remote-job]" do
      assert_select "[data-remote-job-next-check]", count: 0
      assert_select "*", text: /画面を離れても/, count: 0
    end
    assert_select "[data-run-result] [data-batch-classification]" do
      assert_select "[data-batch-status]", text: "completed"
      assert_select "[data-batch-counts]", text: "成功 2 件、失敗 0 件、全 2 件"
      assert_select "[data-batch-id]", text: "batch_69d2"
      assert_select "[data-batch-model]", text: "gpt-5-nano-2025-08-07"
      assert_select "[data-ticket]", 2
      assert_select "[data-ticket]:nth-of-type(1)" do
        assert_select "[data-ticket-text]", text: "荷物が届かない。"
        assert_select "[data-ticket-status]", text: "成功"
        assert_select "[data-ticket-category]", text: "配送"
        assert_select "[data-ticket-reason]", text: "未着の問い合わせのため"
      end
      assert_select "[data-ticket]:nth-of-type(2) [data-ticket-category]", text: "返品・返金"
    end
    assert_before "[data-sentry-links]", "[data-run-result]"
  end

  test "says a ticket without an answer failed, and that RubyLLM logs why" do
    run = create_batch_run(raw_status: "completed")
    run.succeed!(batch_result([ [ "荷物が届かない。", "succeeded", "配送", "未着のため" ], [ "返品したい。", "failed", nil, nil ] ]))

    get run_path(run)

    assert_select "[data-ticket]:nth-of-type(2)" do
      assert_select "[data-ticket-status]", text: "失敗"
      assert_select "[data-ticket-category]", count: 0
      assert_select "[data-ticket-missing]", text: /回答がない.*RubyLLM のログ/m
    end
  end

  test "shows a batch of one ticket as a list, and a batch whose every ticket failed as a success with failed tickets" do
    run = create_batch_run(raw_status: "completed")
    run.succeed!(batch_result([ [ "荷物が届かない。", "failed", nil, nil ] ], model: nil))

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-batch-classification] [data-ticket]", 1
    assert_select "[data-ticket-status]", text: "失敗"
    assert_select "[data-batch-model]", text: "—"
  end

  test "says a ticket was answered but its answer could not be read as a category" do
    run = create_batch_run(raw_status: "completed")
    run.succeed!(batch_result([ [ "荷物が届かない。", "succeeded", nil, nil ] ]))

    get run_path(run)

    assert_select "[data-ticket]" do
      assert_select "[data-ticket-status]", text: "成功"
      assert_select "[data-ticket-category]", count: 0
      assert_select "[data-ticket-missing]", count: 0
      assert_select "[data-ticket-unreadable]", text: /区分として読めなかった.*会話の記録/m
    end
  end

  test "shows a batch whose every ticket failed as a success, with every ticket failed" do
    run = create_batch_run(raw_status: "completed")
    run.succeed!(batch_result([ [ "荷物が届かない。", "failed", nil, nil ], [ "返品したい。", "failed", nil, nil ] ], model: nil))

    get run_path(run)

    assert_select "[data-run-status]", text: "成功"
    assert_select "[data-batch-counts]", text: "成功 0 件、失敗 2 件、全 2 件"
    assert_select "[data-ticket]", 2
    assert_select "[data-ticket] [data-ticket-status]" do |badges|
      assert_equal %w[失敗 失敗], badges.map { |badge| badge.text.strip }
    end
    assert_select "[data-ticket-missing]", 2
  end

  test "shows why an expired batch failed, and what it finished" do
    run = create_batch_run(raw_status: "expired")
    run.fail!(
      { "provider" => "OpenAI", "kind" => "プロバイダー側の処理の失敗", "raw_status" => "expired",
        "message" => "プロバイダーが返した状態: expired", "hint" => FailureKinds::REMOTE_JOB_FAILED.hint },
      result: batch_result([ [ "荷物が届かない。", "succeeded", "配送", "未着のため" ], [ "返品したい。", "failed", nil, nil ] ], raw_status: "expired")
    )

    with_env(SENTRY) { get run_path(run) }

    assert_select "[data-run-status]", text: "失敗"
    assert_select "[data-failure]" do
      assert_select "*", text: /プロバイダー側の処理の失敗（OpenAI）/
      assert_select "*", text: /expired/
      assert_select "*", text: /24 時間以内に処理されなかった/
    end
    assert_select "[data-run-result] [data-batch-classification]" do
      assert_select "[data-batch-status]", text: "expired"
      assert_select "[data-ticket]:nth-of-type(1) [data-ticket-category]", text: "配送"
      assert_select "[data-ticket]:nth-of-type(2) [data-ticket-status]", text: "失敗"
    end
    assert_before "[data-sentry-links]", "[data-failure]"
    assert_before "[data-failure]", "[data-run-result]"
  end

  test "shows why a cancelled batch was cancelled, what it finished, and that the rest was cancelled" do
    run = create_batch_run(raw_status: "cancelled")
    run.cancel!(
      { "provider" => "OpenAI", "kind" => "プロバイダー側の処理の取り消し", "raw_status" => "cancelled",
        "message" => "プロバイダーが返した状態: cancelled", "hint" => FailureKinds::REMOTE_JOB_CANCELLED.hint },
      result: batch_result([ [ "荷物が届かない。", "succeeded", "配送", "未着のため" ], [ "返品したい。", "cancelled", nil, nil ] ], raw_status: "cancelled")
    )

    get run_path(run)

    assert_select "[data-run-status]", text: "取り消し"
    assert_select "[data-controller='poll'][data-poll-active-value='false']"
    assert_select "[data-failure]" do
      assert_select "*", text: /プロバイダー側の処理の取り消し（OpenAI）/
      assert_select "*", text: /cancelled/
      assert_select "*", text: /バッチが取り消された/
    end
    assert_select "[data-ticket]:nth-of-type(2)" do
      assert_select "[data-ticket-status]", text: "取り消し"
      assert_select "[data-ticket-missing]", text: /取り消された/
    end
  end

  test "shows only why a run failed when it has no result" do
    run = create_run
    run.fail_with!(RubyLLM::RateLimitError.new("You exceeded your current quota"))

    get run_path(run)

    assert_select "[data-failure]", text: /レート制限/
    assert_select "[data-run-result]", count: 0
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

  test "dates each trace link by when its trace was recorded, and a bare trace id by the run's start" do
    started_at = Time.zone.local(2026, 9, 23, 10, 0, 0)
    collected_at = Time.zone.local(2026, 9, 24, 9, 30, 0)
    run = create_run(started_at: started_at, trace_ids: [ "11111111111111111111111111111111", { "id" => "22222222222222222222222222222222", "at" => collected_at.iso8601(3) } ])

    with_env(SENTRY) { get run_path(run) }

    assert_select "a[href*='/trace/22222222222222222222222222222222/'][href*='timestamp=#{collected_at.to_i}']", text: "Sentry でトレースを開く"
    assert_select "a[href*='/trace/11111111111111111111111111111111/'][href*='timestamp=#{started_at.to_i}']", text: "以前のトレース 1"
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
