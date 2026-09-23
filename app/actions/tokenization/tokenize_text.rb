module Tokenization
  # Splits a text into the tokens of xAI's tokenizer, to show where it breaks.
  #
  # RubyLLM.tokenize returns a RubyLLM::Tokenization: the token ids in text
  # order, their count, and raw, the provider's answer as it came. The ids
  # alone do not show where the text breaks. xAI's answer gives each token's
  # string and bytes as well, and they are kept as xAI gave them.
  #
  # A token that ends partway through a character, as a four-byte emoji does,
  # has an empty string. Its bytes are still there: the bytes of all the
  # tokens joined give the text back, while the strings joined do not.
  #
  # Only the text is tokenized, without instructions, tools, attachments, or
  # the formatting of a chat. Tokenizing is not billed as usage, and token
  # ids differ between models, so compare tokenizations of the same model.
  class TokenizeText < ApplicationAction
    def initialize(text:, model:)
      @text = text
      @model = model
    end

    # The length of the text is not checked here. xAI refuses what it cannot
    # take, and RubyLLM raises its error.
    def perform
      # provider: is required. In RubyLLM 2.0.0, "grok-4.3" alone resolves to
      # Perplexity's "xai/grok-4.3", which the registry ranks above xAI, and
      # fails without Perplexity's settings.
      tokenization = RubyLLM.tokenize(@text, model: @model, provider: :xai)

      {
        "count" => tokenization.count,
        "model" => tokenization.model,
        "tokens" => tokenization.raw.fetch("token_ids").map do |token|
          {
            "id" => token["token_id"],
            "string" => token["string_token"],
            "bytes" => token["token_bytes"]
          }
        end
      }
    end
  end
end
