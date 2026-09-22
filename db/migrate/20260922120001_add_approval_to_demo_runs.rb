class AddApprovalToDemoRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :demo_runs, :chat, foreign_key: true, comment: "承認待ちで止まった実行の会話の記録。決定待ちのツール呼び出しと決定を持つ"
    add_column :demo_runs, :approval_requests, :json, null: false, default: [],
      comment: "利用者に決定を求めたツール呼び出しの控え（tool_call_id, name, arguments, decision）。履歴で提案と決定を示す"
  end
end
