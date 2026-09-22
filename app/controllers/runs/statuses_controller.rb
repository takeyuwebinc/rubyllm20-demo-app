module Runs
  # The part of the run page that changes while the run is in progress. The
  # page polls it: the job runs in another process, where a broadcast would
  # not reach the web process's in-process Action Cable adapter.
  class StatusesController < ApplicationController
    def show
      render partial: "runs/details", locals: { run: Demos::Run.find(params[:run_id]) }
    end
  end
end
