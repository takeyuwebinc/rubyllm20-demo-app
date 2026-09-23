require "test_helper"

module Tokenization
  class CountInputTokensTest < ActiveSupport::TestCase
    include ChatHelpers

    # Stands in for a chat with a provider: counts with the scripted number,
    # or raises the scripted error, and keeps what it was given. Asking or
    # adding a message would show up in its messages.
    class ScriptedChat
      attr_reader :model, :instructions, :counted, :messages

      def initialize(model:, input_tokens: 1_234, error: nil)
        @model = model
        @input_tokens = input_tokens
        @error = error
        @counted = []
        @messages = []
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def count_tokens(message = nil)
        @counted << message
        raise @error if @error

        @input_tokens
      end

      def ask(message)
        @messages << message
      end

      def add_message(message)
        @messages << message
      end
    end

    INSTRUCTIONS = "あなたはサポートデスクの担当者です。"
    QUESTION = "開封した商品は返品できますか。"

    test "builds the chat with the instructions and counts the question without adding it" do
      chat = ScriptedChat.new(model: model_info, input_tokens: 1_234)

      calls = nil
      result = with_chat(chat) do |made|
        calls = made
        CountInputTokens.perform(instructions: INSTRUCTIONS, question: QUESTION, model: "gpt-5-nano")
      end

      assert_equal [ { model: "gpt-5-nano" } ], calls
      assert_equal INSTRUCTIONS, chat.instructions
      assert_equal [ QUESTION ], chat.counted
      assert_empty chat.messages
      assert_equal 1_234, result["input_tokens"]
      assert_equal "gpt-5-nano", result["model"]
    end

    test "records the limits of the model the chat resolved, and what is left of the window" do
      result = count(input_tokens: 1_234, model: model_info(context_window: 400_000, max_output_tokens: 128_000))

      assert_equal({
        "input_tokens" => 1_234,
        "context_window" => 400_000,
        "max_output_tokens" => 128_000,
        "remaining" => 398_766,
        "fits" => true,
        "model" => "gpt-5-nano"
      }, result)
    end

    test "fits only while the input is smaller than the context window" do
      model = model_info(context_window: 400_000)

      below = count(input_tokens: 399_999, model: model)
      equal = count(input_tokens: 400_000, model: model)
      above = count(input_tokens: 400_001, model: model)

      assert_equal [ true, 1 ], below.values_at("fits", "remaining")
      assert_equal [ false, 0 ], equal.values_at("fits", "remaining")
      assert_equal [ false, -1 ], above.values_at("fits", "remaining")
    end

    test "gives no verdict when the model has no known context window" do
      result = count(input_tokens: 1_234, model: model_info(context_window: nil, max_output_tokens: 128_000))

      assert_equal 1_234, result["input_tokens"]
      assert_equal "gpt-5-nano", result["model"]
      assert_equal 128_000, result["max_output_tokens"]
      assert_nil result["context_window"]
      assert_nil result.fetch("remaining")
      assert_nil result.fetch("fits")
    end

    test "still judges the input when only the maximum output is unknown" do
      result = count(input_tokens: 1_234, model: model_info(context_window: 400_000, max_output_tokens: nil))

      assert_equal true, result["fits"]
      assert_equal 398_766, result["remaining"]
      assert_nil result.fetch("max_output_tokens")
    end

    test "lets a failed count propagate and returns nothing" do
      error = RubyLLM::ContextLengthExceededError.new("Your input exceeds the context window of this model.")
      chat = ScriptedChat.new(model: model_info, error: error)

      raised = assert_raises(RubyLLM::ContextLengthExceededError) do
        with_chat(chat) { CountInputTokens.perform(instructions: INSTRUCTIONS, question: QUESTION, model: "gpt-5-nano") }
      end
      assert_same error, raised
    end

    private

    def count(input_tokens:, model:)
      with_chat(ScriptedChat.new(model: model, input_tokens: input_tokens)) do
        CountInputTokens.perform(instructions: INSTRUCTIONS, question: QUESTION, model: "gpt-5-nano")
      end
    end

    # The model a chat resolves from the registry. A model the registry does
    # not know, or knows without its limits, has nil for them.
    def model_info(context_window: 400_000, max_output_tokens: 128_000)
      RubyLLM::Model.new(id: "gpt-5-nano", provider: "openai", context_window:, max_output_tokens:)
    end
  end
end
