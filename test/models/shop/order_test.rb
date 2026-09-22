require "test_helper"

module Shop
  class OrderTest < ActiveSupport::TestCase
    test "refunds a paid order with the reason and the time" do
      order = Order.create!(description: "注文番号 C-1、7,980 円")

      order.refund!("商品が破損していた")

      assert_predicate order.reload, :refunded?
      assert_equal "商品が破損していた", order.refund_reason
      assert_not_nil order.refunded_at
    end

    test "keeps the first refund when refunded again" do
      order = Order.create!(description: "注文番号 C-1、7,980 円")
      order.refund!("最初の理由")
      first_refunded_at = order.refunded_at

      travel 1.minute do
        order.refund!("後からの理由")
      end

      assert_predicate order.reload, :refunded?
      assert_equal "最初の理由", order.refund_reason
      assert_equal first_refunded_at, order.refunded_at
    end
  end
end
