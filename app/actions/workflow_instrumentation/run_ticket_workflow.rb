module WorkflowInstrumentation
  # Answers a support ticket in three steps: classify it, draft a reply, and
  # review the draft.
  #
  # Each step calls the model once, on a chat of its own. The step's span and
  # the chat span inside it then report the same time, tokens, and cost, and
  # an earlier step's messages do not inflate a later step's input.
  class RunTicketWorkflow < ApplicationAction
    CATEGORIES = %w[配送 返品・返金 商品の不具合 支払い その他].freeze
    PASSED = "合格".freeze
    NEEDS_REVISION = "要修正".freeze
    VERDICTS = [ PASSED, NEEDS_REVISION ].freeze

    class Classification < Schematist::Schema
      string :category, enum: CATEGORIES, description: "チケットの区分"
      string :reason, description: "その区分にした理由"
    end

    class Review < Schematist::Schema
      string :verdict, enum: VERDICTS, description: "下書きをそのまま送れるか"
      array :findings, of: :string, description: "直すべき点。合格なら空"
    end

    CLASSIFY_INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクで、届いたチケットを振り分ける担当者です。
      チケットを、#{CATEGORIES.join("、")}のいずれか 1 つに分類し、そう判断した理由を 1 文で書いてください。
    TEXT

    DRAFT_INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
      顧客からのチケットに、丁寧な日本語で簡潔に回答してください。
      注文や配送の実際の状況は分からないため、確認の方法と、次にできることを案内してください。
    TEXT

    REVIEW_INSTRUCTIONS = <<~TEXT
      あなたは、サポートデスクの回答を送る前に点検する担当者です。
      回答の下書きが、チケットの内容と区分に合っているか、確かめられない事実を約束していないか、丁寧で分かりやすいかを点検してください。
      直すべき点がなければ、判定を「#{PASSED}」とし、指摘を空にしてください。
      直すべき点があれば、判定を「#{NEEDS_REVISION}」とし、直すべき点を指摘に 1 つずつ書いてください。
    TEXT

    def initialize(ticket:, model:)
      @ticket = ticket
      @model = model
    end

    def perform
      RubyLLM.workflow("サポートチケットへの回答") do |workflow|
        classification = workflow.step("分類") { classify }
        draft = workflow.step("回答の下書き") { write_draft(classification) }
        review = workflow.step("レビュー") { review_draft(draft, classification) }

        {
          "category" => classification["category"],
          "reason" => classification["reason"],
          "draft" => draft.content,
          "verdict" => review["verdict"],
          "findings" => review["findings"],
          "model" => draft.model
        }
      end
    end

    private

    def classify
      chat.with_instructions(CLASSIFY_INSTRUCTIONS).with_schema(Classification).ask(@ticket).parsed
    end

    def write_draft(classification)
      chat.with_instructions(DRAFT_INSTRUCTIONS).ask(<<~TEXT)
        区分: #{classification["category"]}

        チケット:
        #{@ticket}
      TEXT
    end

    def review_draft(draft, classification)
      chat.with_instructions(REVIEW_INSTRUCTIONS).with_schema(Review).ask(<<~TEXT).parsed
        区分: #{classification["category"]}

        チケット:
        #{@ticket}

        回答の下書き:
        #{draft.content}
      TEXT
    end

    def chat
      RubyLLM.chat(model: @model)
    end
  end
end
