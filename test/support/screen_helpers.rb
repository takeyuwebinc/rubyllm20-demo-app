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

  # A run of the ticket classification whose batch OpenAI accepted, as the
  # last check found it. A batch never checked keeps only what the
  # submission returned.
  def create_batch_run(raw_status: "in_progress", request_counts: { "total" => 2, "completed" => 1, "failed" => 0 }, checked: true)
    run = create_run(scenario_key: "classify_tickets", input: { "tickets" => "荷物が届かない。\n\n返品したい。" }, started_at: Time.current)
    run.keep_remote_job!(batch_state("validating", { "total" => 0, "completed" => 0, "failed" => 0 }))
    run.record_remote_check!(batch_state(raw_status, request_counts)) if checked
    run
  end

  def batch_state(raw_status, request_counts)
    Demos::Scenario::RemoteState.new(
      kind: "batch", id: "batch_69d2", provider: "openai", status: :pending, raw_status: raw_status, request_counts: request_counts
    )
  end

  # The result of collecting a batch of the given tickets, each given as
  # [text, status, category, reason].
  def batch_result(tickets, raw_status: "completed", model: "gpt-5-nano-2025-08-07")
    {
      "batch_id" => "batch_69d2",
      "provider" => "openai",
      "raw_status" => raw_status,
      "request_counts" => {
        "total" => tickets.size,
        "completed" => tickets.count { |ticket| ticket[1] == "succeeded" },
        "failed" => tickets.count { |ticket| ticket[1] == "failed" }
      },
      "model" => model,
      "tickets" => tickets.map { |text, status, category, reason| { "text" => text, "status" => status, "category" => category, "reason" => reason } }
    }
  end
end
