module ModelFallbacks
  # Answers a customer inquiry as the support desk, with a model of another
  # provider to fall back to when the main model cannot answer.
  #
  # The main model's outage is staged, not waited for: the chat is built in
  # a context whose OpenAI requests go to a host that cannot be reached. The
  # context copies the app's configuration, so the fallback model reaches
  # Anthropic as usual and the rest of the app is untouched.
  class AnswerWithFallback < ApplicationAction
    # .invalid is reserved (RFC 2606) and resolvers answer that it does not
    # exist, so every request fails to connect without reaching OpenAI or
    # costing anything. A connection failure is one of the errors that
    # trigger a fallback by default, after RubyLLM's own retries run out.
    UNREACHABLE_OPENAI_API_BASE = "https://api.openai.invalid/v1".freeze

    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      顧客からの問い合わせに、丁寧な日本語で簡潔に回答してください。
      注文や配送の実際の状況は分からないため、確認の方法と、次にできることを案内してください。
    TEXT

    def initialize(inquiry:, model:, fallback_model:)
      @inquiry = inquiry
      @model = model
      @fallback_model = fallback_model
    end

    def perform
      outage = RubyLLM.context { |config| config.openai_api_base = UNREACHABLE_OPENAI_API_BASE }
      fallbacks = []

      chat = outage.chat(model: @model)
        .with_instructions(INSTRUCTIONS)
        .with_fallbacks(@fallback_model)
        .after_fallback { |fallback| fallbacks << fallback_record(fallback) }
      response = chat.ask(@inquiry)

      {
        "answer" => response.content,
        "model" => response.model,
        "primary_model" => @model,
        "primary_api_base" => UNREACHABLE_OPENAI_API_BASE,
        "fallbacks" => fallbacks
      }
    end

    private

    # from and to are the models the chat switched between. The fallback's
    # own provider is nil for a fallback given as a model id.
    def fallback_record(fallback)
      {
        "attempt" => fallback.attempt,
        "from" => { "provider" => fallback.from.provider, "model" => fallback.from.id },
        "to" => { "provider" => fallback.to.provider, "model" => fallback.to.id },
        "error_class" => fallback.error.class.name,
        "error_message" => fallback.error.message,
        "succeeded" => fallback.succeeded?
      }
    end
  end
end
