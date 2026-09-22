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
