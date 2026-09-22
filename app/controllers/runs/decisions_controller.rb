module Runs
  # Takes the person's decision on a tool call the run's chat proposed. The
  # decision goes to the chat's own records, where the job that continues
  # the run reads it in another process.
  class DecisionsController < ApplicationController
    DECISIONS = { "approve" => "approved", "deny" => "denied" }.freeze

    def create
      @run = Demos::Run.find(params[:run_id])
      @decision_refused = refusal_reason(@run)
      # Refused with 422: Turbo ignores a 2xx page in answer to a form.
      return render "runs/show", status: :unprocessable_entity if @decision_refused

      decision = DECISIONS.fetch(params[:decision])
      @run.scenario.decide(Chat.find(@run.chat_id), params[:tool_call_id], approved: decision == "approved")
      @run.resume!(params[:tool_call_id], decision)
      redirect_to run_path(@run)
    end

    private

    def refusal_reason(run)
      if !run.awaiting_approval?
        "この実行は承認待ちではない"
      elsif run.approval_request(params[:tool_call_id]).nil?
        "その提案はこの実行にない"
      elsif !DECISIONS.key?(params[:decision])
        "決定は承認か却下のどちらかである"
      elsif run.scenario.nil?
        "代表シナリオの定義がないため、続きを実行できない"
      end
    end
  end
end
