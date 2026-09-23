# Helpers for batches, which RubyLLM submits to a provider and collects
# later, without calling a provider.
module BatchHelpers
  # The states in which OpenAI has ended a batch, whatever became of it.
  OPENAI_TERMINAL_STATUSES = %w[completed failed expired cancelled].freeze

  # A batch as RubyLLM returns it from OpenAI in the given state. Its status
  # is read from the state by RubyLLM itself.
  def openai_batch(id: "batch_1", raw_status: "validating", request_counts: { "total" => 5, "completed" => 0, "failed" => 0 })
    RubyLLM::Batch.new(
      provider: RubyLLM::Providers::OpenAI.new(RubyLLM.config),
      id: id, raw_status: raw_status, completed: OPENAI_TERMINAL_STATUSES.include?(raw_status), request_counts: request_counts
    )
  end
end
