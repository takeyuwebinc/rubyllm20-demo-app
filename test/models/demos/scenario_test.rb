require "test_helper"

module Demos
  class ScenarioTest < ActiveSupport::TestCase
    # Stands in for a handler that stops for approval.
    class ApprovingHandler
      class << self
        attr_accessor :calls

        def decide(chat, tool_call_id, approved:)
          (self.calls ||= []) << [ :decide, chat, tool_call_id, approved ]
          :decided
        end

        def resume(chat)
          (self.calls ||= []) << [ :resume, chat ]
          { "answer" => "resumed" }
        end
      end
    end

    # Stands in for a handler that leaves work with the provider.
    class WaitingHandler
      class << self
        attr_accessor :calls

        def resume(id, **models)
          (self.calls ||= []) << [ id, models ]
          { "video" => "done" }
        end
      end
    end

    setup do
      @config = RubyLLM::Configuration.new
    end

    test "hands the id of the work left with the provider, and the models, to its handler to wait for" do
      WaitingHandler.calls = []
      scenario = scenario(handler_name: WaitingHandler.name, models: { "model" => "grok-imagine-video-1.5" })

      assert_equal({ "video" => "done" }, scenario.resume_remote_job("video-1"))
      assert_equal [ [ "video-1", { model: "grok-imagine-video-1.5" } ] ], WaitingHandler.calls
    end

    test "hands only the id when the scenario names no model" do
      WaitingHandler.calls = []

      scenario(handler_name: WaitingHandler.name, models: {}).resume_remote_job("research-1")

      assert_equal [ [ "research-1", {} ] ], WaitingHandler.calls
    end

    test "cannot wait for kept work with a handler that leaves none" do
      scenario = scenario(handler_name: "ResponsesApi::AnswerInquiry")

      assert_raises(NoMethodError) { scenario.resume_remote_job("video-1") }
    end

    test "hands a decision and a resumption to its handler" do
      ApprovingHandler.calls = []
      scenario = scenario(handler_name: ApprovingHandler.name)
      chat = Chat.new

      assert_equal :decided, scenario.decide(chat, "call_1", approved: false)
      assert_equal({ "answer" => "resumed" }, scenario.resume(chat))
      assert_equal [ [ :decide, chat, "call_1", false ], [ :resume, chat ] ], ApprovingHandler.calls
    end

    test "cannot decide or resume for a handler that does not stop for approval" do
      scenario = scenario(handler_name: "ResponsesApi::AnswerInquiry")

      assert_raises(NoMethodError) { scenario.decide(Chat.new, "call_1", approved: true) }
      assert_raises(NoMethodError) { scenario.resume(Chat.new) }
    end

    test "is being prepared while it has no handler" do
      availability = scenario(handler_name: nil).availability(@config)

      assert_equal :preparing, availability.state
    end

    test "is runnable when every required setting of its providers is present" do
      @config.openai_api_key = "sk-test"

      assert_equal :runnable, scenario(providers: %w[openai]).availability(@config).state
    end

    test "names the providers whose settings are missing" do
      @config.openai_api_key = "sk-test"

      availability = scenario(providers: %w[openai anthropic]).availability(@config)

      assert_equal :missing_config, availability.state
      assert_equal %w[anthropic], availability.missing_providers
    end

    test "treats a blank setting as missing" do
      @config.openai_api_key = " "

      assert_equal %w[openai], scenario(providers: %w[openai]).availability(@config).missing_providers
    end

    test "needs every setting a provider requires" do
      @config.vertexai_project_id = "demo-project"

      assert_equal :missing_config, scenario(providers: %w[vertexai]).availability(@config).state

      @config.vertexai_location = "global"

      assert_equal :runnable, scenario(providers: %w[vertexai]).availability(@config).state
    end

    test "reports an unregistered provider as missing" do
      assert_equal %w[nowhere], scenario(providers: %w[nowhere]).availability(@config).missing_providers
    end

    test "keeps only its own inputs, exactly as given" do
      values = scenario.input_values("inquiry" => "  Hello  ", "other" => "x")

      assert_equal({ "inquiry" => "  Hello  " }, values)
    end

    test "names its required inputs that are blank" do
      assert_equal %w[inquiry], scenario.blank_required_inputs("inquiry" => " ")
      assert_empty scenario.blank_required_inputs("inquiry" => "Where is my order?")
    end

    test "uses the defaults for inputs that were not given" do
      assert_equal({ "inquiry" => "Where is my order?" }, scenario.input_values({}))
    end

    test "reads the source of its handler, where the code it runs lives" do
      scenario = Catalog.scenario("answer_inquiry")

      assert_equal "app/actions/responses_api/answer_inquiry.rb", scenario.source_path
      assert_includes scenario.source_code, "class AnswerInquiry"
    end

    private

    def scenario(**overrides)
      Scenario.new(
        key: "answer_inquiry",
        demo_key: "responses-api",
        name: "問い合わせに回答する",
        providers: %w[openai],
        models: { "model" => "gpt-5-nano" },
        inputs: [ Scenario::Input.new(name: "inquiry", label: "問い合わせ", default: "Where is my order?", required: true) ],
        handler_name: "Object",
        result_kind: "text_answer",
        retryable: true,
        **overrides
      )
    end
  end
end
