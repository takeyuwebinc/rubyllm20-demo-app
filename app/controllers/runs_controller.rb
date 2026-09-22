class RunsController < ApplicationController
  PER_PAGE = 20

  def index
    @demo = Demos::Catalog.demo(params[:demo]) if params[:demo].present?
    runs = @demo ? Demos::Run.for_demo(@demo) : Demos::Run.all
    @runs = runs.latest_first.page(params[:page]).per(PER_PAGE)
  end

  def show
    @run = Demos::Run.find_by(id: params[:id])
    render :not_found, status: :not_found unless @run
  end
end
