require "test_helper"

module ProviderTools
  class AnswerWithCodeExecutionTest < ActiveSupport::TestCase
    include ChatHelpers

    ORDERS = <<~CSV.freeze
      注文番号,注文日,カテゴリ,商品,金額,状態
      E-1,2026-09-01,キッチン家電,電気ケトル,4980,支払い済み
      E-2,2026-09-05,キッチン家電,コーヒーメーカー,7980,返金済み
    CSV
    REQUEST = "カテゴリごとの売上金額の合計を求めてください。".freeze

    # Stands in for a chat with a provider: keeps how it was set up and what
    # it was asked, and answers with the scripted response.
    class ScriptedChat
      attr_reader :instructions, :provider_tools, :provider_options, :questions

      def initialize(response)
        @response = response
        @provider_tools = []
        @provider_options = []
        @questions = []
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def with_provider_tools(*tools, **tools_with_options)
        @provider_tools << [ tools, tools_with_options ]
        self
      end

      def with_provider_options(options)
        @provider_options << options
        self
      end

      def ask(question)
        @questions << question
        @response.respond_to?(:call) ? @response.call : @response
      end
    end

    test "asks once, as the support desk, with code execution on, its outputs included, and its use required" do
      chat = ScriptedChat.new(response)

      with_chat(chat) { perform }

      assert_match(/サポートデスク/, chat.instructions)
      assert_match(/コードを実行して集計/, chat.instructions)
      assert_match(/ファイルや画像は作らない/, chat.instructions)
      assert_equal [ [ [ :code_execution ], {} ] ], chat.provider_tools
      assert_equal [ { include: [ "reasoning.encrypted_content", "code_interpreter_call.outputs" ], tool_choice: "required" } ], chat.provider_options
      assert_equal 1, chat.questions.size
      assert_includes chat.questions.sole, ORDERS.strip
      assert_includes chat.questions.sole, REQUEST
    end

    test "returns the answer, the model, and each step with its status, container, code, and outputs" do
      answer = response(
        content: "キッチン家電の売上は 4,980 円です。",
        server_tool_calls: [
          code_call("ci_1", "import pandas as pd\nprint(total)", status: "completed", container_id: "cntr_1",
            outputs: [ { "type" => "logs", "logs" => "キッチン家電 4980\n" } ]),
          code_call("ci_2", "plot()", status: "completed", container_id: "cntr_1",
            outputs: [ { "type" => "image", "url" => "https://example.com/plot.png" } ])
        ]
      )

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal "キッチン家電の売上は 4,980 円です。", result["answer"]
      assert_equal "gpt-5-nano-2025-08-07", result["model"]
      assert_equal [
        { "type" => "code_interpreter_call", "status" => "completed", "container_id" => "cntr_1",
          "code" => "import pandas as pd\nprint(total)", "outputs" => [ { "type" => "logs", "logs" => "キッチン家電 4980\n" } ] },
        { "type" => "code_interpreter_call", "status" => "completed", "container_id" => "cntr_1",
          "code" => "plot()", "outputs" => [ { "type" => "image", "url" => "https://example.com/plot.png" } ] }
      ], result["steps"]
    end

    test "lets a failed request propagate without a result" do
      chat = ScriptedChat.new(-> { raise RubyLLM::RateLimitError, "Rate limit reached" })

      error = assert_raises(RubyLLM::RateLimitError) { with_chat(chat) { perform } }

      assert_equal "Rate limit reached", error.message
      assert_equal 1, chat.questions.size
    end

    test "returns no steps when the model ran no code, with the answer and the model" do
      result = with_chat(ScriptedChat.new(response(content: "コードを実行せずに回答しました。"))) { perform }

      assert_equal({ "answer" => "コードを実行せずに回答しました。", "model" => "gpt-5-nano-2025-08-07", "steps" => [] }, result)
    end

    test "keeps no outputs for a step whose result is missing or not a list" do
      answer = response(server_tool_calls: [
        code_call("ci_1", "x = 1", outputs: nil),
        RubyLLM::ServerToolCall.new(type: "code_interpreter_call", id: "ci_2", input: "y = 2", result: "opaque", raw: {})
      ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal [ [], [] ], result["steps"].map { |step| step["outputs"] }
    end

    test "drops outputs that are not objects and keeps outputs of an unknown type with their type" do
      answer = response(server_tool_calls: [
        code_call("ci_1", "x = 1", outputs: [ "stray", nil, 42, { "type" => "files", "files" => [ { "name" => "a.csv" } ] } ])
      ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal [ { "type" => "files", "files" => [ { "name" => "a.csv" } ] } ], result["steps"].sole["outputs"]
    end

    test "leaves out the code of a step whose input is not code" do
      answer = response(server_tool_calls: [
        RubyLLM::ServerToolCall.new(type: "code_interpreter_call", id: "ci_1", input: { "type" => "exec" }, raw: {}),
        RubyLLM::ServerToolCall.new(type: "code_interpreter_call", id: "ci_2", raw: {})
      ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal [ nil, nil ], result["steps"].map { |step| step["code"] }
    end

    test "leaves out the status and the container when the provider's item is missing or lacks them" do
      answer = response(server_tool_calls: [
        { type: "code_interpreter_call", id: "ci_1", input: "x = 1" },
        RubyLLM::ServerToolCall.new(type: "code_interpreter_call", id: "ci_2", input: "y = 2", raw: { "type" => "code_interpreter_call" })
      ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_nil answer.server_tool_calls.first.raw
      assert_equal [
        { "type" => "code_interpreter_call", "status" => nil, "container_id" => nil, "code" => "x = 1", "outputs" => [] },
        { "type" => "code_interpreter_call", "status" => nil, "container_id" => nil, "code" => "y = 2", "outputs" => [] }
      ], result["steps"]
    end

    # A response from the provider carries the item and its outputs with
    # string keys; a call RubyLLM rebuilds from a Hash, as it does for a
    # recorded chat, carries symbol keys.
    test "reads the item and the outputs the same with string keys and with symbol keys" do
      outputs = [
        { "type" => "logs", "logs" => "4980\n" },
        { "type" => "image", "url" => "https://example.com/plot.png" },
        { "type" => "files", "files" => [ { "name" => "a.csv" } ] }
      ]
      string_keyed = response(server_tool_calls: [ code_call("ci_1", "print(4980)", status: "failed", container_id: "cntr_1", outputs: outputs) ])
      symbol_keyed = response(server_tool_calls: [ string_keyed.server_tool_calls.sole.to_h ])

      results = [ string_keyed, symbol_keyed ].map { |answer| with_chat(ScriptedChat.new(answer)) { perform } }

      assert_equal [
        { type: "logs", logs: "4980\n" },
        { type: "image", url: "https://example.com/plot.png" },
        { type: "files", files: [ { name: "a.csv" } ] }
      ], symbol_keyed.server_tool_calls.sole.result
      assert_equal "failed", symbol_keyed.server_tool_calls.sole.raw[:status]
      assert_equal [ { "type" => "code_interpreter_call", "status" => "failed", "container_id" => "cntr_1", "code" => "print(4980)", "outputs" => outputs } ], results.first["steps"]
      assert_equal results.first["steps"], results.last["steps"]
    end

    test "keeps the code with its line endings as the provider returned them" do
      code = "import pandas as pd\r\nfrom io import StringIO\nprint(df)\r\n"
      answer = response(server_tool_calls: [ code_call("ci_1", code) ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal code, result["steps"].sole["code"]
    end

    private

    def perform
      AnswerWithCodeExecution.perform(orders: ORDERS, request: REQUEST, model: "gpt-5-nano")
    end

    def response(content: "集計しました。", server_tool_calls: [])
      RubyLLM::Message.new(role: :assistant, content: content, model: "gpt-5-nano-2025-08-07", server_tool_calls: server_tool_calls)
    end

    # A code execution step as RubyLLM reads it from OpenAI's response: the
    # item's code as the input, its outputs as the result, the item as raw.
    def code_call(id, code, status: "completed", container_id: "cntr_1", outputs: [])
      raw = { "type" => "code_interpreter_call", "id" => id, "status" => status, "code" => code, "container_id" => container_id, "outputs" => outputs }
      RubyLLM::ServerToolCall.new(type: "code_interpreter_call", id: id, input: code, result: outputs, raw: raw)
    end
  end
end
