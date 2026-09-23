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
        # A research agent is not a model of the registry; its handler keeps the ID.
        assert_predicate scenario.models, :any?, scenario.key unless scenario.key == "research_topic"
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

    test "answers one inquiry with an OpenAI model that falls back to an Anthropic one, and starts over when its job runs again" do
      scenario = Catalog.scenario("fall_back_to_another_provider")

      assert_equal ModelFallbacks::AnswerWithFallback, scenario.handler
      assert_equal %w[openai anthropic], scenario.providers
      assert_equal "openai", RubyLLM.models.find(scenario.models.fetch("model")).provider
      assert_equal "anthropic", RubyLLM.models.find(scenario.models.fetch("fallback_model")).provider
      assert_equal %w[inquiry], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_predicate scenario.inputs.sole.default, :present?
      assert_equal "fallback_answer", scenario.result_kind
      assert_equal true, scenario.retryable
    end

    test "starts the web search over when its job runs again, from one question, on OpenAI" do
      scenario = Catalog.scenario("search_web")

      assert_equal ProviderTools::AnswerWithWebSearch, scenario.handler
      assert_equal %w[openai], scenario.providers
      assert_equal true, scenario.retryable
      assert_equal %w[question], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_equal "web_search_answer", scenario.result_kind
    end

    test "starts the code execution over when its job runs again, from order data and a request, on OpenAI" do
      scenario = Catalog.scenario("run_code")

      assert_equal "provider-tools", scenario.demo.key
      assert_equal ProviderTools::AnswerWithCodeExecution, scenario.handler
      assert_equal %w[openai], scenario.providers
      assert_equal({ "model" => "gpt-5-nano" }, scenario.models)
      assert_equal true, scenario.retryable
      assert_equal %w[orders request], scenario.inputs.map(&:name)
      assert scenario.inputs.all?(&:required)
      assert scenario.inputs.all? { |input| input.default.present? }
      assert_equal "code_execution_answer", scenario.result_kind
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

    test "generates the product video with xAI from one required description, and never starts over" do
      scenario = Catalog.scenario("generate_product_video")

      assert_equal VideoAndSpeech::GenerateProductVideo, scenario.handler
      assert_equal %w[xai], scenario.providers
      assert_equal({ "model" => "grok-imagine-video-1.5" }, scenario.models)
      assert_equal %w[description], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_predicate scenario.inputs.sole.default, :present?
      assert_equal "product_video", scenario.result_kind
      assert_equal false, scenario.retryable
    end

    test "counts tokens with OpenAI from instructions and a question, and starts over when its job runs again" do
      scenario = Catalog.scenario("count_tokens")

      assert_equal Tokenization::CountInputTokens, scenario.handler
      assert_equal %w[openai], scenario.providers
      assert_equal %w[instructions question], scenario.inputs.map(&:name)
      assert scenario.inputs.all?(&:required)
      assert scenario.inputs.all? { |input| input.default.present? }
      assert_equal "token_count", scenario.result_kind
      assert_equal true, scenario.retryable
    end

    # Without a known context window the scenario could not tell whether the
    # input fits.
    test "counts tokens with a model whose limits the registry knows" do
      model = RubyLLM.models.find(Catalog.scenario("count_tokens").models.fetch("model"))

      assert_equal 400_000, model.context_window
      assert_equal 128_000, model.max_output_tokens
    end

    test "researches a topic with Vertex AI's agent, without a model, never starting over" do
      scenario = Catalog.scenario("research_topic")

      assert_equal DeepResearch::ResearchTopic, scenario.handler
      assert_equal %w[vertexai], scenario.providers
      assert_equal({}, scenario.models)
      assert_equal [ "topic" ], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_match "出典", scenario.inputs.sole.default
      assert_equal "research_report", scenario.result_kind
      assert_equal false, scenario.retryable
    end

    test "gives every implemented scenario but the research one a model" do
      without_models = Catalog.scenarios.select(&:implemented?).select { |scenario| scenario.models.empty? }

      assert_equal [ "research_topic" ], without_models.map(&:key)
    end

    test "tokenizes text with xAI from one required text, and starts over when its job runs again" do
      scenario = Catalog.scenario("tokenize_text")

      assert_equal Tokenization::TokenizeText, scenario.handler
      assert_equal %w[xai], scenario.providers
      assert_equal({ "model" => "grok-4.3" }, scenario.models)
      assert_equal %w[text], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert scenario.inputs.sole.default.end_with?("よろしくお願いします🙏")
      assert_equal "tokenization", scenario.result_kind
      assert_equal true, scenario.retryable
    end

    # The handler names xAI when it tokenizes, so the model must be one of
    # xAI's own.
    test "tokenizes text with a model that resolves to xAI when xAI is named" do
      model = RubyLLM.models.find(Catalog.scenario("tokenize_text").models.fetch("model"), provider: :xai)

      assert_equal "xai", model.provider
      assert_equal "grok-4.3", model.id
    end

    test "answers from the return policy with Anthropic, from one inquiry, and starts over when its job runs again" do
      scenario = Catalog.scenario("cite_return_policy")

      assert_equal Citations::AnswerFromReturnPolicy, scenario.handler
      assert_equal %w[anthropic], scenario.providers
      assert_equal %w[inquiry], scenario.inputs.map(&:name)
      assert scenario.inputs.sole.required
      assert_predicate scenario.inputs.sole.default, :present?
      assert_equal [ Scenario::Document.new(name: "policy", label: "返品ポリシー文書（PDF、3 ページ）", path: "documents/return-policy.pdf") ], scenario.documents
      assert_equal "cited_answer", scenario.result_kind
      assert_equal true, scenario.retryable
    end

    # RubyLLM only warns when the registry says a model cannot cite, and
    # sends the request anyway.
    test "answers from the return policy with an Anthropic model that cites documents and takes PDFs" do
      model = RubyLLM.models.find(Catalog.scenario("cite_return_policy").models.fetch("model"))

      assert_equal "anthropic", model.provider
      assert model.supports?(:citations)
      assert_includes model.modalities.input, "pdf"
    end

    test "keeps every document a scenario defines under public/" do
      documents = Catalog.scenarios.flat_map(&:documents)

      assert_predicate documents, :any?
      documents.each do |document|
        assert_predicate document.absolute_path, :file?, document.path
        assert document.absolute_path.to_s.start_with?("#{Rails.public_path}/"), document.path
      end
    end

    test "reads the documents of a scenario, in the order they are defined" do
      scenario = build_scenario("documents" => [
        { "name" => "policy", "label" => "返品ポリシー文書", "path" => "documents/return-policy.pdf" },
        { "name" => "terms", "label" => "利用規約", "path" => "documents/terms.pdf" }
      ])

      assert_equal [
        Scenario::Document.new(name: "policy", label: "返品ポリシー文書", path: "documents/return-policy.pdf"),
        Scenario::Document.new(name: "terms", label: "利用規約", path: "documents/terms.pdf")
      ], scenario.documents
      assert_equal %w[/documents/return-policy.pdf /documents/terms.pdf], scenario.documents.map(&:url)
    end

    test "reads a scenario without documents, or with an empty list of them, as having none" do
      assert_equal [], build_scenario({}).documents
      assert_equal [], build_scenario("documents" => []).documents
    end

    test "refuses a document that lacks a name, a label, or a path" do
      %w[name label path].each do |missing|
        document = { "name" => "policy", "label" => "返品ポリシー文書", "path" => "documents/return-policy.pdf" }.except(missing)

        error = assert_raises(KeyError, missing) { build_scenario("documents" => [ document ]) }
        assert_match missing, error.message
      end
    end

    # The handler takes them all as the keywords of one call, where a later
    # value would win: a person's input could stand in for a document's path.
    test "refuses a scenario whose inputs, models, and documents share a name" do
      document = ->(name) { { "name" => name, "label" => "文書", "path" => "documents/return-policy.pdf" } }
      input = ->(name) { { "name" => name, "label" => "入力" } }

      [
        { "inputs" => [ input.("policy") ], "documents" => [ document.("policy") ] },
        { "models" => { "policy" => "claude-sonnet-5" }, "documents" => [ document.("policy") ] },
        { "inputs" => [ input.("model") ], "models" => { "model" => "claude-sonnet-5" } },
        { "inputs" => [ input.("inquiry"), input.("inquiry") ] },
        { "documents" => [ document.("policy"), document.("policy") ] }
      ].each do |attributes|
        error = assert_raises(ArgumentError, attributes.inspect) { build_scenario(attributes) }
        assert_match(/answer_from_documents/, error.message)
      end
    end

    # Availability is judged from the providers a scenario lists, while the
    # handler reaches the provider through the model id. They must agree.
    #
    # tokenize_text is left out: its handler names the provider, because
    # grok-4.3 alone resolves to Perplexity's xai/grok-4.3. Resolving every
    # model with its provider named instead would no longer check where the
    # handlers that give the model id alone end up.
    test "lists the provider each model of an implemented scenario resolves to" do
      Catalog.demos.flat_map(&:scenarios).select(&:implemented?).reject { |scenario| scenario.key == "tokenize_text" }.each do |scenario|
        scenario.models.each_value do |model_id|
          assert_includes scenario.providers, RubyLLM.models.find(model_id).provider, "#{scenario.key}: #{model_id}"
        end
      end
    end

    private

    # One scenario built from its attributes as config/demos.yml would hold
    # them, with the given ones in place of the defaults.
    def build_scenario(overrides)
      scenario = {
        "key" => "answer_from_documents",
        "name" => "文書に基づいて回答する",
        "inputs" => [ { "name" => "inquiry", "label" => "問い合わせ文" } ],
        "models" => { "model" => "claude-sonnet-5" }
      }.merge(overrides)
      demo = { "key" => "documents-demo", "name" => "文書", "summary" => "文書", "sources" => [], "scenarios" => [ scenario ] }

      Catalog.build([ demo ]).sole.scenarios.sole
    end
  end
end
