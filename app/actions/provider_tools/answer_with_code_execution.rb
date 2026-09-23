module ProviderTools
  # Totals order data by having the model write code and run it, and lists
  # each step it ran: the code and what the code printed.
  #
  # The code runs on the provider's side, in a container of the provider's,
  # within the one request: the app asks once and gets back the answer
  # together with the code and its outputs. There is no place of the app's
  # own to run code in, and no tool of its own to write.
  class AnswerWithCodeExecution < ApplicationAction
    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      与えられた注文データを、コードを実行して集計してください。暗算で求めないでください。
      集計の結果は日本語の本文で示してください。ファイルや画像は作らないでください。
    TEXT

    def initialize(orders:, request:, model:)
      @orders = orders
      @request = request
      @model = model
    end

    def perform
      chat = RubyLLM.chat(model: @model)
                    .with_instructions(INSTRUCTIONS)
                    .with_provider_tools(:code_execution)
                    .with_provider_options(
                      # OpenAI leaves out what the code printed unless asked
                      # for it. These options replace RubyLLM's own, so its
                      # default, the encrypted reasoning, is listed too.
                      include: [
                        "reasoning.encrypted_content",
                        "code_interpreter_call.outputs"
                      ],
                      # with_tool_options(choice:) is sent only with tools of
                      # the app's own, so the provider's own word is used to
                      # make the model run code rather than answer from memory.
                      tool_choice: "required"
                    )
      response = chat.ask(<<~TEXT)
        #{@request}

        注文データ（CSV）:
        #{@orders}
      TEXT

      {
        "answer" => response.content,
        "model" => response.model,
        "steps" => response.server_tool_calls.map { |call| step(call) }
      }
    end

    private

    # OpenAI reports each run as a code_interpreter_call item. RubyLLM keeps
    # the item's code as the call's input and its outputs as the result, and
    # keeps the item itself as raw. The status and the container are read
    # from raw, since RubyLLM keeps them nowhere else.
    #
    # Keys are strings in a response and symbols once RubyLLM rebuilds the
    # call from a Hash, as it does for a recorded chat.
    def step(call)
      item = call.raw.is_a?(Hash) ? call.raw.transform_keys(&:to_s) : {}
      {
        "type" => call.type,
        "status" => item["status"],
        "container_id" => item["container_id"],
        "code" => call.input.is_a?(String) ? call.input : nil,
        "outputs" => outputs(call.result)
      }
    end

    # Each output is an object with a type: logs with the text the code
    # printed, or image with a URL.
    def outputs(result)
      return [] unless result.is_a?(Array)

      result.grep(Hash).map(&:deep_stringify_keys)
    end
  end
end
