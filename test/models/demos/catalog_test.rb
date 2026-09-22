require "test_helper"

module Demos
  class CatalogTest < ActiveSupport::TestCase
    test "lists the ten features in the order of the requirements" do
      assert_equal %w[
        responses-api citations tool-approval batches model-fallbacks
        video-and-speech provider-tools deep-research tokenization workflow-instrumentation
      ], Catalog.demos.map(&:key)
    end

    test "gives every demo a summary and at least one RubyLLM source" do
      Catalog.demos.each do |demo|
        assert_predicate demo.summary, :present?, demo.key
        assert demo.sources.any? { |source| source.url.start_with?("https://rubyllm.com/") }, demo.key
      end
    end

    test "has both explanations or neither" do
      Catalog.demos.each do |demo|
        assert_equal demo.useful_cases.present?, demo.without_it.present?, demo.key
      end
    end

    test "has two scenarios only for Video and Speech, Provider Tools, and Tokenization" do
      counts = Catalog.demos.to_h { |demo| [ demo.key, demo.scenarios.size ] }

      assert_equal %w[video-and-speech provider-tools tokenization], counts.select { |_, size| size == 2 }.keys
      assert counts.except("video-and-speech", "provider-tools", "tokenization").values.all?(1)
    end

    test "uses unique scenario keys" do
      keys = Catalog.demos.flat_map(&:scenarios).map(&:key)

      assert_equal keys.uniq, keys
    end

    test "looks up a demo and a scenario by key" do
      assert_equal "Responses API", Catalog.demo("responses-api").name
      assert_equal "responses-api", Catalog.scenario("answer_inquiry").demo.key
      assert_nil Catalog.demo("missing")
      assert_nil Catalog.scenario("missing")
    end

    test "fully describes every implemented scenario" do
      Catalog.demos.flat_map(&:scenarios).select(&:implemented?).each do |scenario|
        assert_kind_of Class, scenario.handler, scenario.key
        assert_predicate scenario.providers, :any?, scenario.key
        assert_predicate scenario.models, :any?, scenario.key
        assert_predicate scenario.inputs, :any?, scenario.key
        assert_predicate scenario.result_kind, :present?, scenario.key
        refute_nil scenario.retryable, scenario.key
      end
    end

    test "starts the ticket workflow over when its job runs again, from one ticket" do
      scenario = Catalog.scenario("run_ticket_workflow")

      assert_equal WorkflowInstrumentation::RunTicketWorkflow, scenario.handler
      assert_equal true, scenario.retryable
      assert_equal %w[ticket], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
    end

    test "never starts the refund scenario over, and takes the inquiry and the order" do
      scenario = Catalog.scenario("approve_refund")

      assert_equal ToolApproval::AnswerRefundRequest, scenario.handler
      assert_equal false, scenario.retryable
      assert_equal %w[inquiry order], scenario.inputs.map(&:name)
      assert scenario.inputs.all?(&:required)
      assert_equal "refund_decision", scenario.result_kind
    end

    test "reads the answer aloud with OpenAI from one required text, and starts over when its job runs again" do
      scenario = Catalog.scenario("speak_answer")

      assert_equal VideoAndSpeech::SpeakAnswer, scenario.handler
      assert_equal %w[openai], scenario.providers
      assert_equal({ "model" => "gpt-4o-mini-tts" }, scenario.models)
      assert_equal %w[text], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_predicate scenario.inputs.sole.default, :present?
      assert_equal "speech", scenario.result_kind
      assert_equal true, scenario.retryable
    end

    test "keeps the product video being prepared" do
      refute_predicate Catalog.scenario("generate_product_video"), :implemented?
    end

    # Availability is judged from the providers a scenario lists, while the
    # handler reaches the provider through the model id. They must agree.
    test "lists the provider each model of an implemented scenario resolves to" do
      Catalog.demos.flat_map(&:scenarios).select(&:implemented?).each do |scenario|
        scenario.models.each_value do |model_id|
          assert_includes scenario.providers, RubyLLM.models.find(model_id).provider, "#{scenario.key}: #{model_id}"
        end
      end
    end
  end
end
