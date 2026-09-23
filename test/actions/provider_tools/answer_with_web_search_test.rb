require "test_helper"

module ProviderTools
  class AnswerWithWebSearchTest < ActiveSupport::TestCase
    include ChatHelpers

    # Stands in for a chat with a provider: keeps how it was set up and what
    # it was asked, and answers with the scripted response.
    class ScriptedChat
      attr_reader :instructions, :provider_tools, :questions

      def initialize(response)
        @response = response
        @provider_tools = []
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

      def ask(question)
        @questions << question
        @response.respond_to?(:call) ? @response.call : @response
      end
    end

    test "asks the question once, as the support desk, with web search on" do
      chat = ScriptedChat.new(response)

      with_chat(chat) { AnswerWithWebSearch.perform(question: "返品の制度は変わりましたか", model: "gpt-5-nano") }

      assert_match(/サポートデスク/, chat.instructions)
      assert_match(/Web 検索/, chat.instructions)
      assert_match(/出典/, chat.instructions)
      assert_equal [ [ [ :web_search ], {} ] ], chat.provider_tools
      assert_equal [ "返品の制度は変わりましたか" ], chat.questions
    end

    test "returns the answer, the model, each search the provider ran, and each source it cited" do
      answer = response(
        content: "返品の特約の表示が変わりました。",
        server_tool_calls: [
          search_call("ws_1", "type" => "search", "queries" => [ "特定商取引法 改正", "返品特約 表示" ], "query" => "特定商取引法 改正"),
          search_call("ws_2", "type" => "search", "query" => "宅配便 再配達 制度"),
          search_call("ws_3", "type" => "open_page", "url" => "https://www.caa.go.jp/policies/")
        ],
        citations: [
          { url: "https://www.caa.go.jp/policies/", title: "特定商取引法", text: "返品の特約の表示", start_index: 0, end_index: 8 }
        ]
      )

      result = with_chat(ScriptedChat.new(answer)) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }

      assert_equal "返品の特約の表示が変わりました。", result["answer"]
      assert_equal "gpt-5-nano-2025-08-07", result["model"]
      assert_equal [
        { "type" => "web_search_call", "action" => "search", "queries" => [ "特定商取引法 改正", "返品特約 表示" ], "url" => nil },
        { "type" => "web_search_call", "action" => "search", "queries" => [ "宅配便 再配達 制度" ], "url" => nil },
        { "type" => "web_search_call", "action" => "open_page", "queries" => [], "url" => "https://www.caa.go.jp/policies/" }
      ], result["searches"]
      assert_equal [
        { "url" => "https://www.caa.go.jp/policies/", "title" => "特定商取引法", "text" => "返品の特約の表示", "start_index" => 0, "end_index" => 8 }
      ], result["citations"]
    end

    test "lets a failed request propagate without a result" do
      chat = ScriptedChat.new(-> { raise RubyLLM::RateLimitError, "Rate limit reached" })

      error = assert_raises(RubyLLM::RateLimitError) do
        with_chat(chat) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }
      end

      assert_equal "Rate limit reached", error.message
      assert_equal 1, chat.questions.size
    end

    test "returns empty lists when the model neither searched nor cited, with the answer and the model" do
      result = with_chat(ScriptedChat.new(response(content: "検索せずに回答しました。"))) do
        AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano")
      end

      assert_equal({ "answer" => "検索せずに回答しました。", "model" => "gpt-5-nano-2025-08-07", "searches" => [], "citations" => [] }, result)
    end

    test "keeps a step without an action as its item type alone" do
      answer = response(server_tool_calls: [ RubyLLM::ServerToolCall.new(type: "web_search_call", id: "ws_1", raw: {}) ])

      result = with_chat(ScriptedChat.new(answer)) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }

      assert_equal [ { "type" => "web_search_call", "action" => nil, "queries" => [], "url" => nil } ], result["searches"]
    end

    # A response from the provider carries the action with string keys; a
    # call RubyLLM rebuilds from a Hash, as it does for a recorded chat,
    # carries symbol keys.
    test "reads the action the same with string keys and with symbol keys" do
      action = { "type" => "search", "query" => "返品 制度", "url" => "https://example.com/" }
      string_keyed = response(server_tool_calls: [ search_call("ws_1", action) ])
      symbol_keyed = response(server_tool_calls: [ { type: "web_search_call", id: "ws_1", input: action } ])

      results = [ string_keyed, symbol_keyed ].map do |answer|
        with_chat(ScriptedChat.new(answer)) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }
      end

      assert_equal({ "type" => "search", "query" => "返品 制度", "url" => "https://example.com/" }, string_keyed.server_tool_calls.sole.input)
      assert_equal({ type: "search", query: "返品 制度", url: "https://example.com/" }, symbol_keyed.server_tool_calls.sole.input)
      assert_equal [ { "type" => "web_search_call", "action" => "search", "queries" => [ "返品 制度" ], "url" => "https://example.com/" } ], results.first["searches"]
      assert_equal results.first["searches"], results.last["searches"]
    end

    test "falls back to the single query when the list of queries is empty" do
      answer = response(server_tool_calls: [ search_call("ws_1", "type" => "search", "queries" => [], "query" => "返品 制度") ])

      result = with_chat(ScriptedChat.new(answer)) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }

      assert_equal [ "返品 制度" ], result["searches"].sole["queries"]
    end

    test "keeps a source without a URL or a title with those left empty" do
      answer = response(citations: [ { text: "返品の特約" }, { url: "https://example.com/" } ])

      result = with_chat(ScriptedChat.new(answer)) { AnswerWithWebSearch.perform(question: "返品の制度は", model: "gpt-5-nano") }

      assert_equal [
        { "url" => nil, "title" => nil, "text" => "返品の特約", "start_index" => nil, "end_index" => nil },
        { "url" => "https://example.com/", "title" => nil, "text" => nil, "start_index" => nil, "end_index" => nil }
      ], result["citations"]
    end

    private

    def response(content: "回答です。", server_tool_calls: [], citations: [])
      RubyLLM::Message.new(role: :assistant, content: content, model: "gpt-5-nano-2025-08-07",
        server_tool_calls: server_tool_calls, citations: citations)
    end

    # A web search step as RubyLLM reads it from OpenAI's response.
    def search_call(id, action)
      RubyLLM::ServerToolCall.new(type: "web_search_call", id: id, input: action, raw: { "type" => "web_search_call", "id" => id, "action" => action })
    end
  end
end
