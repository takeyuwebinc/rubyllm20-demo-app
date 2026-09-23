# Puts stand-ins in place of RubyLLM.research_later and
# RubyLLM::ResearchJob.find for the length of a block, so that code that
# submits or loads a research job reaches no provider. Each test scripts the
# job they hand back. The arguments of every call are yielded as they are
# made.
module ResearchHelpers
  # A research job as RubyLLM hands it back, answering as scripted. Its wait
  # returns itself, or raises the scripted error, and keeps how it was
  # called. An error given as a Proc is built with the job, as RubyLLM's
  # errors hold the job they were raised for.
  class ScriptedResearchJob
    attr_reader :id, :agent, :status, :message, :tokens, :cost, :raw, :waits

    def initialize(id: "v1_research", agent: "deep-research-preview-04-2026", status: :completed, message: nil,
                   tokens: RubyLLM::Tokens.new, cost: RubyLLM::Cost.from_h({}), raw: { "status" => "completed" }, wait_error: nil)
      @id = id
      @agent = agent
      @status = status
      @message = message
      @tokens = tokens
      @cost = cost
      @raw = raw
      @wait_error = wait_error
      @waits = []
    end

    def pending? = status == :pending
    def completed? = status == :completed
    def cancelled? = status == :cancelled

    def wait(timeout:, interval:)
      @waits << { timeout: timeout, interval: interval }
      raise(@wait_error.respond_to?(:call) ? @wait_error.call(self) : @wait_error) if @wait_error

      self
    end
  end

  def with_research(submitted: nil, found: nil)
    original_research_later = RubyLLM.method(:research_later)
    original_find = RubyLLM::ResearchJob.method(:find)
    calls = { research_later: [], find: [] }
    RubyLLM.define_singleton_method(:research_later) do |prompt, **options|
      calls[:research_later] << [ prompt, options ]
      submitted.respond_to?(:call) ? submitted.call : submitted
    end
    RubyLLM::ResearchJob.define_singleton_method(:find) do |id, **options|
      calls[:find] << [ id, options ]
      found.respond_to?(:call) ? found.call : found
    end
    yield calls
  ensure
    RubyLLM.define_singleton_method(:research_later, original_research_later)
    RubyLLM::ResearchJob.define_singleton_method(:find, original_find)
  end
end
