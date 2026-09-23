class AddRemoteJobIdToDemoRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :demo_runs, :remote_job_id, :string,
      comment: "プロバイダーに残した処理（動画の生成など）の ID。ジョブが再び動いたとき、投入し直さずにこの ID から完了を待つ"
  end
end
