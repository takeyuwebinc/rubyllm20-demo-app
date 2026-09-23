module DemosHelper
  AVAILABILITY_LABELS = { runnable: "実行できる", missing_config: "設定値が足りない", preparing: "準備中" }.freeze
  AVAILABILITY_STYLES = {
    runnable: "bg-green-50 text-green-700 ring-green-600/20",
    missing_config: "bg-amber-50 text-amber-800 ring-amber-600/20",
    preparing: "bg-gray-50 text-gray-600 ring-gray-500/10"
  }.freeze

  def availability_badge(availability)
    label = AVAILABILITY_LABELS.fetch(availability.state)
    label += "（#{provider_names(availability.missing_providers)}）" if availability.missing_config?
    tag.span(label, data: { availability: availability.state },
      class: "inline-flex shrink-0 items-center rounded-md px-2 py-1 text-xs font-medium ring-1 ring-inset #{AVAILABILITY_STYLES.fetch(availability.state)}")
  end

  def provider_names(slugs)
    slugs.map { |slug| Demos.provider_name(slug) }.join("、")
  end

  # Paragraphs split on blank lines, with `backticked` spans shown as code.
  def explanation(text, css_class: nil)
    paragraphs = text.split(/\n{2,}/).map do |paragraph|
      parts = paragraph.split("`").each_with_index.map do |part, index|
        index.odd? ? tag.code(part, class: "rounded bg-gray-100 px-1 py-0.5 text-sm") : part
      end
      tag.p(safe_join(parts))
    end
    tag.div(safe_join(paragraphs), class: [ "space-y-3", css_class ])
  end

  # A link, in a new tab, to a document the scenario hands its handler: the
  # file itself, so a reader can check what the answer was based on.
  def document_link(document)
    link_to document.label, document.url, target: "_blank", rel: "noopener", class: "link-quiet"
  end

  # The values to put in a scenario's inputs: what was just refused, else the
  # input of the run the page was opened from, else the defaults.
  def input_values_for(scenario)
    if @run&.scenario_key == scenario.key
      @run.input
    elsif @source_run&.scenario_key == scenario.key
      scenario.input_values(@source_run.input)
    else
      scenario.input_values({})
    end
  end

  # The run just refused, when it was for this scenario.
  def refused_run_for(scenario)
    @run if @run&.scenario_key == scenario.key && @run.errors.any?
  end
end
