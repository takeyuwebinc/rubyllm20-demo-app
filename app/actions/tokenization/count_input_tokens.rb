module Tokenization
  # Counts the input tokens of a support desk's chat before it is sent, and
  # tells whether they fit the model's context window.
  #
  # Nothing is asked: the count is the whole point, and asking would spend the
  # time and the money that counting beforehand is meant to save. count_tokens
  # sends the chat, with the question as its next message, to the provider's
  # counting endpoint, so the count includes the instructions and the
  # formatting as the provider counts them. The question is not added to the
  # chat. The count records no usage and emits no chat event, so the trace
  # shows only the counting request.
  #
  # The limits come from the model the chat resolved from the registry, not
  # from the person running this: a limit that someone enters judges their
  # budget rather than the model. The input fits while it is smaller than the
  # context window, and what is left goes negative once it is over. OpenAI's
  # counting endpoint answers for input past the window as well, so an input
  # that does not fit comes back as a verdict rather than as an error. The
  # maximum output is only reported: a verdict that set aside the full output
  # for every request would call inputs too long that fit. A model the
  # registry has no context window for gets no verdict.
  class CountInputTokens < ApplicationAction
    def initialize(instructions:, question:, model:)
      @instructions = instructions
      @question = question
      @model = model
    end

    def perform
      chat = RubyLLM.chat(model: @model).with_instructions(@instructions)
      input_tokens = chat.count_tokens(@question)

      context_window = chat.model.context_window
      if context_window
        remaining = context_window - input_tokens
        fits = input_tokens < context_window
      end

      {
        "input_tokens" => input_tokens,
        "context_window" => context_window,
        "max_output_tokens" => chat.model.max_output_tokens,
        "remaining" => remaining,
        "fits" => fits,
        "model" => chat.model.id
      }
    end
  end
end
