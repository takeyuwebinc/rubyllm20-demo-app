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

    setup do
      @config = RubyLLM::Configuration.new
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

    # Stands in for a handler, keeping the keywords it was called with.
    class RecordingHandler
      class << self
        attr_accessor :arguments

        def perform(**arguments)
          self.arguments = arguments
          { "answer" => "ok" }
        end
      end
    end

    test "hands the handler the inputs, the models, and each document's absolute path, as keywords in the order of the definition" do
      scenario = scenario(handler_name: RecordingHandler.name, documents: [
        Scenario::Document.new(name: "policy", label: "返品ポリシー", path: "documents/return-policy.pdf"),
        Scenario::Document.new(name: "terms", label: "利用規約", path: "documents/terms.pdf")
      ])

      scenario.perform("inquiry" => "返品できますか")

      assert_equal({
        inquiry: "返品できますか",
        model: "gpt-5-nano",
        policy: Rails.root.join("public/documents/return-policy.pdf"),
        terms: Rails.root.join("public/documents/terms.pdf")
      }, RecordingHandler.arguments)
      assert_equal %i[inquiry model policy terms], RecordingHandler.arguments.keys
      assert_kind_of Pathname, RecordingHandler.arguments[:policy]
      assert_predicate RecordingHandler.arguments[:policy], :absolute?
    end

    test "hands the handler only the inputs and the models when it has no documents" do
      scenario(handler_name: RecordingHandler.name).perform("inquiry" => "返品できますか")

      assert_equal({ inquiry: "返品できますか", model: "gpt-5-nano" }, RecordingHandler.arguments)
    end

    test "serves a document from the root, escaping its path for a link" do
      policy = Scenario::Document.new(name: "policy", label: "返品ポリシー", path: "documents/return-policy.pdf")
      terms = Scenario::Document.new(name: "terms", label: "利用規約", path: "documents/利用 規約.pdf")

      assert_equal "/documents/return-policy.pdf", policy.url
      assert_equal "/documents/%E5%88%A9%E7%94%A8%20%E8%A6%8F%E7%B4%84.pdf", terms.url
      assert_equal "return-policy.pdf", policy.filename
      assert_equal "利用 規約.pdf", terms.filename
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
        documents: [],
        handler_name: "Object",
        result_kind: "text_answer",
        retryable: true,
        **overrides
      )
    end
  end
end
