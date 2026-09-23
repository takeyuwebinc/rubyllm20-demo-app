require "test_helper"

module Demos
  class RunTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ScreenHelpers

    # A generated file without a format, as RubyLLM's Video and Image have none.
    GeneratedClip = Struct.new(:to_blob, :mime_type)

    test "starts a run with the given input and queues its job" do
      run = Run.start(runnable_scenario, "inquiry" => "Where is my order?")

      assert_predicate run, :persisted?
      assert_predicate run, :running?
      assert_equal({ "inquiry" => "Where is my order?" }, run.input)
      assert_equal [], run.trace_ids
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "issues a conversation id that Sentry can put in a URL" do
      first = Run.start(runnable_scenario, {})
      second = Run.start(runnable_scenario, {})

      assert_match(/\A[A-Za-z0-9_-]+\z/, first.conversation_id)
      refute_equal first.conversation_id, second.conversation_id
    end

    test "does not record a run whose scenario cannot run" do
      run = assert_no_difference(-> { Run.count }) { Run.start(runnable_scenario(providers: %w[nowhere]), {}) }

      refute_predicate run, :persisted?
      assert_predicate run.errors[:base], :any?
      assert_no_enqueued_jobs
    end

    test "does not record a run with a blank required input, and says which one" do
      run = assert_no_difference(-> { Run.count }) { Run.start(runnable_scenario, "inquiry" => "  ") }

      refute_predicate run, :persisted?
      assert_predicate run.input_errors("inquiry"), :any?
      assert_no_enqueued_jobs
    end

    test "records the result and when it finished" do
      run = create_run

      run.succeed!({ "answer" => "Hello" })

      assert_predicate run.reload, :succeeded?
      assert_equal({ "answer" => "Hello" }, run.result)
      assert_not_nil run.finished_at
    end

    test "never rewrites a finished run" do
      run = create_run
      run.succeed!({ "answer" => "Hello" })

      assert_raises(ActiveRecord::RecordInvalid) { run.fail_with!(RuntimeError.new("late")) }
      assert_predicate run.reload, :succeeded?
    end

    test "keeps a generated file as an attachment named after its key, and a reference to it in the result" do
      run = create_run

      run.succeed!({ "speech" => fake_speech(data: "mp3 bytes"), "model" => "gpt-4o-mini-tts", "characters" => 42 })

      run.reload
      assert_predicate run, :succeeded?
      assert_not_nil run.finished_at
      file = run.generated_files.sole
      assert_equal "speech.mp3", file.filename.to_s
      assert_equal "audio/mpeg", file.content_type
      assert_equal "mp3 bytes", file.download
      assert_equal({
        "speech" => { "filename" => "speech.mp3", "content_type" => "audio/mpeg", "byte_size" => 9 },
        "model" => "gpt-4o-mini-tts",
        "characters" => 42
      }, run.result)
    end

    test "names a generated file that has no format by its MIME type" do
      run = create_run

      run.succeed!({ "video" => GeneratedClip.new("mp4 bytes", "video/mp4") })

      file = run.reload.generated_files.sole
      assert_equal "video.mp4", file.filename.to_s
      assert_equal "video/mp4", file.content_type
      assert_equal({ "filename" => "video.mp4", "content_type" => "video/mp4", "byte_size" => 9 }, run.result["video"])
    end

    test "names a generated file by its key alone when Rails does not know its MIME type" do
      run = create_run

      run.succeed!({ "clip" => GeneratedClip.new("bytes", "application/x-unknown") })

      file = run.reload.generated_files.sole
      assert_equal "clip", file.filename.to_s
      assert_equal "application/x-unknown", file.content_type
    end

    test "keeps every generated file of a result" do
      run = create_run

      run.succeed!({ "speech" => fake_speech(data: "mp3"), "video" => GeneratedClip.new("mp4 bytes", "video/mp4") })

      run.reload
      assert_equal %w[speech.mp3 video.mp4], run.generated_files.map { |file| file.filename.to_s }.sort
      assert_equal({ "filename" => "speech.mp3", "content_type" => "audio/mpeg", "byte_size" => 3 }, run.result["speech"])
      assert_equal({ "filename" => "video.mp4", "content_type" => "video/mp4", "byte_size" => 9 }, run.result["video"])
    end

    test "keeps no attachment for a result without generated files" do
      run = create_run

      run.succeed!({ "answer" => "Hello", "model" => "gpt-5-nano" })

      assert_equal({ "answer" => "Hello", "model" => "gpt-5-nano" }, run.reload.result)
      assert_empty run.generated_files
    end

    test "refuses to record success on a finished run before storing anything" do
      %w[succeeded failed cancelled].each do |status|
        run = create_run(status: status, result: { "answer" => "before" }, finished_at: 1.minute.ago)
        uploads = 0

        with_storage_upload(->(upload, *args, **options) { uploads += 1; upload.call(*args, **options) }) do
          assert_no_difference([ -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ]) do
            assert_raises(ActiveRecord::RecordInvalid, status) { run.succeed!({ "speech" => fake_speech, "answer" => "after" }) }
          end
        end

        assert_equal 0, uploads, status
        run.reload
        assert_equal status, run.status
        assert_equal({ "answer" => "before" }, run.result, status)
        assert_empty run.generated_files, status
      end
    end

    test "keeps neither the attachments nor the result when storing a generated file fails part way" do
      run = create_run
      uploads = 0
      failing_second = lambda do |upload, *args, **options|
        uploads += 1
        raise IOError, "disk full" if uploads == 2

        upload.call(*args, **options)
      end

      with_storage_upload(failing_second) do
        assert_no_difference([ -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ]) do
          error = assert_raises(IOError) do
            run.succeed!({ "speech" => fake_speech, "video" => GeneratedClip.new("mp4 bytes", "video/mp4") })
          end
          assert_equal "disk full", error.message
        end
      end

      assert_equal 2, uploads
      run.reload
      assert_predicate run, :running?
      assert_nil run.result
      assert_nil run.finished_at
      assert_empty run.generated_files
    end

    # The job records the failure on the same object right after.
    test "leaves nothing of a result for the next save when saving it fails after the files were stored" do
      run = create_run
      failing = true
      run.define_singleton_method(:save!) do |**options|
        next super(**options) unless failing

        failing = false
        raise ActiveRecord::RecordNotSaved.new("Failed to save the record", self)
      end

      assert_no_difference([ -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ]) do
        assert_raises(ActiveRecord::RecordNotSaved) { run.succeed!({ "speech" => fake_speech, "answer" => "after" }) }
        run.fail_with!(ActiveRecord::RecordNotSaved.new("Failed to save the record"))
      end

      run.reload
      assert_predicate run, :failed?
      assert_nil run.result
      assert_empty run.generated_files
    end

    test "refuses to record success on a run waiting for approval before storing anything" do
      run = create_awaiting_run
      uploads = 0

      with_storage_upload(->(upload, *args, **options) { uploads += 1; upload.call(*args, **options) }) do
        assert_raises(ActiveRecord::RecordInvalid) { run.succeed!({ "speech" => fake_speech }) }
      end

      assert_equal 0, uploads
      assert_predicate run.reload, :awaiting_approval?
      assert_nil run.result
      assert_empty run.generated_files
    end

    test "allows the transitions a run can make" do
      assert Run.transition?("running", "awaiting_approval")
      assert Run.transition?("awaiting_approval", "running")
      assert Run.transition?("awaiting_approval", "cancelled")
      refute Run.transition?("succeeded", "running")
      refute Run.transition?("failed", "running")
      refute Run.transition?("cancelled", "failed")
    end

    test "records a provider failure with its kind and likely causes" do
      run = create_run

      run.fail_with!(RubyLLM::RateLimitError.new("You exceeded your current quota"))

      assert_predicate run.reload, :failed?
      assert_not_nil run.finished_at
      assert_equal "レート制限", run.failure["kind"]
      assert_equal "RubyLLM::RateLimitError", run.failure["error_class"]
      assert_equal "You exceeded your current quota", run.failure["message"]
      assert_match "残高", run.failure["hint"]
      assert_equal "OpenAI", run.failure["provider"]
    end

    test "records a provider failure as the kind it is given" do
      run = create_run

      run.fail_with!(RubyLLM::Error.new("Not found"), kind: FailureKinds::EXPIRED)

      assert_predicate run.reload, :failed?
      assert_equal "期限切れ", run.failure["kind"]
      assert_equal "RubyLLM::Error", run.failure["error_class"]
      assert_equal "Not found", run.failure["message"]
      assert_match "7 日", run.failure["hint"]
    end

    test "records an error outside the table by its class, without causes" do
      run = create_run

      run.fail_with!(ArgumentError.new("bad"))

      assert_equal "ArgumentError", run.failure["kind"]
      assert_nil run.failure["hint"]
    end

    test "adds each trace id once" do
      run = create_run

      2.times { run.add_trace_id!("0af7651916cd43dd8448eb211c80319c") }

      assert_equal [ "0af7651916cd43dd8448eb211c80319c" ], run.reload.trace_ids
    end

    test "fails the runs a dead worker left running with nothing kept at the provider, and only those" do
      abandoned = create_run
      finished = create_run.tap { |run| run.succeed!({ "answer" => "done" }) }
      awaiting = create_awaiting_run

      Run.recover_abandoned!([ abandoned.id, finished.id, awaiting.id ])

      assert_predicate abandoned.reload, :failed?
      assert_equal "ワーカーの異常終了", abandoned.failure["kind"]
      assert_predicate finished.reload, :succeeded?
      assert_predicate awaiting.reload, :awaiting_approval?
      assert_no_enqueued_jobs
    end

    test "queues again a run a dead worker left waiting on work kept at the provider" do
      run = create_run(started_at: 5.minutes.ago)
      run.keep_remote_job_id!("interactions/abc")

      Run.recover_abandoned!([ run.id ], message: "Worker 42 died")

      run.reload
      assert_predicate run, :running?
      assert_equal 1, run.retries
      assert_equal "ワーカーの異常終了", run.failure["kind"]
      assert_equal "Worker 42 died", run.failure["message"]
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "fails a run a dead worker left waiting on the provider once it has been tried again as often as allowed" do
      run = create_run(started_at: 5.minutes.ago, failure: { "kind" => "接続の失敗", "retries" => Run::MAX_RETRIES })
      run.keep_remote_job_id!("interactions/abc")

      Run.recover_abandoned!([ run.id ])

      assert_predicate run.reload, :failed?
      assert_equal "ワーカーの異常終了", run.failure["kind"]
      assert_no_enqueued_jobs
    end

    test "keeps the ID of the work left with the provider, and nothing else changes" do
      started_at = 1.minute.ago.round
      run = create_run(started_at: started_at)

      run.keep_remote_job_id!("interactions/abc")

      run.reload
      assert_equal "interactions/abc", run.remote_job_id
      assert_predicate run, :running?
      assert_equal started_at, run.started_at
      assert_nil run.result
      assert_nil run.finished_at
    end

    test "refuses a blank ID, or an ID other than the one already kept" do
      run = create_run

      assert_raises(ArgumentError) { run.keep_remote_job_id!(" ") }
      assert_nil run.reload.remote_job_id

      run.keep_remote_job_id!("interactions/abc")
      assert_raises(ArgumentError) { run.keep_remote_job_id!("interactions/other") }
      assert_equal "interactions/abc", run.reload.remote_job_id
    end

    test "keeping the same ID again changes nothing" do
      run = create_run
      run.keep_remote_job_id!("interactions/abc")

      assert_no_changes -> { run.reload.updated_at } do
        run.keep_remote_job_id!("interactions/abc")
      end
      assert_equal "interactions/abc", run.remote_job_id
    end

    test "keeps an ID only for a running run" do
      finished = create_run.tap { |run| run.succeed!({ "answer" => "done" }) }
      awaiting = create_awaiting_run

      [ finished, awaiting ].each do |run|
        assert_raises(ArgumentError, run.status) { run.keep_remote_job_id!("interactions/abc") }
        assert_nil run.reload.remote_job_id, run.status
      end
      assert_predicate finished, :succeeded?
      assert_predicate awaiting, :awaiting_approval?
    end

    test "records that the provider cancelled the work, with the reason" do
      run = create_run

      run.cancel_with!(RubyLLM::ResearchJob::Error.new("Research cancelled:  (job abc)", job: nil))

      run.reload
      assert_predicate run, :cancelled?
      assert_not_nil run.finished_at
      assert_equal "取り消し", run.failure["kind"]
      assert_equal "OpenAI", run.failure["provider"]
      assert_equal "Research cancelled:  (job abc)", run.failure["message"]
      assert_match "取り消", run.failure["hint"]
    end

    test "records a cancellation on a run waiting for approval" do
      run = create_awaiting_run

      run.cancel_with!(RuntimeError.new("cancelled"))

      assert_predicate run.reload, :cancelled?
    end

    test "never records a cancellation on a finished run" do
      %w[succeeded failed cancelled].each do |status|
        run = create_run(status: status, failure: { "kind" => "before" }, finished_at: 1.minute.ago)

        assert_raises(ActiveRecord::RecordInvalid, status) { run.cancel_with!(RuntimeError.new("late")) }

        run.reload
        assert_equal status, run.status
        assert_equal({ "kind" => "before" }, run.failure, status)
      end
    end

    test "keeps a failure to try again later on a run that stays running, and counts it" do
      run = create_run

      assert run.retry_later!(RubyLLM::UnauthorizedError.new("invalid_grant"))

      run.reload
      assert_predicate run, :running?
      assert_nil run.finished_at
      assert_equal 1, run.retries
      assert_equal "認証の失敗", run.failure["kind"]
      assert_equal "OpenAI", run.failure["provider"]
      assert_equal "invalid_grant", run.failure["message"]
      assert_match "gcloud", run.failure["hint"]

      assert run.retry_later!(Faraday::ConnectionFailed.new("refused"))
      assert_equal 2, run.reload.retries
      assert_equal "接続の失敗", run.failure["kind"]
    end

    test "forgets the failures it tried again after once the run succeeds" do
      run = create_run
      run.retry_later!(Faraday::ConnectionFailed.new("refused"))

      run.succeed!({ "answer" => "done" })

      assert_nil run.reload.failure
      assert_equal 0, run.retries
    end

    test "tries again up to the limit, and then says no without counting" do
      run = create_run(failure: { "kind" => "接続の失敗", "retries" => Run::MAX_RETRIES - 1 })

      assert run.retry_later!(Faraday::ConnectionFailed.new("refused"))
      assert_equal 60, run.reload.retries

      refute run.retry_later!(Faraday::ConnectionFailed.new("refused again"))
      run.reload
      assert_equal 60, run.retries
      assert_equal "refused", run.failure["message"]
      assert_predicate run, :running?
    end

    test "keeps a failure to try again later only on a running run" do
      finished = create_run.tap { |run| run.succeed!({ "answer" => "done" }) }
      awaiting = create_awaiting_run

      [ finished, awaiting ].each do |run|
        assert_raises(ArgumentError, run.status) { run.retry_later!(Faraday::ConnectionFailed.new("refused")) }
        assert_nil run.reload.failure, run.status
      end
      assert_predicate finished, :succeeded?
      assert_predicate awaiting, :awaiting_approval?
    end

    test "lists the runs of a demo, newest first" do
      older = create_run(scenario_key: "answer_inquiry", created_at: 2.minutes.ago)
      newer = create_run(scenario_key: "answer_inquiry", created_at: 1.minute.ago)
      create_run(scenario_key: "cite_return_policy")

      assert_equal [ newer, older ], Run.for_demo(Catalog.demo("responses-api")).latest_first.to_a
    end

    test "keeps a run whose scenario is no longer defined" do
      run = create_run(scenario_key: "removed_scenario")

      assert_nil run.scenario
      assert_predicate run.reload, :persisted?
    end

    test "stops for approval with the chat and what it asked" do
      chat = create_refund_chat
      create_pending_refund_call(chat, tool_call_id: "call_1", order_id: 7, reason: "商品が破損していた")
      run = create_run

      run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id))

      assert_predicate run.reload, :awaiting_approval?
      assert_equal chat.id, run.chat_id
      assert_equal [ {
        "tool_call_id" => "call_1", "name" => "issue_refund",
        "arguments" => { "order_id" => 7, "reason" => "商品が破損していた" }, "decision" => nil
      } ], run.approval_requests
    end

    test "keeps the decision and continues" do
      run = create_awaiting_run

      run.resume!("call_1", "approved")

      assert_predicate run.reload, :running?
      assert_equal "approved", run.approval_requests.sole["decision"]
      assert_enqueued_with(job: RunJob, args: [ run ])
    end

    test "refuses to continue on a request it never made" do
      run = create_awaiting_run

      assert_raises(ArgumentError) { run.resume!("call_9", "approved") }

      assert_predicate run.reload, :awaiting_approval?
      assert_nil run.approval_requests.sole["decision"]
      assert_no_enqueued_jobs
    end

    test "keeps earlier requests and their decisions when it stops again" do
      chat = create_refund_chat
      run = create_awaiting_run(chat: chat, tool_call_id: "call_1")
      ToolApproval::AnswerRefundRequest.decide(Chat.find(chat.id), "call_1", approved: true)
      run.resume!("call_1", "approved")
      create_pending_refund_call(chat, tool_call_id: "call_2", order_id: 8)

      run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id))

      assert_equal [ [ "call_1", "approved" ], [ "call_2", nil ] ],
        run.reload.approval_requests.map { |request| request.values_at("tool_call_id", "decision") }
    end

    test "refuses to stop for approval with nothing to decide" do
      chat = create_refund_chat
      run = create_run

      assert_raises(ArgumentError) { run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id)) }

      assert_predicate run.reload, :running?
      assert_nil run.chat_id
    end

    test "never stops a finished run for approval" do
      chat = create_refund_chat
      create_pending_refund_call(chat)
      run = create_run.tap { |r| r.succeed!({ "answer" => "done" }) }

      assert_raises(ActiveRecord::RecordInvalid) { run.await_approval!(ToolApproval::AnswerRefundRequest::RefundAgent.find(chat.id)) }
      assert_predicate run.reload, :succeeded?
    end

    test "fails for a reason that is not a provider error" do
      run = create_run

      run.fail_as!(FailureKinds::INTERRUPTED)

      assert_predicate run.reload, :failed?
      assert_equal "ジョブの中断", run.failure["kind"]
      assert_match "もう一度実行", run.failure["hint"]
    end

    private

    def runnable_scenario(**overrides)
      Scenario.new(
        key: "answer_inquiry",
        demo_key: "responses-api",
        name: "問い合わせに回答する",
        providers: [],
        models: {},
        inputs: [ Scenario::Input.new(name: "inquiry", label: "問い合わせ", default: "Hi", required: true) ],
        handler_name: "Object",
        result_kind: "text_answer",
        retryable: true,
        **overrides
      )
    end

    def create_run(**attributes)
      Run.create!(scenario_key: "answer_inquiry", input: { "inquiry" => "Hi" }, **attributes)
    end
  end
end
