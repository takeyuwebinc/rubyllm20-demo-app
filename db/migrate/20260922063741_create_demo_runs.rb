class CreateDemoRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_runs, comment: "代表シナリオの実行の履歴。失敗した実行も残す" do |t|
      t.string :scenario_key, null: false, comment: "代表シナリオの識別子（config/demos.yml）。定義から消えても実行は残す"
      t.string :status, null: false, default: "running", comment: "状態（running:実行中, awaiting_approval:承認待ち, succeeded:成功, failed:失敗, cancelled:取り消し）"
      t.json :input, null: false, default: {}, comment: "実行に使った入力。入力の項目ごとの値"
      t.json :result, comment: "結果。形は代表シナリオの結果の種類で決まる"
      t.json :failure, comment: "失敗の内容（プロバイダー名、エラーの種類、プロバイダーが返したメッセージ、原因の候補）"
      t.string :conversation_id, null: false, comment: "Sentry が複数のトレースを 1 つのやり取りにまとめるための ID"
      t.json :trace_ids, null: false, default: [], comment: "この実行に属する OpenTelemetry のトレース ID。結果が後から届く機能とジョブのやり直しで複数になる"
      t.datetime :started_at, comment: "ジョブが代表シナリオを始めた日時。ジョブが再び実行されたことを見分ける"
      t.datetime :finished_at, comment: "成功、失敗、取り消しのいずれかになった日時"
      t.timestamps
    end

    add_index :demo_runs, :conversation_id, unique: true, name: "idx_demo_runs_conversation_id"
  end
end
