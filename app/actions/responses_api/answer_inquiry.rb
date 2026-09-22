module ResponsesApi
  # Answers a customer inquiry as the support desk.
  #
  # Nothing here names the protocol. RubyLLM 2.0 sends OpenAI chat models
  # through the Responses API by default, and the request span in the trace
  # shows which endpoint was called.
  class AnswerInquiry < ApplicationAction
    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      顧客からの問い合わせに、丁寧な日本語で簡潔に回答してください。
      注文や配送の実際の状況は分からないため、確認の方法と、次にできることを案内してください。
    TEXT

    def initialize(inquiry:, model:)
      @inquiry = inquiry
      @model = model
    end

    def perform
      chat = RubyLLM.chat(model: @model).with_instructions(INSTRUCTIONS)
      response = chat.ask(@inquiry)

      { "answer" => response.content, "model" => response.model }
    end
  end
end
