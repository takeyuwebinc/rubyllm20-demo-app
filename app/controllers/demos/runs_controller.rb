module Demos
  class RunsController < ApplicationController
    include DemoPage

    def create
      load_demo_page(params[:demo_key])
      scenario = @demo.scenarios.find { |candidate| candidate.key == params.dig(:run, :scenario_key) } or
        raise ActionController::RoutingError, "No scenario #{params.dig(:run, :scenario_key)} in #{@demo.key}"

      @run = Run.start(scenario, input_params(scenario))
      if @run.persisted?
        redirect_to run_path(@run)
      else
        render "demos/show", status: :unprocessable_entity
      end
    end

    private

    def input_params(scenario)
      params.fetch(:run, {}).fetch(:input, {}).permit(*scenario.inputs.map(&:name)).to_h
    end
  end
end
