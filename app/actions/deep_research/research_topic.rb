module DeepResearch
  # Hands a research topic to Vertex AI's Deep Research agent, which searches
  # the web, reads the pages, plans, and writes a report with its sources.
  #
  # The research runs at the provider for minutes, so it is submitted and
  # waited for in two steps. perform only submits it and hands back the job.
  # .resume loads the job by its ID, from this process or any other, and
  # waits for the report. RubyLLM keeps no record of research jobs, so the ID
  # is what the caller keeps.
  class ResearchTopic < ApplicationAction
    # The one agent Vertex AI's Deep Research offers; RubyLLM refuses any
    # other ID. It is an agent rather than a model of RubyLLM's registry.
    AGENT = "deep-research-preview-04-2026".freeze

    # Vertex AI ends a research after 120 minutes. The wait allows a little
    # more, so that a research the provider ends at that limit can still be
    # read: with the same limit, the wait could give up just before it. A
    # wait that runs out leaves the research going at the provider.
    WAIT_TIMEOUT = 130 * 60

    # Each poll is a request, and a span in the trace, so the polls are kept
    # sparse: a research takes minutes, not seconds.
    POLL_INTERVAL = 30

    def self.resume(id)
      job = RubyLLM::ResearchJob.find(id, provider: :vertexai)
      job.wait(timeout: WAIT_TIMEOUT, interval: POLL_INTERVAL)
      result(job)
    end

    def initialize(topic:)
      @topic = topic
    end

    # No tools are given, so the agent uses its default ones: Google Search
    # and fetching the pages it finds.
    def perform
      RubyLLM.research_later(@topic, provider: :vertexai, agent: AGENT)
    end

    class << self
      private

      # The report is a Message like a chat's answer. The provider may leave
      # out its steps, its thinking summary, and the URLs of its sources, so
      # any of them may be empty. A report cut short, by an output budget
      # for one, is incomplete rather than completed.
      def result(job)
        report = job.message
        {
          "report" => report.content,
          "completed" => job.completed?,
          "provider_status" => job.raw["status"],
          "finish_reason" => report.finish_reason&.to_s,
          "citations" => report.citations.map { |citation| source(citation) },
          "steps" => report.server_tool_calls.map { |call| step(call) },
          "thinking" => report.thinking&.text,
          "job_id" => job.id,
          "agent" => job.agent,
          # Output includes thinking. Counts the provider did not report are nil.
          "tokens" => {
            "input" => job.tokens.input,
            "output" => job.tokens.output,
            "thinking" => job.tokens.thinking,
            "cache_read" => job.tokens.cache_read
          },
          # Vertex AI reports no price, and an agent has none in RubyLLM's
          # registry, so the cost is unknown unless the provider gives one.
          "cost" => job.cost.total&.to_f
        }
      end

      # text and the indexes point to the span of the report that the source
      # supports; cited_text is the passage of the source itself.
      def source(citation)
        {
          "url" => citation.url,
          "title" => citation.title,
          "text" => citation.text,
          "start_index" => citation.start_index,
          "end_index" => citation.end_index,
          "cited_text" => citation.cited_text
        }
      end

      # A step the agent ran at the provider, such as a search. A call holds
      # its input and a result holds what came back.
      def step(call)
        { "type" => call.type, "name" => call.name, "input" => call.input, "result" => call.result }
      end
    end
  end
end
