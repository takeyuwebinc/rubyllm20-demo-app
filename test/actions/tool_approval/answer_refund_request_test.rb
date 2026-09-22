require "test_helper"

module ToolApproval
  class AnswerRefundRequestTest < ActiveSupport::TestCase
    include ScreenHelpers

    IssueRefund = AnswerRefundRequest::IssueRefund
    RefundAgent = AnswerRefundRequest::RefundAgent

    # Stands in for a persisted chat after the model answered, without a
    # provider: reports whether it waits for approval, and its messages.
    class ScriptedChat
      Response = Struct.new(:content, :model)

      attr_reader :messages, :questions

      def initialize(awaiting_approval:, answer: "返金を承りました。", model: "gpt-5-nano-2025-08-07", messages: [])
        @awaiting_approval = awaiting_approval
        @response = Response.new(answer, model)
        @messages = messages
        @questions = []
      end

      def awaiting_approval? = @awaiting_approval

      def ask(question)
        @questions << question
        @response
      end

      def complete = @response
    end

    RecordedCall = Struct.new(:name, :arguments)
    RecordedMessage = Struct.new(:tool_calls)

    test "the refund tool needs approval and is named without its namespace" do
      assert_predicate IssueRefund, :requires_approval?
      assert_equal "issue_refund", IssueRefund.tool_name
      assert_equal %w[order_id reason], JSON.parse(IssueRefund.new.parameters_schema.to_json)["properties"].keys
    end

    test "the refund tool refunds the order and reports it" do
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円")

      result = IssueRefund.new.execute(order_id: order.id, reason: "商品が破損していた")

      assert_predicate order.reload, :refunded?
      assert_equal({ order_id: order.id, status: "refunded", refunded_at: order.refunded_at }, result)
    end

    test "the refund tool reports an unknown order without touching any" do
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円")

      result = IssueRefund.new.execute(order_id: order.id + 1, reason: "商品が破損していた")

      assert_match(/見つからない/, result[:error])
      assert_predicate order.reload, :paid?
    end

    test "the refund tool leaves a refunded order as it is and says so" do
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円").refund!("最初の理由")

      result = IssueRefund.new.execute(order_id: order.id, reason: "後からの理由")

      assert_equal "refunded", result[:status]
      assert_equal "最初の理由", order.reload.refund_reason
    end

    test "returns the chat while it waits for approval" do
      chat = ScriptedChat.new(awaiting_approval: true)
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円")

      assert_same chat, AnswerRefundRequest.outcome(chat, chat.complete, order)
    end

    test "returns the answer, the order, and the model once the model answered" do
      chat = ScriptedChat.new(awaiting_approval: false, answer: "返金を承りました。", model: "gpt-5-nano-2025-08-07")
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円").refund!("商品が破損していた")

      result = AnswerRefundRequest.outcome(chat, chat.complete, order)

      assert_equal "返金を承りました。", result["answer"]
      assert_equal "gpt-5-nano-2025-08-07", result["model"]
      assert_equal "注文番号 C-1、7,980 円", result["order"]["description"]
      assert_equal "refunded", result["order"]["status"]
      assert_equal "商品が破損していた", result["order"]["refund_reason"]
      assert_equal order.refunded_at, result["order"]["refunded_at"]
    end

    test "starts with a new order and asks about it and the inquiry, and finishes when the model answers without a tool" do
      chat = ScriptedChat.new(awaiting_approval: false, answer: "返金の対象ではありません。")

      result = with_agent(create!: ->(model:) { chat }) do
        AnswerRefundRequest.perform(inquiry: "返金してください", order: "注文番号 C-1、7,980 円", model: "gpt-5-nano")
      end

      order = Shop::Order.last
      assert_equal "注文番号 C-1、7,980 円", order.description
      assert_predicate order, :paid?
      assert_match(/ID: #{order.id}/, chat.questions.sole)
      assert_match(/注文番号 C-1、7,980 円/, chat.questions.sole)
      assert_match(/返金してください/, chat.questions.sole)
      assert_equal "返金の対象ではありません。", result["answer"]
      assert_equal "paid", result["order"]["status"]
    end

    test "resumes the chat and reads the order back from the recorded tool call" do
      order = Shop::Order.create!(description: "注文番号 C-1、7,980 円").refund!("商品が破損していた")
      chat = ScriptedChat.new(awaiting_approval: false, messages: [
        RecordedMessage.new({ "call_1" => RecordedCall.new("issue_refund", { "order_id" => order.id, "reason" => "商品が破損していた" }) })
      ])
      found = []

      result = with_agent(find: ->(id) { found << id; chat }) { AnswerRefundRequest.resume(Chat.new(id: 42)) }

      assert_equal [ 42 ], found
      assert_equal "refunded", result["order"]["status"]
      assert_equal "返金を承りました。", result["answer"]
    end

    test "reads the order from the first refund call when the model made several" do
      first = Shop::Order.create!(description: "最初の注文").refund!("商品が破損していた")
      second = Shop::Order.create!(description: "2 つ目の注文")
      chat = ScriptedChat.new(awaiting_approval: false, messages: [
        RecordedMessage.new({ "call_1" => RecordedCall.new("issue_refund", { "order_id" => first.id, "reason" => "a" }) }),
        RecordedMessage.new({ "call_2" => RecordedCall.new("issue_refund", { "order_id" => second.id, "reason" => "b" }) })
      ])

      result = with_agent(find: ->(_id) { chat }) { AnswerRefundRequest.resume(Chat.new(id: 42)) }

      assert_equal "最初の注文", result["order"]["description"]
    end

    test "leaves the order empty when the model named an order that does not exist" do
      chat = ScriptedChat.new(awaiting_approval: false, messages: [
        RecordedMessage.new({ "call_1" => RecordedCall.new("issue_refund", { "order_id" => 0, "reason" => "商品が破損していた" }) })
      ])

      result = with_agent(find: ->(_id) { chat }) { AnswerRefundRequest.resume(Chat.new(id: 42)) }

      assert_nil result["order"]
      assert_equal "返金を承りました。", result["answer"]
    end

    test "records the decision on the tool call" do
      chat = create_refund_chat
      create_pending_refund_call(chat, tool_call_id: "call_1")
      create_pending_refund_call(chat, tool_call_id: "call_2")

      AnswerRefundRequest.decide(Chat.find(chat.id), "call_1", approved: true)
      AnswerRefundRequest.decide(Chat.find(chat.id), "call_2", approved: false)

      assert_equal "approved", refund_call_approval("call_1")
      assert_equal "denied", refund_call_approval("call_2")
    end

    private

    # Replaces the agent's ways of making and loading a chat for the block.
    def with_agent(**methods)
      originals = methods.keys.to_h { |name| [ name, RefundAgent.method(name) ] }
      methods.each { |name, body| RefundAgent.define_singleton_method(name, body) }
      yield
    ensure
      originals.each { |name, original| RefundAgent.define_singleton_method(name, original) }
    end
  end
end
