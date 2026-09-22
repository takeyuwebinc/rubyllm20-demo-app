module ToolApproval
  # Answers a customer who asks for a refund. The model may propose one by
  # calling IssueRefund, and nothing is refunded until a person approves it.
  #
  # The tool and the agent are defined here, beside the action that uses
  # them, so the demo shows the three together.
  #
  # The chat is persisted, so the proposal outlives the job that produced
  # it: the decision is recorded from the web process, and another job
  # continues the chat. RefundAgent.find restores the tools on a chat loaded
  # from the database. A bare Chat.find would not know that the call needs
  # approval, and the model would go on with an error as the tool's result.
  class AnswerRefundRequest < ApplicationAction
    class IssueRefund < RubyLLM::Tool
      description "注文の全額を返金する。返金の実行には担当者の承認が要る"
      parameter :order_id, type: "integer", description: "返金する注文の ID"
      parameter :reason, description: "返金の理由。顧客の申し出に基づく 1 文"
      requires_approval

      # The default name is derived from the full class name and would carry
      # the namespaces.
      def self.tool_name = "issue_refund"

      # Runs only after a person approved it. It may still run twice if the
      # job is interrupted between the refund and saving its result, which
      # is why the order refuses a second refund on its own.
      def execute(order_id:, reason:)
        order = Shop::Order.find_by(id: order_id)
        return { error: "注文 #{order_id} は見つからない" } unless order

        order.refund!(reason)
        { order_id: order.id, status: order.status, refunded_at: order.refunded_at }
      end
    end

    class RefundAgent < RubyLLM::Agent
      chat_model Chat
      instructions <<~TEXT
        あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクの担当者です。
        顧客からの返金の申し出を、対象の注文と照らして判断してください。
        商品の破損や不具合など、返金に応じるべき申し出なら、issue_refund で返金を提案してください。
        返金は担当者の承認を経て実行されます。ツールの結果を踏まえて、顧客への回答を丁寧な日本語で簡潔に書いてください。
        ツールの結果が、利用者（担当者）が呼び出しを却下した（denied）というエラーなら、返金は実行されず、この後も実行されません。
        承認待ちとは書かず、返金できないことと、次にできること（交換、修理、写真の送付など）を案内してください。
      TEXT
      tools IssueRefund
    end

    def initialize(inquiry:, order:, model:)
      @inquiry = inquiry
      @order_description = order
      @model = model
    end

    # Starts the conversation. Returns the chat while it waits for approval,
    # or the result once the model has answered.
    def perform
      order = Shop::Order.create!(description: @order_description)
      chat = RefundAgent.create!(model: @model)
      response = chat.ask(<<~TEXT)
        対象の注文（ID: #{order.id}）:
        #{order.description}

        顧客からの申し出:
        #{@inquiry}
      TEXT
      self.class.outcome(chat, response, order)
    end

    class << self
      # Records a person's decision on a proposed tool call. The decision is
      # kept on the tool call's record, where the job that resumes reads it.
      def decide(chat, tool_call_id, approved:)
        chat = RefundAgent.find(chat.id)
        approved ? chat.approve(tool_call_id) : chat.deny(tool_call_id)
      end

      # Continues a chat that stopped for approval: runs the approved refund,
      # or tells the model it was denied, and gets the answer to the customer.
      def resume(chat)
        chat = RefundAgent.find(chat.id)
        response = chat.complete
        outcome(chat, response, proposed_order(chat))
      end

      def outcome(chat, response, order)
        return chat if chat.awaiting_approval?

        {
          "answer" => response.content,
          "order" => order && {
            "description" => order.description,
            "status" => order.status,
            "refund_reason" => order.refund_reason,
            "refunded_at" => order.refunded_at
          },
          "model" => response.model
        }
      end

      private

      # The order the model asked to refund, read back from the recorded
      # tool call. Nil when the model named an order that does not exist.
      def proposed_order(chat)
        call = chat.messages.flat_map { |message| message.tool_calls.values }.find { |c| c.name == IssueRefund.tool_name }
        Shop::Order.find_by(id: call.arguments["order_id"]) if call
      end
    end
  end
end
