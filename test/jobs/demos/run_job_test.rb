require "test_helper"

module Demos
  class RunJobTest < ActiveSupport::TestCase
    # Stands in for a scenario handler so that no provider is called.
    class FakeHandler
      class << self
        attr_accessor :calls, :outcome, :resumed, :resumed_models, :resume_outcome, :traced

        def perform(**arguments)
          calls << arguments
          outcome.respond_to?(:call) ? outcome.call : outcome
        end

        # Continues a chat, or waits for the work left with the provider
        # under an id, as a handler of either kind does.
        def resume(chat_or_id, **models)
          resumed << chat_or_id
          resumed_models << models
          traced << [ :resume, in_span? ]
          resume_outcome.respond_to?(:call) ? resume_outcome.call : resume_outcome
        end

        def in_span?
          OpenTelemetry::Trace.current_span.context.valid?
        end
      end
    end

    # Stands in for a handler that leaves work the job checks on rather than
    # waits for, such as a batch: it also has .check, and its .resume
    # collects the ended work by its id alone. It runs FakeHandler's script
    # and records to it.
    class CheckingHandler
      class << self
        attr_accessor :checked, :check_outcome

        def perform(**arguments) = FakeHandler.perform(**arguments)

        def resume(id) = FakeHandler.resume(id)

        def check(id)
          checked << id
          FakeHandler.traced << [ :check, FakeHandler.in_span? ]
          check_outcome.respond_to?(:call) ? check_outcome.call : check_outcome
        end
      end
    end

    # Work left with the provider as RubyLLM's ResearchJob is: an id, and
    # whether it is still pending. An error of a job's wait holds it.
    RemoteWork = Data.define(:id, :status) do
      def pending? = status == :pending
      def cancelled? = status == :cancelled
    end

    # Work left with the provider, as RubyLLM's VideoJob and ResearchJob
    # stand for it: an id, a status, and whether it is still pending.
    RemoteJob = Data.define(:id) do
      def status = :pending
      def pending? = true
    end

    # Answers each question, or each count, with the next scripted answer, in
    # place of a chat with a provider, and keeps the questions it was given.
    # An answer can report a fallback attempt to the after_fallback callbacks
    # with #fall_back.
    class ScriptedChat
      attr_reader :questions

      def initialize(*answers)
        @answers = answers
        @questions = []
        @fallback_callbacks = []
      end

      def with_instructions(_instructions) = self
      def with_schema(_schema) = self
      def with_fallbacks(*_models, **_options) = self

      def after_fallback(&callback)
        @fallback_callbacks << callback
        self
      end

      def fall_back(fallback)
        @fallback_callbacks.each { |callback| callback.call(fallback) }
      end

      def ask(question)
        @questions << question
        @answers.fetch(@questions.size - 1).call
      end
      alias_method :count_tokens, :ask
    end

    include ActiveJob::TestHelper
    include ActiveJob::TestHelper
    include ScreenHelpers
    include ChatHelpers
    include BatchHelpers

    RESULT = { "tickets" => [ { "text" => "届かない", "status" => "succeeded", "category" => "配送", "reason" => "未着のため" } ] }.freeze

    setup do
      FakeHandler.calls = []
      FakeHandler.outcome = { "answer" => "Your order ships tomorrow." }
      FakeHandler.resumed = []
      FakeHandler.resumed_models = []
      FakeHandler.resume_outcome = { "answer" => "Refunded." }
      CheckingHandler.checked = []
      CheckingHandler.check_outcome = nil
      FakeHandler.traced = []
      @run = Run.create!(scenario_key: "answer_inquiry", input: { "inquiry" => "Where is my order?" })
    end

    test "records the result of the scenario" do
      perform

      assert_predicate @run.reload, :succeeded?
      assert_equal({ "answer" => "Your order ships tomorrow." }, @run.result)
      assert_not_nil @run.finished_at
      assert_nil @run.remote_job_id
      assert_empty FakeHandler.resumed
    end

    test "keeps the id of the work the scenario left with the provider, then waits for it in the same trace" do
      FakeHandler.outcome = RemoteJob.new(id: "video-1")
      kept_before_waiting = nil
      trace_while_waiting = nil
      FakeHandler.resume_outcome = lambda do
        kept_before_waiting = Run.find(@run.id).remote_job_id
        trace_while_waiting = OpenTelemetry::Trace.current_span.context.hex_trace_id
        { "answer" => "A video of the kettle." }
      end

      workflow_span = with_tracing { perform(retryable: false) }

      @run.reload
      assert_equal "video-1", kept_before_waiting
      assert_equal workflow_span.hex_trace_id, trace_while_waiting, "waits inside the workflow"
      assert_equal "video-1", @run.remote_job_id
      assert_equal [ "video-1" ], FakeHandler.resumed
      assert_equal [ { model: "gpt-5-nano" } ], FakeHandler.resumed_models
      assert_predicate @run, :succeeded?
      assert_equal({ "answer" => "A video of the kettle." }, @run.result)
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
    end

    test "records a failure while waiting for the work left with the provider, and keeps its id" do
      FakeHandler.outcome = RemoteJob.new(id: "video-1")
      FakeHandler.resume_outcome = -> { raise RubyLLM::Error, "Video generation failed: expired" }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_nil @run.result
      assert_equal "video-1", @run.remote_job_id
      assert_equal "プロバイダーのエラー", @run.failure["kind"]
      assert_equal "Video generation failed: expired", @run.failure["message"]
    end

    test "keeps no id when leaving the work with the provider fails" do
      FakeHandler.outcome = -> { raise RubyLLM::RateLimitError, "Rate limit reached" }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_nil @run.remote_job_id
      assert_empty FakeHandler.resumed
    end

    test "waits for the work kept with a run when its job runs again, instead of leaving it once more" do
      started_at = 2.minutes.ago.change(usec: 0)
      @run.update!(started_at: started_at, remote_job_id: "video-1", trace_ids: [ "11111111111111111111111111111111" ])

      workflow_span = with_tracing { perform(retryable: false) }

      @run.reload
      assert_empty FakeHandler.calls
      assert_equal [ "video-1" ], FakeHandler.resumed
      assert_equal [ { model: "gpt-5-nano" } ], FakeHandler.resumed_models
      assert_equal started_at, @run.started_at
      assert_predicate @run, :succeeded?
      assert_equal({ "answer" => "Refunded." }, @run.result)
      assert_equal [ "11111111111111111111111111111111", workflow_span.hex_trace_id ], @run.traces.map(&:id)
    end

    test "waits for the kept work even for a scenario that may start over" do
      @run.update!(started_at: 1.minute.ago, remote_job_id: "video-1")

      perform(retryable: true)

      assert_empty FakeHandler.calls
      assert_equal [ "video-1" ], FakeHandler.resumed
      assert_predicate @run.reload, :succeeded?
    end

    test "passes the inputs and the models to the handler as keywords" do
      perform

      assert_equal [ { inquiry: "Where is my order?", model: "gpt-5-nano" } ], FakeHandler.calls
    end

    test "records a provider failure without reporting it" do
      FakeHandler.outcome = -> { raise RubyLLM::UnauthorizedError, "Incorrect API key provided" }

      assert_no_error_reported { perform }

      assert_predicate @run.reload, :failed?
      assert_nil @run.result
      assert_equal "認証の失敗", @run.failure["kind"]
      assert_equal "Incorrect API key provided", @run.failure["message"]
    end

    test "treats a timeout from the HTTP client as a provider failure" do
      FakeHandler.outcome = -> { raise Faraday::TimeoutError, "execution expired" }

      assert_no_error_reported { perform }

      assert_equal "タイムアウト", @run.reload.failure["kind"]
    end

    test "records and reports an unexpected error" do
      FakeHandler.outcome = -> { raise NoMethodError, "undefined method 'content'" }

      assert_error_reported(NoMethodError) { perform }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
    end

    test "fails and reports a run whose generated files could not all be stored, keeping none of them" do
      FakeHandler.outcome = { "speech" => fake_speech, "slow_speech" => fake_speech }
      uploads = 0
      failing_second = lambda do |upload, *args, **options|
        uploads += 1
        raise IOError, "disk full" if uploads == 2

        upload.call(*args, **options)
      end

      with_storage_upload(failing_second) do
        assert_error_reported(IOError) { perform }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "IOError", @run.failure["kind"]
      assert_equal "disk full", @run.failure["message"]
      assert_nil @run.result
      assert_empty @run.generated_files
    end

    test "fails a run whose generated video could not be downloaded, keeping nothing of its result" do
      video = RubyLLM::Video.new(url: "https://vidgen.x.ai/expired.mp4", mime_type: "video/mp4", model: "grok-imagine-video-1.5")
      video.define_singleton_method(:to_blob) { raise Faraday::ResourceNotFound, "the server responded with status 404" }
      FakeHandler.outcome = { "video" => video, "model" => "grok-imagine-video-1.5" }

      assert_no_error_reported { perform }

      @run.reload
      assert_predicate @run, :failed?
      assert_equal "取得の失敗", @run.failure["kind"]
      assert_equal "Faraday::ResourceNotFound", @run.failure["error_class"]
      assert_equal "the server responded with status 404", @run.failure["message"]
      assert_nil @run.result
      assert_empty @run.generated_files
    end

    test "fails a ticket workflow run whose step fails, and asks nothing after that step" do
      run = Run.create!(scenario_key: "run_ticket_workflow", input: { "ticket" => "電気ケトルの電源が入りません。" })
      chat = ScriptedChat.new(
        -> { RubyLLM::Message.new(role: :assistant, content: '{"category":"商品の不具合","reason":"電源が入らないため"}', model: "gpt-5-nano") },
        -> { raise RubyLLM::RateLimitError, "Rate limit reached" }
      )

      with_chat(chat) do
        assert_no_error_reported { RunJob.perform_now(run) }
      end

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal "RubyLLM::RateLimitError", run.failure["error_class"]
      assert_equal 2, chat.questions.size, "the review step must not ask after the draft step failed"
    end

    test "fails a token count whose input exceeds the model's limit, as that kind of failure" do
      run = Run.create!(scenario_key: "count_tokens", input: { "instructions" => "サポートの担当者です。", "question" => "返品できますか。" })
      chat = ScriptedChat.new(-> { raise RubyLLM::ContextLengthExceededError, "Your input exceeds the context window of this model." })

      with_chat(chat) do
        assert_no_error_reported { RunJob.perform_now(run) }
      end

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal "入力がモデルの上限を超えた", run.failure["kind"]
      assert_equal "Your input exceeds the context window of this model.", run.failure["message"]
      assert_equal [ "返品できますか。" ], chat.questions
    end

    # The main model's requests never reach OpenAI, so the error recorded is
    # the fallback model's, while the run names both providers. The switch
    # itself is kept nowhere: only a result holds it.
    test "fails a fallback run whose fallback model also failed, as that kind of failure, keeping no switch" do
      run = Run.create!(scenario_key: "fall_back_to_another_provider", input: { "inquiry" => "配送予定日を教えてください。" })
      overloaded = RubyLLM::OverloadedError.new("Overloaded")
      switch = ChatHelpers::ScriptedFallback.new(
        from: RubyLLM.models.find("gpt-5-nano"), to: RubyLLM.models.find("claude-haiku-4-5"),
        error: Faraday::ConnectionFailed.new("Failed to open TCP connection to api.openai.invalid:443"), attempt: 1,
        response: nil, fallback_error: overloaded
      )
      chat = ScriptedChat.new(lambda do
        chat.fall_back(switch)
        raise overloaded
      end)

      with_context(chat) do
        assert_no_error_reported { RunJob.perform_now(run) }
      end

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal({
        "provider" => "OpenAI、Anthropic",
        "kind" => "過負荷",
        "error_class" => "RubyLLM::OverloadedError",
        "message" => "Overloaded",
        "hint" => FailureKinds::PROVIDER_OUTAGE
      }, run.failure)
      assert_equal [ "配送予定日を教えてください。" ], chat.questions
    end

    # With a fake key, a request that reached Anthropic would fail as a
    # provider error and go unreported: the missing file is found first.
    test "fails and reports a run whose document is missing, before calling the provider" do
      run = Run.create!(scenario_key: "cite_return_policy", input: { "inquiry" => "返品できますか。" })
      missing = Catalog.scenario("cite_return_policy").with(documents: [
        Scenario::Document.new(name: "policy", label: "返品ポリシー", path: "documents/missing-policy.pdf")
      ])
      run.define_singleton_method(:scenario) { missing }

      assert_error_reported(Errno::ENOENT) { RunJob.perform_now(run) }

      assert_predicate run.reload, :failed?
      assert_nil run.result
      assert_equal "Errno::ENOENT", run.failure["kind"]
      assert_match "missing-policy.pdf", run.failure["message"]
    end

    test "does nothing for a finished run" do
      @run.succeed!({ "answer" => "done" })

      perform

      assert_empty FakeHandler.calls
    end

    test "starts a retryable scenario over when its job runs again" do
      @run.update!(started_at: 1.minute.ago)

      perform

      assert_equal 1, FakeHandler.calls.size
      assert_predicate @run.reload, :succeeded?
    end

    test "fails a scenario that must not run twice, and has no chat to continue, when its job runs again" do
      @run.update!(started_at: 1.minute.ago)

      assert_no_error_reported { perform(retryable: false) }

      assert_empty FakeHandler.calls
      assert_predicate @run.reload, :failed?
      assert_equal "ジョブの中断", @run.failure["kind"]
      assert_match "もう一度実行", @run.failure["hint"]
    end

    test "stops the run for approval when the scenario hands back a waiting chat" do
      chat = create_refund_chat
      create_pending_refund_call(chat, tool_call_id: "call_1", order_id: 7)
      FakeHandler.outcome = -> { ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id) }

      perform(retryable: false)

      assert_predicate @run.reload, :awaiting_approval?
      assert_equal chat.id, @run.chat_id
      assert_equal [ "call_1" ], @run.approval_requests.map { |request| request["tool_call_id"] }
      assert_nil @run.result
    end

    test "leaves a run that waits for approval alone" do
      @run = create_awaiting_run

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_empty FakeHandler.resumed
      assert_predicate @run.reload, :awaiting_approval?
    end

    test "continues the chat of a run that was decided, instead of starting over" do
      @run = create_awaiting_run
      @run.update!(started_at: 2.minutes.ago)
      @run.resume!("call_1", "approved")
      started_at = @run.reload.started_at

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_equal [ @run.chat_id ], FakeHandler.resumed.map(&:id)
      assert_equal [ {} ], FakeHandler.resumed_models, "a chat is continued without the models"
      assert_predicate @run.reload, :succeeded?
      assert_equal({ "answer" => "Refunded." }, @run.result)
      assert_equal started_at, @run.started_at
    end

    test "continues the chat even when the run had started and the scenario must not run twice" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.update!(started_at: 1.minute.ago)

      perform(retryable: false)

      assert_equal 1, FakeHandler.resumed.size
      assert_predicate @run.reload, :succeeded?
    end

    test "records a failed resumption and keeps the decision" do
      @run = create_awaiting_run
      @run.resume!("call_1", "denied")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "boom" }

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_nil @run.result
      assert_equal "サーバー側のエラー", @run.failure["kind"]
      assert_equal "denied", @run.approval_requests.sole["decision"]
    end

    test "keeps the ID of work the scenario left with the provider, then waits for it in the same workflow" do
      FakeHandler.outcome = RemoteWork.new("interactions/abc", :pending)
      seen_while_waiting = {}
      FakeHandler.resume_outcome = lambda do
        seen_while_waiting[:remote_job_id] = @run.reload.remote_job_id
        seen_while_waiting[:trace_id] = OpenTelemetry::Trace.current_span.context.hex_trace_id
        { "report" => "調査の結果" }
      end

      workflow_span = with_tracing { perform(retryable: false) }

      assert_equal 1, FakeHandler.calls.size
      assert_equal [ "interactions/abc" ], FakeHandler.resumed
      assert_equal "interactions/abc", seen_while_waiting[:remote_job_id]
      assert_equal workflow_span.hex_trace_id, seen_while_waiting[:trace_id]
      @run.reload
      assert_predicate @run, :succeeded?
      assert_equal({ "report" => "調査の結果" }, @run.result)
      assert_equal "interactions/abc", @run.remote_job_id
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
    end

    test "waits for the work kept at the provider when the job runs again, instead of starting over" do
      started_at = 5.minutes.ago.round
      @run.update!(started_at: started_at)
      @run.record_remote_job_id!("interactions/abc")

      perform(retryable: false)

      assert_empty FakeHandler.calls
      assert_equal [ "interactions/abc" ], FakeHandler.resumed
      @run.reload
      assert_predicate @run, :succeeded?
      assert_equal({ "answer" => "Refunded." }, @run.result)
      assert_equal started_at, @run.started_at
    end

    test "continues the chat of a run that also kept the ID of work at the provider" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.record_remote_job_id!("interactions/abc")

      perform(retryable: false)

      assert_equal [ @run.chat_id ], FakeHandler.resumed.map(&:id)
      assert_predicate @run.reload, :succeeded?
    end

    test "does not try a chat again when continuing it fails in a way that may pass" do
      @run = create_awaiting_run
      @run.resume!("call_1", "approved")
      @run.record_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "boom" }

      # Deciding queued a job already; only what continuing the chat queues counts.
      assert_no_enqueued_jobs(only: RunJob) { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "サーバー側のエラー", @run.failure["kind"]
    end

    test "fails a run whose research failed, keeping its ID, without reporting it" do
      @run.record_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research failed: boom (job abc)", job: RemoteWork.new("abc", :failed)) }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_equal "調査の失敗", @run.failure["kind"]
      assert_equal "Research failed: boom (job abc)", @run.failure["message"]
      assert_equal "interactions/abc", @run.remote_job_id
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails a run whose wait ran past its deadline" do
      @run.record_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::TimeoutError.new("Research timed out (job abc)", job: RemoteWork.new("abc", :pending)) }

      assert_no_error_reported { perform(retryable: false) }

      assert_predicate @run.reload, :failed?
      assert_equal "待ち時間の上限", @run.failure["kind"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "tries a run waiting on the provider again a minute later when fetching the work fails in a way that may pass" do
      job = RemoteWork.new("abc", :pending)
      @run.record_remote_job_id!("interactions/abc")
      [
        -> { raise RubyLLM::UnauthorizedError, "invalid_grant" },
        -> { raise Faraday::ConnectionFailed, "refused" },
        -> { raise RubyLLM::ServerError, "boom" },
        -> { raise RubyLLM::ResearchJob::TimeoutError.new("Research request timed out (job abc)", job: job), cause: Faraday::TimeoutError.new("slow") }
      ].each.with_index(1) do |failure, count|
        FakeHandler.resume_outcome = failure

        freeze_time do
          assert_no_error_reported { perform(retryable: false) }

          assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
        end
        @run.reload
        assert_predicate @run, :running?, count
        assert_nil @run.finished_at
        assert_equal count, @run.retries
      end
      assert_equal "タイムアウト", @run.failure["kind"]
    end

    test "tries again a minute later when the wait that follows the submission fails in a way that may pass" do
      FakeHandler.outcome = RemoteWork.new("interactions/abc", :pending)
      FakeHandler.resume_outcome = -> { raise RubyLLM::UnauthorizedError, "invalid_rapt" }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :running?
      assert_equal "interactions/abc", @run.remote_job_id
      assert_equal "認証の失敗", @run.failure["kind"]
      assert_enqueued_with(job: RunJob, args: [ @run ])
    end

    test "fails a submission that fails in a way that may pass, as nothing was left at the provider" do
      FakeHandler.outcome = -> { raise RubyLLM::RateLimitError, "Quota exceeded" }

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "レート制限", @run.failure["kind"]
      assert_nil @run.remote_job_id
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails a run waiting on the provider once it has been tried again as often as allowed" do
      @run.update!(failure: { "kind" => "接続の失敗", "retries" => Run::MAX_RETRIES - 1 })
      @run.record_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise Faraday::ConnectionFailed, "refused" }

      perform(retryable: false)

      assert_predicate @run.reload, :running?
      assert_equal Run::MAX_RETRIES, @run.retries
      assert_enqueued_with(job: RunJob, args: [ @run ])
      clear_enqueued_jobs

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "接続の失敗", @run.failure["kind"]
      assert_equal "refused", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "records that the provider cancelled the work, without reporting it" do
      @run.record_remote_job_id!("interactions/abc")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research cancelled: stopped by user (job abc)", job: RemoteWork.new("abc", :cancelled)) }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :cancelled?
      assert_not_nil @run.finished_at
      assert_equal "取り消し", @run.failure["kind"]
      assert_equal "Research cancelled: stopped by user (job abc)", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails as expired a run whose work the provider no longer has" do
      @run.record_remote_job_id!("interactions/abc")
      not_found = RubyLLM::Error.new("Requested entity was not found.", response: Data.define(:status, :body).new(404, ""))
      FakeHandler.resume_outcome = -> { raise not_found }

      assert_no_error_reported { perform(retryable: false) }

      @run.reload
      assert_predicate @run, :failed?
      assert_equal "期限切れ", @run.failure["kind"]
      assert_equal "Requested entity was not found.", @run.failure["message"]
      assert_no_enqueued_jobs only: RunJob
    end

    test "fails as its kind, not as expired, a 404 on a run that kept no ID" do
      FakeHandler.outcome = -> { raise RubyLLM::Error.new("Not found", response: Data.define(:status, :body).new(404, "")) }

      perform(retryable: false)

      assert_predicate @run.reload, :failed?
      assert_equal "プロバイダーのエラー", @run.failure["kind"]
      assert_equal "RubyLLM::Error", @run.failure["error_class"]
    end

    test "records a cancellation whether or not the run kept an ID" do
      FakeHandler.outcome = -> { raise RubyLLM::ResearchJob::Error.new("Research cancelled:  (job abc)", job: RemoteWork.new("abc", :cancelled)) }

      perform(retryable: false)

      assert_predicate @run.reload, :cancelled?
      assert_nil @run.remote_job_id
      assert_equal "取り消し", @run.failure["kind"]
    end

    test "queues a run again after a minute" do
      freeze_time do
        RunJob.retry_later(@run)

        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "fails the run when its scenario is no longer defined" do
      @run.update!(scenario_key: "removed_scenario")

      assert_error_reported { RunJob.perform_now(@run) }

      assert_predicate @run.reload, :failed?
    end

    test "runs the scenario inside a workflow that carries the conversation id, and records its trace" do
      workflow_span = with_tracing { perform }

      assert_equal @run.conversation_id, workflow_span.attributes["gen_ai.conversation.id"]
      assert_equal [ workflow_span.hex_trace_id ], @run.reload.traces.map(&:id)
    end

    test "records the trace of a run that stopped for approval" do
      chat = create_refund_chat
      create_pending_refund_call(chat)
      FakeHandler.outcome = -> { ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id) }

      workflow_span = with_tracing { perform(retryable: false) }

      assert_predicate @run.reload, :awaiting_approval?
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
    end

    test "records no trace id when tracing is off" do
      perform

      assert_equal [], @run.reload.trace_ids
    end

    test "fails a submission that failed, and neither keeps work nor checks on any" do
      FakeHandler.outcome = -> { raise RubyLLM::BadRequestError, "Invalid file format" }

      assert_no_error_reported { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :failed?
      assert_equal "不正なリクエスト", @run.failure["kind"]
      assert_nil @run.remote_job
      assert_no_enqueued_jobs
    end

    test "keeps the work a scenario left with the provider, checks on it in a minute, and records the submission's trace" do
      FakeHandler.outcome = openai_batch

      freeze_time do
        workflow_span = with_tracing { perform(retryable: false, handler: CheckingHandler) }

        assert_predicate @run.reload, :running?
        assert_equal "batch_1", @run.remote_job_id
        assert_equal %w[batch openai validating], @run.remote_job.values_at("kind", "provider", "raw_status")
        assert_equal({ "total" => 5, "completed" => 0, "failed" => 0 }, @run.remote_job["request_counts"])
        assert_nil @run.remote_job["checked_at"]
        assert_equal [ Run::Trace.new(workflow_span.hex_trace_id, Time.current) ], @run.traces
        assert_equal Time.current, @run.started_at
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "checks on unfinished work outside any workflow, keeps what it found, and checks again in a minute" do
      keep_work(started_at: 5.minutes.ago)
      started_at = @run.started_at
      CheckingHandler.check_outcome = openai_batch(raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 2, "failed" => 0 })

      freeze_time do
        with_tracing { perform(retryable: false, handler: CheckingHandler) }

        assert_predicate @run.reload, :running?
        assert_equal [ "batch_1" ], CheckingHandler.checked
        assert_equal [ [ :check, false ] ], FakeHandler.traced
        assert_equal "in_progress", @run.remote_job["raw_status"]
        assert_equal({ "total" => 5, "completed" => 2, "failed" => 0 }, @run.remote_job["request_counts"])
        assert_equal Time.current, Time.zone.parse(@run.remote_job["checked_at"])
        assert_empty FakeHandler.calls
        assert_empty FakeHandler.resumed
        assert_empty @run.traces
        assert_equal started_at, @run.started_at
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "collects work that ended inside the workflow, and records the result with the collection's trace" do
      keep_work(started_at: 1.hour.ago)
      started_at = @run.started_at
      CheckingHandler.check_outcome = openai_batch(raw_status: "completed", request_counts: { "total" => 5, "completed" => 5, "failed" => 0 })
      FakeHandler.resume_outcome = RESULT

      workflow_span = with_tracing { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :succeeded?
      assert_equal RESULT, @run.result
      assert_equal [ "batch_1" ], FakeHandler.resumed
      assert_equal [ [ :check, false ], [ :resume, true ] ], FakeHandler.traced
      assert_equal "completed", @run.remote_job["raw_status"]
      assert_equal [ workflow_span.hex_trace_id ], @run.traces.map(&:id)
      assert_equal @run.conversation_id, workflow_span.attributes["gen_ai.conversation.id"]
      assert_equal started_at, @run.started_at
      assert_empty FakeHandler.calls
      assert_no_enqueued_jobs
    end

    test "fails work the provider ended without finishing it, keeping the part it finished" do
      keep_work
      CheckingHandler.check_outcome = openai_batch(raw_status: "expired", request_counts: { "total" => 5, "completed" => 3, "failed" => 0 })
      FakeHandler.resume_outcome = RESULT

      assert_no_error_reported { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :failed?
      assert_equal "プロバイダー側の処理の失敗", @run.failure["kind"]
      assert_equal "OpenAI", @run.failure["provider"]
      assert_equal "expired", @run.failure["raw_status"]
      assert_match "expired", @run.failure["message"]
      assert_match "24 時間以内", @run.failure["hint"]
      assert_equal RESULT, @run.result
      assert_no_enqueued_jobs
    end

    test "cancels a run whose work was cancelled at the provider, keeping the part it finished" do
      keep_work
      CheckingHandler.check_outcome = openai_batch(raw_status: "cancelled")
      FakeHandler.resume_outcome = RESULT

      perform(retryable: false, handler: CheckingHandler)

      assert_predicate @run.reload, :cancelled?
      assert_equal "プロバイダー側の処理の取り消し", @run.failure["kind"]
      assert_equal "OpenAI", @run.failure["provider"]
      assert_equal "cancelled", @run.failure["raw_status"]
      assert_match "取り消された", @run.failure["hint"]
      assert_equal RESULT, @run.result
      assert_not_nil @run.finished_at
    end

    test "carries a check that could not reach the provider over to the next check" do
      keep_work
      CheckingHandler.check_outcome = -> { raise Faraday::ConnectionFailed, "Failed to open TCP connection" }

      freeze_time do
        assert_no_error_reported { with_tracing { perform(retryable: false, handler: CheckingHandler) } }

        assert_predicate @run.reload, :running?
        assert_equal({ "kind" => "接続の失敗", "message" => "Failed to open TCP connection", "at" => Time.current.iso8601(3) }, @run.remote_job["check_failure"])
        assert_empty @run.traces
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "carries a collection that failed at the provider over to the next check, recording no trace" do
      keep_work
      CheckingHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "The server had an error" }

      freeze_time do
        assert_no_error_reported { with_tracing { perform(retryable: false, handler: CheckingHandler) } }

        assert_predicate @run.reload, :running?
        assert_equal({ "kind" => "サーバー側のエラー", "message" => "The server had an error", "at" => Time.current.iso8601(3) }, @run.remote_job["check_failure"])
        assert_empty @run.traces
        assert_enqueued_with(job: RunJob, args: [ @run ], at: 1.minute.from_now)
      end
    end

    test "fails, reports, and stops checking on a collection that fails for an error of this app" do
      keep_work
      CheckingHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise NoMethodError, "undefined method 'content' for nil" }

      assert_error_reported(NoMethodError) { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
      assert_nil @run.result
      assert_no_enqueued_jobs
    end

    test "fails, reports, and stops checking on a check that fails for an error of this app" do
      keep_work
      CheckingHandler.check_outcome = -> { raise NoMethodError, "undefined method 'refresh'" }

      assert_error_reported(NoMethodError) { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :failed?
      assert_equal "NoMethodError", @run.failure["kind"]
      assert_no_enqueued_jobs
    end

    test "carries a failed check over until 48 hours after the submission, and then fails with its error" do
      travel_to(Time.zone.local(2026, 9, 21, 10, 0, 0)) { keep_work }
      CheckingHandler.check_outcome = -> { raise Faraday::ConnectionFailed, "refused" }

      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 0)) { perform(retryable: false, handler: CheckingHandler) }

      assert_predicate @run.reload, :running?
      assert_enqueued_jobs 1

      clear_enqueued_jobs
      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 1)) do
        assert_no_error_reported { perform(retryable: false, handler: CheckingHandler) }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "接続の失敗", @run.failure["kind"]
      assert_equal "refused", @run.failure["message"]
      assert_no_enqueued_jobs
    end

    test "gives up on a collection that fails at the provider more than 48 hours after the submission" do
      travel_to(Time.zone.local(2026, 9, 21, 10, 0, 0)) { keep_work }
      CheckingHandler.check_outcome = openai_batch(raw_status: "completed")
      FakeHandler.resume_outcome = -> { raise RubyLLM::ServerError, "The server had an error" }

      travel_to(Time.zone.local(2026, 9, 23, 10, 0, 1)) do
        assert_no_error_reported { perform(retryable: false, handler: CheckingHandler) }
      end

      assert_predicate @run.reload, :failed?
      assert_equal "サーバー側のエラー", @run.failure["kind"]
      assert_nil @run.result
      assert_no_enqueued_jobs
    end

    test "leaves the same work and one check each when the check runs twice in a row" do
      keep_work
      CheckingHandler.check_outcome = openai_batch(raw_status: "in_progress", request_counts: { "total" => 5, "completed" => 1, "failed" => 0 })

      perform(retryable: false, handler: CheckingHandler)
      first = @run.reload.remote_job.except("checked_at")
      perform(retryable: false, handler: CheckingHandler)

      assert_equal first, @run.reload.remote_job.except("checked_at")
      assert_predicate @run, :running?
      assert_enqueued_jobs 2, only: RunJob
    end

    test "finds the run a queued job was for" do
      serialized = RunJob.new(@run).serialize

      assert_equal @run, RunJob.run_from(serialized)
      assert_nil RunJob.run_from(ApplicationJob.new.serialize)
    end

    private

    # The run left a batch with the provider when its job first ran.
    def keep_work(started_at: 1.minute.ago)
      @run.update!(started_at: started_at)
      @run.keep_remote_job!(Scenario.new(**Scenario.members.index_with(nil)).remote_state(openai_batch))
    end

    def perform(retryable: true, handler: FakeHandler)
      scenario = Scenario.new(
        key: "answer_inquiry",
        demo_key: "responses-api",
        name: "問い合わせに回答する",
        providers: %w[openai],
        models: { "model" => "gpt-5-nano" },
        inputs: [ Scenario::Input.new(name: "inquiry", label: "問い合わせ", default: "", required: true) ],
        documents: [],
        handler_name: handler.name,
        result_kind: "text_answer",
        retryable: retryable
      )
      @run.define_singleton_method(:scenario) { scenario }
      RunJob.perform_now(@run)
    end

    # Runs the block with spans exported to memory, and returns the workflow's span.
    def with_tracing
      exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
      subscriber = Observability::RubyLLMSpanSubscriber.new(tracer: provider.tracer("test"), capture_content: false)
      subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, subscriber)

      yield
      exporter.finished_spans.find { |span| span.name.start_with?("invoke_agent") }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
      # Shutting down clears the exporter, so the spans are read first.
      provider.shutdown
    end
  end
end
