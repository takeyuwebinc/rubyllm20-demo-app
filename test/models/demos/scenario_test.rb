require "test_helper"

module Demos
  class ScenarioTest < ActiveSupport::TestCase
    setup do
      @config = RubyLLM::Configuration.new
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
