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

    # Stands in for a handler that leaves a batch with the provider.
    class BatchHandler
      class << self
        attr_accessor :calls, :batch

        def check(id)
          (self.calls ||= []) << [ :check, id ]
          batch
        end

        def resume(id)
          (self.calls ||= []) << [ :resume, id ]
          { "tickets" => [] }
        end
      end
    end

    include BatchHelpers

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

    test "asks its handler about the work the run left with the provider, and reads the answer" do
      BatchHandler.calls = []
      BatchHandler.batch = openai_batch(raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 2, "failed" => 1 })

      batch_scenario = scenario(handler_name: BatchHandler.name)
      state = batch_scenario.check_remote_job("batch_1")

      assert_predicate batch_scenario, :checks_remote_job?

      assert_equal [ [ :check, "batch_1" ] ], BatchHandler.calls
      assert_equal Scenario::RemoteState.new(
        kind: "batch", id: "batch_1", provider: "openai", status: :pending,
        raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 2, "failed" => 1 }
      ), state
      assert_predicate state, :pending?
    end

    test "reads a batch as pending until it ends, and then by how it ended" do
      {
        "validating" => :pending, "in_progress" => :pending, "finalizing" => :pending, "cancelling" => :pending,
        "completed" => :succeeded, "expired" => :failed, "failed" => :failed, "cancelled" => :cancelled
      }.each do |raw_status, status|
        state = scenario.remote_state(openai_batch(raw_status:))

        assert_equal status, state.status, raw_status
        assert_equal raw_status, state.raw_status
      end
    end

    test "passes the counts of a batch on as the provider reported them, or nil" do
      assert_nil scenario.remote_state(openai_batch(request_counts: nil)).request_counts
    end

    test "refuses to read a value it knows no reading for" do
      assert_raises(ArgumentError) { scenario.remote_state(Struct.new(:id, :status).new("job_1", :pending)) }
    end

    test "hands the id of the work to its handler to collect it" do
      BatchHandler.calls = []

      assert_equal({ "tickets" => [] }, scenario(handler_name: BatchHandler.name).collect_remote_job("batch_1"))
      assert_equal [ [ :resume, "batch_1" ] ], BatchHandler.calls
    end

    test "cannot check on or collect work for a handler that leaves none with a provider" do
      scenario = scenario(handler_name: "ResponsesApi::AnswerInquiry")

      refute_predicate scenario, :checks_remote_job?
      assert_raises(NoMethodError) { scenario.check_remote_job("batch_1") }
      assert_raises(NoMethodError) { scenario.collect_remote_job("batch_1") }
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
