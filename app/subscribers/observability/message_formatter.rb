module Observability
  # Renders RubyLLM messages in the GenAI message shape: a list of
  # { role, parts }, where each part is typed.
  module MessageFormatter
    module_function

    def format(messages)
      messages.filter_map do |message|
        parts = parts_for(message)
        { role: message.role.to_s, parts: parts } if parts.any?
      end
    end

    def parts_for(message)
      return [ tool_response_part(message) ] if message.role.to_s == "tool"

      # Thinking goes in its own part type. Backends show it apart from what
      # the model said; as a text part it would read as the model's answer.
      [ reasoning_part(message), text_part(message), *tool_call_parts(message), *server_tool_call_parts(message) ].compact
    end

    def reasoning_part(message)
      text = message.thinking.text if message.respond_to?(:thinking) && message.thinking.respond_to?(:text)
      { type: "reasoning", content: text } if text.present?
    end

    def text_part(message)
      { type: "text", content: message.content.to_s } if message.content.present?
    end

    def tool_call_parts(message)
      return [] unless message.respond_to?(:tool_calls) && message.tool_calls.respond_to?(:each_value)

      message.tool_calls.each_value.map do |tool_call|
        { type: "tool_call", id: tool_call.id, name: tool_call.name, arguments: tool_call.arguments }
      end
    end

    # Steps the provider ran itself, such as a web search. The message shape
    # has no part type for them, and a tool call is the nearest: it carries
    # what the model asked for, with which input. The call has a name only when
    # the provider reports one; OpenAI's items have only their type.
    #
    # Citations are not parts. The message shape has no type for them, and the
    # span of the answer they point to is already in the text part.
    def server_tool_call_parts(message)
      return [] unless message.respond_to?(:server_tool_calls)

      Array(message.server_tool_calls).map do |call|
        { type: "tool_call", id: call.id, name: call.name || call.type, arguments: call.input || {} }
      end
    end

    def tool_response_part(message)
      { type: "tool_call_response", id: message.tool_call_id, result: message.content.to_s }
    end
  end
end
