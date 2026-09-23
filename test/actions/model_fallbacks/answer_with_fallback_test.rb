require "test_helper"

module ModelFallbacks
  class AnswerWithFallbackTest < ActiveSupport::TestCase
    include ChatHelpers

    # Stands in for a chat with a provider: keeps how it was set up and what
    # it was asked. When asked, it reports the scripted fallbacks to the
    # after_fallback callbacks, then answers with the scripted response.
    class ScriptedChat
      attr_reader :instructions, :fallbacks, :questions

      def initialize(response, fallbacks: [])
        @response = response
        @scripted_fallbacks = fallbacks
        @callbacks = []
        @questions = []
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def with_fallbacks(*models, **options)
        @fallbacks = [ models, options ]
        self
      end

      def after_fallback(&callback)
        @callbacks << callback
        self
      end

      def ask(question)
        @questions << question
        @scripted_fallbacks.each { |fallback| @callbacks.each { |callback| callback.call(fallback) } }
        @response.respond_to?(:call) ? @response.call : @response
      end
    end

    INQUIRY = "注文した電気ケトルの配送状況を教えてください。".freeze
    CONNECTION_FAILED = "Failed to open TCP connection to api.openai.invalid:443 (getaddrinfo(3): Name or service not known)".freeze

    test "builds the chat in a context that sends OpenAI requests to a host that cannot be reached, and asks once" do
      chat = ScriptedChat.new(response)

      with_context(chat) do |contexts|
        perform

        context = contexts.sole
        assert_equal "https://api.openai.invalid/v1", context.config.openai_api_base
        assert_nil context.config.anthropic_api_base
        assert_equal "sk-ant-test", context.config.anthropic_api_key
        assert_equal [ { model: "gpt-5-nano" } ], context.chats
      end
      assert_match(/サポートデスク/, chat.instructions)
      assert_equal [ [ "claude-haiku-4-5" ], {} ], chat.fallbacks
      assert_equal [ INQUIRY ], chat.questions
    end

    test "leaves the configuration of the whole app as it was" do
      with_context(ScriptedChat.new(response)) { perform }

      assert_nil RubyLLM.config.openai_api_base
    end

    test "returns the answer, the model that answered, the main model, the unreachable host, and each fallback" do
      answer = response(content: "配送状況は注文履歴から確認できます。", model: "claude-haiku-4-5-20251001")
      fallback = connection_fallback(response: answer)

      result = with_context(ScriptedChat.new(answer, fallbacks: [ fallback ])) { perform }

      assert_equal({
        "answer" => "配送状況は注文履歴から確認できます。",
        "model" => "claude-haiku-4-5-20251001",
        "primary_model" => "gpt-5-nano",
        "primary_api_base" => "https://api.openai.invalid/v1",
        "fallbacks" => [
          {
            "attempt" => 1,
            "from" => { "provider" => "openai", "model" => "gpt-5-nano" },
            "to" => { "provider" => "anthropic", "model" => "claude-haiku-4-5" },
            "error_class" => "Faraday::ConnectionFailed",
            "error_message" => CONNECTION_FAILED,
            "succeeded" => true
          }
        ]
      }, result)
    end

    test "records a fallback whose model failed as not answering" do
      fallback = connection_fallback(response: nil, fallback_error: RubyLLM::OverloadedError.new("Overloaded"))

      result = with_context(ScriptedChat.new(response, fallbacks: [ fallback ])) { perform }

      assert_equal false, result["fallbacks"].sole["succeeded"]
    end

    test "returns no fallbacks and the main model's answer when the main model answered" do
      result = with_context(ScriptedChat.new(response(model: "gpt-5-nano-2025-08-07"))) { perform }

      assert_equal [], result["fallbacks"]
      assert_equal "gpt-5-nano-2025-08-07", result["model"]
    end

    test "lets the error of a fallback model that also failed propagate, without a result" do
      overloaded = RubyLLM::OverloadedError.new("Overloaded")
      fallback = connection_fallback(response: nil, fallback_error: overloaded)
      chat = ScriptedChat.new(-> { raise overloaded }, fallbacks: [ fallback ])

      error = assert_raises(RubyLLM::OverloadedError) { with_context(chat) { perform } }

      assert_same overloaded, error
      assert_equal [ INQUIRY ], chat.questions
    end

    private

    def perform
      AnswerWithFallback.perform(inquiry: INQUIRY, model: "gpt-5-nano", fallback_model: "claude-haiku-4-5")
    end

    def response(content: "回答です。", model: "claude-haiku-4-5-20251001")
      RubyLLM::Message.new(role: :assistant, content: content, model: model)
    end

    # The switch from the main model, whose host could not be reached, to
    # the fallback model.
    def connection_fallback(response:, fallback_error: nil)
      ScriptedFallback.new(
        from: RubyLLM.models.find("gpt-5-nano"), to: RubyLLM.models.find("claude-haiku-4-5"),
        error: Faraday::ConnectionFailed.new(CONNECTION_FAILED), attempt: 1,
        response: response, fallback_error: fallback_error
      )
    end
  end
end
