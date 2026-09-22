class CreateShopOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :shop_orders, comment: "架空の EC サイトの注文。代表シナリオの実行ごとに入力から作る" do |t|
      t.text :description, null: false, comment: "注文の説明（注文番号、商品、金額、支払いの状況）。入力の文をそのまま持つ"
      t.string :status, null: false, default: "paid", comment: "状態（paid:支払い済み, refunded:返金済み）"
      t.text :refund_reason, comment: "返金の理由。AI がツールに渡した値"
      t.datetime :refunded_at, comment: "返金した日時"
      t.timestamps
    end
  end
end
