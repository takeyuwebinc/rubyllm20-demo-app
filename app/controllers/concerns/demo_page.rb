# Loads what the demo page shows, for the controllers that render it.
module DemoPage
  RECENT_RUNS = 5

  private

  def load_demo_page(key)
    @demo = Demos::Catalog.demo(key) or raise ActionController::RoutingError, "No demo #{key}"
    @recent_runs = Demos::Run.for_demo(@demo).latest_first.limit(RECENT_RUNS)
  end
end
