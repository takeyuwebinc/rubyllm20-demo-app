# Helpers that pin the settings a screen depends on, so that screen tests do
# not depend on the developer's .env.
module ScreenHelpers
  def with_openai_key(value)
    original = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = value
    yield
  ensure
    RubyLLM.config.openai_api_key = original
  end

  # Vertex AI needs a project and a location; the location is the one
  # Deep Research accepts unless given.
  def with_vertexai_config(project_id, location: "global")
    original = [ RubyLLM.config.vertexai_project_id, RubyLLM.config.vertexai_location ]
    RubyLLM.config.vertexai_project_id = project_id
    RubyLLM.config.vertexai_location = location
    yield
  ensure
    RubyLLM.config.vertexai_project_id, RubyLLM.config.vertexai_location = original
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| ENV[key] = value }
  end

  def create_run(scenario_key: "answer_inquiry", input: { "inquiry" => "Where is my order?" }, **attributes)
    Demos::Run.create!(scenario_key: scenario_key, input: input, **attributes)
  end

  # Audio as RubyLLM.speak returns it. Building one calls no provider.
  def fake_speech(data: "mp3 bytes", model: "gpt-4o-mini-tts", voice: "marin", format: "mp3")
    RubyLLM::Speech.new(data: data, model: model, voice: voice, format: format)
  end

  # A run that read a 16-character answer aloud, with its audio attached.
  def create_speech_run
    run = create_run(scenario_key: "speak_answer", input: { "text" => "ご注文の商品は明日お届けします。" })
    run.succeed!({ "speech" => fake_speech(data: "x" * 48_000), "model" => "gpt-4o-mini-tts", "voice" => "marin", "format" => "mp3", "characters" => 16 })
    run
  end

  # The speech of a run made by create_speech_run, as the run page shows it.
  def assert_shows_speech(run)
    file = run.generated_files.sole
    assert_select "[data-speech]" do
      assert_select "audio[controls][src=?]", rails_blob_path(file, only_path: true)
      assert_select "a[href=?]", rails_blob_path(file, disposition: "attachment", only_path: true), text: "音声を保存する"
      assert_select "[data-speech-missing]", count: 0
      assert_select "dd", text: "gpt-4o-mini-tts"
      assert_select "dd", text: "marin"
      assert_select "dd", text: "mp3"
      assert_select "dd", text: "16 文字"
      assert_select "dd", text: "46.9 KB"
      assert_select "*", text: /AI が生成したもの/
    end
  end

  # A research report as DeepResearch::ResearchTopic returns it, complete,
  # with one source, two steps, and a thinking summary.
  def research_result(**overrides)
    {
      "report" => "# 返品の法制度\n\n通信販売には法定のクーリング・オフがない。",
      "completed" => true,
      "provider_status" => "completed",
      "finish_reason" => "stop",
      "citations" => [ {
        "url" => "https://www.caa.go.jp/policies/", "title" => "特定商取引法ガイド", "text" => "法定のクーリング・オフがない",
        "start_index" => 12, "end_index" => 26, "cited_text" => "通信販売にはクーリング・オフ制度はありません"
      } ],
      "steps" => [
        { "type" => "google_search_call", "name" => "google_search", "input" => { "queries" => [ "通信販売 返品 特約" ] }, "result" => nil },
        { "type" => "url_context_result", "name" => nil, "input" => nil, "result" => [ { "url" => "https://www.caa.go.jp/policies/" } ] }
      ],
      "thinking" => "まず法令を確かめる。",
      "job_id" => "v1_research",
      "agent" => "deep-research-preview-04-2026",
      "tokens" => { "input" => 12_000, "output" => 8_000, "thinking" => 3_000, "cache_read" => 500 },
      "cost" => nil
    }.merge(overrides.transform_keys(&:to_s))
  end

  # A research run that kept its job's ID, succeeded or not yet.
  def create_research_run(result: nil, remote_job_id: "v1_research", **attributes)
    run = create_run(scenario_key: "research_topic", input: { "topic" => "返品の法制度を整理してほしい" }, started_at: 5.minutes.ago, **attributes)
    run.keep_remote_job_id!(remote_job_id) if remote_job_id
    run.succeed!(result) if result
    run
  end

  # Replaces the storage service's upload for the block. The replacement is
  # called with the original upload and its arguments.
  def with_storage_upload(replacement)
    service = ActiveStorage::Blob.service
    original = service.method(:upload)
    service.define_singleton_method(:upload) { |*args, **options| replacement.call(original, *args, **options) }
    yield
  ensure
    service.singleton_class.remove_method(:upload)
  end

  # A persisted chat of the refund agent, without calling a provider. The
  # model record is made first: RubyLLM would otherwise load its whole
  # registry into the empty test database.
  def create_refund_chat(model: "gpt-5-nano")
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: model, provider: "openai") { |record| record.name = model }
    ToolApproval::AnswerRefundRequest::RefundAgent.create!(model: model)
  end

  # A recorded tool call of the chat that still needs a decision, as RubyLLM
  # persists one after the model asked for the tool.
  def create_pending_refund_call(chat, tool_call_id: "call_1", order_id: 1, reason: "商品が破損していた")
    message = chat.messages.create!(role: "assistant", content: "")
    RubyLLM::ActiveRecord::ToolCall.create!(
      message: message, tool_call_id: tool_call_id, name: "issue_refund",
      arguments: { "order_id" => order_id, "reason" => reason }
    )
  end

  def refund_call_approval(tool_call_id)
    RubyLLM::ActiveRecord::ToolCall.find_by!(tool_call_id: tool_call_id).approval
  end

  # A run that stopped for a decision on one proposed refund.
  def create_awaiting_run(chat: create_refund_chat, tool_call_id: "call_1", order_id: 1)
    create_pending_refund_call(chat, tool_call_id: tool_call_id, order_id: order_id)
    run = create_run(scenario_key: "approve_refund", input: { "inquiry" => "返金してください", "order" => "注文番号 C-1、7,980 円" })
    run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id))
    run
  end
end
