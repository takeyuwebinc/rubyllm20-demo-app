class AddRemoteJobToDemoRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :demo_runs, :remote_job, :json,
      comment: "プロバイダー側に残した処理のうち、完了まで確認して回収するもの（バッチなど）の控え。種類、プロバイダー、投入日時、最後に確かめた状態と件数と日時、最後の確認の失敗。ID は remote_job_id に置く"
  end
end
