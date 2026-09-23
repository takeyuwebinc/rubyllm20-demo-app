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

  test "marks a run waiting for approval in the history and on its demo" do
    run = create_awaiting_run

    get runs_path
    assert_select "[data-run='#{run.id}'] [data-run-status]", text: "承認待ち"

    get demo_path("tool-approval")
    assert_select "a[href=?] [data-run-status]", run_path(run), text: "承認待ち"
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
