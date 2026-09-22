class DemosController < ApplicationController
  include DemoPage

  def index
    @demos = Demos::Catalog.demos
  end

  def show
    load_demo_page(params[:key])
    @source_run = Demos::Run.find_by(id: params[:from_run]) if params[:from_run].present?
  end
end
