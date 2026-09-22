module Shop
  # An order of the fictional shop. A demo run makes its own, so that there is
  # always an order that can still be refunded, and never touches a real one.
  class Order < ApplicationRecord
    enum :status, { paid: "paid", refunded: "refunded" }, validate: true

    validates :description, presence: true

    # Refunds the order once. A tool can run twice after an interruption, so
    # a refunded order keeps its first refund.
    def refund!(reason)
      return self if refunded?

      update!(status: :refunded, refund_reason: reason, refunded_at: Time.current)
      self
    end
  end
end
