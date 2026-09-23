module RunsHelper
  STATUS_LABELS = {
    "running" => "実行中",
    "awaiting_approval" => "承認待ち",
    "succeeded" => "成功",
    "failed" => "失敗",
    "cancelled" => "取り消し"
  }.freeze
  STATUS_STYLES = {
    "running" => "bg-blue-50 text-blue-700 ring-blue-600/20",
    "awaiting_approval" => "bg-amber-50 text-amber-800 ring-amber-600/20",
    "succeeded" => "bg-green-50 text-green-700 ring-green-600/20",
    "failed" => "bg-red-50 text-red-700 ring-red-600/20",
    "cancelled" => "bg-gray-50 text-gray-600 ring-gray-500/10"
  }.freeze

  DECISION_LABELS = { "approved" => "承認", "denied" => "却下" }.freeze
  ORDER_STATUS_LABELS = { "paid" => "支払い済み", "refunded" => "返金済み" }.freeze

  def decision_label(decision)
    DECISION_LABELS.fetch(decision, decision)
  end

  def order_status_label(status)
    ORDER_STATUS_LABELS.fetch(status, status)
  end

  # The arguments of a proposed tool call, as the model wrote them.
  def tool_arguments_list(arguments)
    tag.dl(class: "mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm") do
      safe_join(arguments.map do |name, value|
        tag.dt(name, class: "font-mono text-gray-500") + tag.dd(value.to_s, class: "break-words text-gray-900")
      end)
    end
  end

  # A link, in a new tab, to a URL the model returned, such as a source it
  # cited. The model writes these URLs from pages it read, so only an http or
  # https URL becomes a link: a javascript: URL would run in this page when
  # clicked. Any other URL leaves the text as plain text.
  def model_url_link(text, url)
    return ERB::Util.html_escape(text) unless url.to_s.match?(%r{\Ahttps?://}i)

    link_to text, url, target: "_blank", rel: "noopener", class: "link-quiet"
  end

  # The outcome of one request of a batch, in the words and colors of a
  # run's status: a request succeeds, fails, or is cancelled as a run does.
  def request_status_badge(status)
    tag.span(STATUS_LABELS.fetch(status, status), data: { ticket_status: status },
      class: "inline-flex items-center rounded-md px-2 py-1 text-xs font-medium ring-1 ring-inset #{STATUS_STYLES.fetch(status, STATUS_STYLES["cancelled"])}")
  end

  # The provider's tally of a batch's requests, or a dash while it reports
  # none. OpenAI counts a request as completed once it succeeded.
  def request_counts_text(counts)
    return "—" if counts.blank?

    "成功 #{counts["completed"].to_i} 件、失敗 #{counts["failed"].to_i} 件、全 #{counts["total"].to_i} 件"
  end

  def run_status_badge(run, size: :small)
    text_size = size == :large ? "px-3 py-1 text-base" : "px-2 py-1 text-xs"
    tag.span(STATUS_LABELS.fetch(run.status), data: { run_status: run.status },
      class: "inline-flex items-center rounded-md font-medium ring-1 ring-inset #{text_size} #{STATUS_STYLES.fetch(run.status)}")
  end

  # The scenario's name, or its key when the scenario is no longer defined.
  def run_title(run)
    run.scenario&.name || run.scenario_key
  end

  def run_demo_name(run)
    run.scenario&.demo&.name
  end

  # Takes a time, or a time kept as an ISO 8601 string in a JSON column.
  def format_time(time)
    time = Time.zone.parse(time) if time.is_a?(String)
    time&.strftime("%Y-%m-%d %H:%M:%S")
  end

  def input_label(run, name)
    run.scenario&.inputs&.find { |input| input.name == name }&.label || name
  end

  def sentry_links
    @sentry_links ||= Observability::SentryLinks.from_env
  end

  def sentry_trace_url(trace)
    sentry_links.trace_url(trace.id, at: trace.at)
  end

  def sentry_conversation_url(run)
    sentry_links.conversation_url(run.conversation_id, from: run.created_at, to: run.finished_at || Time.current)
  end
end
