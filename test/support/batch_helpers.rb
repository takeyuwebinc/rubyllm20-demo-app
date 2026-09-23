# Helpers for batches, which RubyLLM submits to a provider and collects
# later, without calling a provider.
module BatchHelpers
  # The states in which OpenAI has ended a batch, whatever became of it.
  OPENAI_TERMINAL_STATUSES = %w[completed failed expired cancelled].freeze

  # Stands in for OpenAI's side of the Batch API, in place of the three
  # operations RubyLLM's OpenAI provider performs on a batch: creating it
  # (after uploading the requests), fetching its state, and reading its
  # result files. Everything RubyLLM does around them, such as keeping the
  # batch in its table and adding the answers to the chats, runs as it is.
  class FakeOpenAIBatches
    attr_reader :submissions, :checks, :collections
    attr_accessor :raw_status, :request_counts, :results, :errors

    def initialize
      @submissions = []
      @checks = []
      @collections = []
      @raw_status = "validating"
      @request_counts = { "total" => 0, "completed" => 0, "failed" => 0 }
      @results = []
      @errors = {}
    end

    # The requests are what RubyLLM would upload: a custom id, the model,
    # and the body of each request. The batches are numbered from batch_1.
    def create_batch(requests)
      raise errors[:create] if errors[:create]

      submissions << requests
      state("batch_#{submissions.size}")
    end

    # The configuration is that of the provider RubyLLM checked with.
    def find_batch(id, config:)
      raise errors[:check] if errors[:check]

      checks << { id: id, config: config }
      state(id)
    end

    # Each result is [index, answer, failure status]: an answer where the
    # request succeeded, nil and :failed or :cancelled where it did not.
    def batch_results(id)
      raise errors[:collect] if errors[:collect]

      collections << id
      results
    end

    private

    def state(id)
      {
        id: id, raw_status: raw_status, completed: OPENAI_TERMINAL_STATUSES.include?(raw_status),
        request_counts: request_counts, request_count: request_counts&.fetch("total", nil)
      }.compact
    end
  end

  def with_openai_batches(fake = FakeOpenAIBatches.new)
    provider = RubyLLM::Providers::OpenAI
    names = %i[create_batch find_batch batch_results]
    own = names.to_h { |name| [ name, provider.instance_method(name) ] }.select { |_, method| method.owner == provider }
    provider.define_method(:create_batch) { |requests| fake.create_batch(requests) }
    provider.define_method(:find_batch) { |id| fake.find_batch(id, config: config) }
    provider.define_method(:batch_results) { |id, batch_protocol: nil| fake.batch_results(id) }
    yield fake
  ensure
    names.each { |name| provider.remove_method(name) }
    own.each { |name, method| provider.define_method(name, method) }
  end

  # An answer to one ticket, as RubyLLM reads it from OpenAI's result file.
  def classification_answer(category, reason, model: "gpt-5-nano-2025-08-07", input_tokens: 180, output_tokens: 40)
    RubyLLM::Message.new(
      role: :assistant, content: { category: category, reason: reason }.to_json, model: model,
      input_tokens: input_tokens, output_tokens: output_tokens
    )
  end

  # The model record the chats of a batch belong to. Made first: RubyLLM
  # would otherwise load its whole registry into the empty test database.
  def create_model_record(model: "gpt-5-nano")
    RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: model, provider: "openai") { |record| record.name = model }
  end

  # A batch as RubyLLM returns it from OpenAI in the given state. Its status
  # is read from the state by RubyLLM itself.
  def openai_batch(id: "batch_1", raw_status: "validating", request_counts: { "total" => 5, "completed" => 0, "failed" => 0 })
    RubyLLM::Batch.new(
      provider: RubyLLM::Providers::OpenAI.new(RubyLLM.config),
      id: id, raw_status: raw_status, completed: OPENAI_TERMINAL_STATUSES.include?(raw_status), request_counts: request_counts
    )
  end
end
