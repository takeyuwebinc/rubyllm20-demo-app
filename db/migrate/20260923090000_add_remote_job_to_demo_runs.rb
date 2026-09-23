class AddRemoteJobToDemoRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :demo_runs, :remote_job, :json,
      comment: "プロバイダー側に残した処理（バッチなど）の控え。種類、識別子、プロバイダー、投入日時、最後に確かめた状態と件数と日時、最後の確認の失敗"
  end
end
