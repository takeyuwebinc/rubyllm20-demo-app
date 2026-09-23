module Citations
  # Answers a customer inquiry from the attached return policy, and lists
  # which part of the answer rests on which passage and page of the policy.
  #
  # The provider matches the answer to the passages: the app attaches the
  # document and asks once. Every quote is taken from the document by the
  # provider, not written by the model.
  class AnswerFromReturnPolicy < ApplicationAction
    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      添付した返品ポリシーだけを根拠に、根拠にした箇所を引用して、顧客からの問い合わせに丁寧な日本語で簡潔に回答してください。
      返品ポリシーに書かれていないことは、書かれていないと伝えてください。
    TEXT

    def initialize(inquiry:, policy:, model:)
      @inquiry = inquiry
      @policy = policy
      @model = model
    end

    def perform
      chat = RubyLLM.chat(model: @model)
                    .with_instructions(INSTRUCTIONS)
                    .with_citations
      response = chat.ask(@inquiry, with: @policy)

      {
        "answer" => response.content,
        "model" => response.model,
        # RubyLLM titles the attached document with its filename, so a
        # citation's title names the document it quotes.
        "document" => File.basename(@policy),
        "citations" => response.citations.map { |citation| source(citation) }
      }
    end

    private

    # Each citation ties the span of the answer (text, start_index,
    # end_index) to the passage of the document it rests on (cited_text).
    # For a PDF, start_page and end_page are the pages of the passage,
    # counted from 1, both included.
    def source(citation)
      {
        "title" => citation.title,
        "cited_text" => citation.cited_text,
        "text" => citation.text,
        "start_index" => citation.start_index,
        "end_index" => citation.end_index,
        "start_page" => citation.start_page,
        "end_page" => citation.end_page,
        "source_index" => citation.source_index
      }
    end
  end
end
