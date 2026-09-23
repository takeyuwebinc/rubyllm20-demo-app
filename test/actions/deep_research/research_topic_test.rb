require "test_helper"

module DeepResearch
  class ResearchTopicTest < ActiveSupport::TestCase
    include ResearchHelpers

    test "submits the topic once to Vertex AI's Deep Research agent, and hands back the job it got" do
      job = ScriptedResearchJob.new(status: :pending, raw: { "status" => "in_progress" })

      returned = with_research(submitted: job) do |calls|
        ResearchTopic.perform(topic: "返品の法制度を整理してほしい").tap do
          assert_equal [ [ "返品の法制度を整理してほしい", { provider: :vertexai, agent: "deep-research-preview-04-2026" } ] ], calls[:research_later]
          assert_empty calls[:find]
        end
      end

      assert_same job, returned
    end

    test "lets a failed submission propagate, handing back no job" do
      with_research(submitted: -> { raise RubyLLM::RateLimitError, "Quota exceeded" }) do
        assert_raises(RubyLLM::RateLimitError) { ResearchTopic.perform(topic: "返品の法制度") }
      end
    end

    test "loads the job by its ID, waits up to 130 minutes polling every 30 seconds, and returns the report" do
      job = ScriptedResearchJob.new(
        id: "v1_abc",
        message: report(
          content: "# 返品の法制度\n\n通信販売には法定のクーリング・オフがない。",
          citations: [
            RubyLLM::Citation.new(url: "https://www.caa.go.jp/policies/", title: "特定商取引法ガイド", text: "法定のクーリング・オフがない",
              cited_text: "通信販売にはクーリング・オフ制度はありません", start_index: 12, end_index: 26)
          ],
          server_tool_calls: [
            RubyLLM::ServerToolCall.new(type: "google_search_call", id: "s1", name: "google_search", input: { "queries" => [ "通信販売 返品 特約" ] }, raw: {}),
            RubyLLM::ServerToolCall.new(type: "google_search_result", id: "s1", name: "google_search", result: [ { "url" => "https://www.caa.go.jp/policies/" } ], raw: {})
          ],
          thinking: RubyLLM::Thinking.new(text: "まず法令を確かめる。")
        ),
        tokens: RubyLLM::Tokens.new(input: 12_000, output: 8_000, thinking: 3_000, cache_read: 500),
        raw: { "status" => "completed" }
      )

      result = with_research(found: job) do |calls|
        ResearchTopic.resume("v1_abc").tap do
          assert_equal [ [ "v1_abc", { provider: :vertexai } ] ], calls[:find]
          assert_empty calls[:research_later]
        end
      end

      assert_equal [ { timeout: 130 * 60, interval: 30 } ], job.waits
      assert_equal({
        "report" => "# 返品の法制度\n\n通信販売には法定のクーリング・オフがない。",
        "completed" => true,
        "provider_status" => "completed",
        "finish_reason" => "stop",
        "citations" => [ {
          "url" => "https://www.caa.go.jp/policies/", "title" => "特定商取引法ガイド", "text" => "法定のクーリング・オフがない",
          "start_index" => 12, "end_index" => 26, "cited_text" => "通信販売にはクーリング・オフ制度はありません"
        } ],
        "steps" => [
          { "type" => "google_search_call", "name" => "google_search", "input" => { "queries" => [ "通信販売 返品 特約" ] }, "result" => nil },
          { "type" => "google_search_result", "name" => "google_search", "input" => nil, "result" => [ { "url" => "https://www.caa.go.jp/policies/" } ] }
        ],
        "thinking" => "まず法令を確かめる。",
        "job_id" => "v1_abc",
        "agent" => "deep-research-preview-04-2026",
        "tokens" => { "input" => 12_000, "output" => 8_000, "thinking" => 3_000, "cache_read" => 500 },
        "cost" => nil
      }, result)
    end

    test "returns the partial report of a job the provider stopped before it finished" do
      job = ScriptedResearchJob.new(
        status: :incomplete,
        message: report(content: "途中までのレポート", finish_reason: :max_tokens),
        raw: { "status" => "budget_exceeded" }
      )

      result = with_research(found: job) { ResearchTopic.resume("v1_research") }

      assert_equal "途中までのレポート", result["report"]
      assert_equal false, result["completed"]
      assert_equal "budget_exceeded", result["provider_status"]
      assert_equal "max_tokens", result["finish_reason"]
    end

    test "returns empty lists, no thinking, and blank token counts when the provider reports none" do
      job = ScriptedResearchJob.new(message: report(content: "レポート"), tokens: RubyLLM::Tokens.new(input: 100, output: 50))

      result = with_research(found: job) { ResearchTopic.resume("v1_research") }

      assert_equal [], result["citations"]
      assert_equal [], result["steps"]
      assert_nil result["thinking"]
      assert_equal({ "input" => 100, "output" => 50, "thinking" => nil, "cache_read" => nil }, result["tokens"])
    end

    test "keeps a thinking summary without text as none" do
      job = ScriptedResearchJob.new(message: report(content: "レポート", thinking: RubyLLM::Thinking.new(signature: "sig")))

      result = with_research(found: job) { ResearchTopic.resume("v1_research") }

      assert_nil result["thinking"]
    end

    test "keeps the cost when the provider reports one" do
      job = ScriptedResearchJob.new(message: report(content: "レポート"), tokens: RubyLLM::Tokens.new(input: 1, output: 1),
        cost: RubyLLM::Cost.from_h({ total: 0.42 }, tokens: RubyLLM::Tokens.new(input: 1, output: 1)))

      result = with_research(found: job) { ResearchTopic.resume("v1_research") }

      assert_in_delta 0.42, result["cost"]
    end

    test "returns the report of a job that had already finished, after a wait that returns at once" do
      job = ScriptedResearchJob.new(message: report(content: "済んだレポート"))

      result = with_research(found: job) { ResearchTopic.resume("v1_research") }

      assert_equal 1, job.waits.size
      assert_equal "済んだレポート", result["report"]
    end

    test "lets a failed research propagate, returning no result" do
      failed = ScriptedResearchJob.new(status: :failed, wait_error: ->(job) { RubyLLM::ResearchJob::Error.new("Research failed: boom (job v1_research)", job: job) })

      with_research(found: failed) do
        assert_raises(RubyLLM::ResearchJob::Error) { ResearchTopic.resume("v1_research") }
      end
    end

    test "lets a cancelled research propagate, returning no result" do
      cancelled = ScriptedResearchJob.new(status: :cancelled, wait_error: ->(job) { RubyLLM::ResearchJob::Error.new("Research cancelled:  (job v1_research)", job: job) })

      error = with_research(found: cancelled) do
        assert_raises(RubyLLM::ResearchJob::Error) { ResearchTopic.resume("v1_research") }
      end

      assert FailureKinds.cancelled?(error)
    end

    test "lets a failure to load the job propagate" do
      with_research(found: -> { raise RubyLLM::UnauthorizedError, "invalid_grant" }) do
        assert_raises(RubyLLM::UnauthorizedError) { ResearchTopic.resume("v1_research") }
      end
    end

    private

    # A report as RubyLLM reads it from Vertex AI: no model, since an agent
    # is not one.
    def report(content:, citations: [], server_tool_calls: [], thinking: nil, finish_reason: :stop)
      RubyLLM::Message.new(role: :assistant, content: content, model: nil, citations: citations,
        server_tool_calls: server_tool_calls, thinking: thinking, finish_reason: finish_reason)
    end
  end
end
