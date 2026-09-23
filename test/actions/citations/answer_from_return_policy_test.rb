require "test_helper"

module Citations
  class AnswerFromReturnPolicyTest < ActiveSupport::TestCase
    include ChatHelpers

    POLICY = Rails.public_path.join("documents/return-policy.pdf")

    # Stands in for a chat with a provider: keeps how it was set up and what
    # it was asked with, and answers with the scripted response.
    class ScriptedChat
      attr_reader :instructions, :citations, :questions

      def initialize(response)
        @response = response
        @citations = []
        @questions = []
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def with_citations(enabled = true)
        @citations << enabled
        self
      end

      def ask(question, with: nil)
        @questions << [ question, with ]
        @response.respond_to?(:call) ? @response.call : @response
      end
    end

    test "asks the inquiry once, as the support desk, with the policy attached and citations on" do
      chat = ScriptedChat.new(response)

      calls = with_chat(chat) do |calls|
        AnswerFromReturnPolicy.perform(inquiry: "返品できますか", policy: POLICY, model: "claude-sonnet-5")
        calls
      end

      assert_equal [ { model: "claude-sonnet-5" } ], calls
      assert_match(/サポートデスク/, chat.instructions)
      assert_match(/返品ポリシーだけを根拠に/, chat.instructions)
      assert_match(/引用/, chat.instructions)
      assert_match(/書かれていないと伝えて/, chat.instructions)
      assert_equal [ true ], chat.citations
      assert_equal [ [ "返品できますか", POLICY ] ], chat.questions
    end

    test "returns the answer, the model, the document's filename, and each source with its pages as RubyLLM gives them" do
      answer = response(content: "30 日以内なら返品できます。返金は 7 営業日以内です。", citations: [
        { title: "return-policy.pdf", cited_text: "商品の到着から 30 日以内であれば、返品を受け付けます。", text: "30 日以内なら返品できます。",
          start_index: 0, end_index: 15, source_index: 0, start_page: 1, end_page: 1 },
        { title: "return-policy.pdf", cited_text: "返金は、7 営業日以内に行います。", text: "返金は 7 営業日以内です。",
          start_index: 15, end_index: 29, source_index: 0, start_page: 2, end_page: 3 }
      ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal "30 日以内なら返品できます。返金は 7 営業日以内です。", result["answer"]
      assert_equal "claude-sonnet-5-20260801", result["model"]
      assert_equal "return-policy.pdf", result["document"]
      assert_equal [
        { "title" => "return-policy.pdf", "cited_text" => "商品の到着から 30 日以内であれば、返品を受け付けます。", "text" => "30 日以内なら返品できます。",
          "start_index" => 0, "end_index" => 15, "start_page" => 1, "end_page" => 1, "source_index" => 0 },
        { "title" => "return-policy.pdf", "cited_text" => "返金は、7 営業日以内に行います。", "text" => "返金は 7 営業日以内です。",
          "start_index" => 15, "end_index" => 29, "start_page" => 2, "end_page" => 3, "source_index" => 0 }
      ], result["citations"]
    end

    test "keeps a source that lacks pages, a quote, or a place in the answer with those left empty" do
      answer = response(citations: [ { title: "return-policy.pdf", text: "返品できます。" }, {} ])

      result = with_chat(ScriptedChat.new(answer)) { perform }

      assert_equal [
        { "title" => "return-policy.pdf", "cited_text" => nil, "text" => "返品できます。",
          "start_index" => nil, "end_index" => nil, "start_page" => nil, "end_page" => nil, "source_index" => nil },
        { "title" => nil, "cited_text" => nil, "text" => nil,
          "start_index" => nil, "end_index" => nil, "start_page" => nil, "end_page" => nil, "source_index" => nil }
      ], result["citations"]
    end

    test "returns no sources when the answer cites none, with the answer, the model, and the document's filename" do
      result = with_chat(ScriptedChat.new(response(content: "ポリシーには書かれていません。"))) { perform }

      assert_equal({ "answer" => "ポリシーには書かれていません。", "model" => "claude-sonnet-5-20260801", "document" => "return-policy.pdf", "citations" => [] }, result)
    end

    test "lets a failed request propagate without a result" do
      chat = ScriptedChat.new(-> { raise RubyLLM::OverloadedError, "Overloaded" })

      error = assert_raises(RubyLLM::OverloadedError) { with_chat(chat) { perform } }

      assert_equal "Overloaded", error.message
      assert_equal 1, chat.questions.size
    end

    private

    def perform
      AnswerFromReturnPolicy.perform(inquiry: "返品できますか", policy: POLICY, model: "claude-sonnet-5")
    end

    # The model that answered, as the provider names it: not the id the
    # chat was built with.
    def response(content: "回答です。", citations: [])
      RubyLLM::Message.new(role: :assistant, content: content, model: "claude-sonnet-5-20260801", citations: citations)
    end
  end
end
