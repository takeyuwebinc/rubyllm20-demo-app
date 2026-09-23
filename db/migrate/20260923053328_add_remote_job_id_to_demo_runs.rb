class AddRemoteJobIdToDemoRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :demo_runs, :remote_job_id, :string
  end
end
