module Batches
  # Classifies support tickets in one batch. OpenAI answers a batch within
  # 24 hours at half the price of the same calls made one at a time, which
  # suits work nobody is waiting on.
  #
  # Each ticket gets a chat of its own, persisted. RubyLLM then keeps the
  # batch in its own table on submission, loads it again by its id in
  # another process, and adds each answer to its chat when it is collected.
  class ClassifyTickets < ApplicationAction
    # Categories are stored and shown as these words, so no table of labels
    # has to be kept in step with the result's display.
    CATEGORIES = %w[配送 返品・返金 商品の不具合 支払い その他].freeze

    class Classification < Schematist::Schema
      string :category, enum: CATEGORIES, description: "チケットの区分"
      string :reason, description: "その区分にした理由"
    end

    INSTRUCTIONS = <<~TEXT
      あなたは、家電と日用品を扱う架空の EC サイトのサポートデスクで、届いたチケットを振り分ける担当者です。
      チケットを、#{CATEGORIES.join("、")}のいずれか 1 つに分類し、そう判断した理由を 1 文で書いてください。
    TEXT

    # One ticket per paragraph: a blank line separates the tickets. Browsers
    # send the line breaks of a form as CRLF, so they are made LF first.
    def initialize(tickets:, model:)
      @tickets = tickets.gsub(/\R/, "\n").split(/(?:\n[[:blank:]]*){2,}/).map(&:strip).reject(&:blank?)
      @model = model
    end

    # Submits every ticket in one batch, and returns the batch without
    # waiting for OpenAI to process it.
    def perform
      chats = @tickets.map do |ticket|
        Chat.create!(model: @model)
            .with_instructions(INSTRUCTIONS)
            .with_schema(Classification)
            .ask_later(ticket)
      end
      RubyLLM.batch(chats)
    end

    class << self
      # Asks OpenAI how the batch is doing, and returns the batch. Checks
      # repeat every minute until the batch ends, so they are left out of
      # the instrumentation: each would otherwise make a trace of its own.
      def check(batch_id)
        quiet = RubyLLM.context { |config| config.instrumenter = nil }
        RubyLLM::Batch.find(batch_id, context: quiet).refresh
      end

      # Collects the answers of a batch that has ended, however it ended:
      # OpenAI keeps what it finished before a batch expired or was
      # cancelled, and bills what an expired batch finished. The last check
      # stored how the batch ended.
      def resume(batch_id)
        batch = RubyLLM::Batch.find(batch_id)
        answers = batch.messages
        {
          "batch_id" => batch.id,
          "provider" => batch.provider,
          "raw_status" => batch.raw_status,
          "request_counts" => batch.request_counts,
          "model" => answers.compact.first&.model,
          "tickets" => batch.chats.each_with_index.map { |chat, index| ticket(chat, answers[index], batch.statuses[index]) }
        }
      end

      private

      # A ticket whose request failed has no answer; RubyLLM logs why, and
      # nothing else says.
      def ticket(chat, answer, status)
        classification = classification(answer) || {}
        {
          "text" => chat.messages.find { |message| message.role == :user }.content,
          "status" => status.to_s,
          "category" => classification["category"],
          "reason" => classification["reason"]
        }
      end

      # The schema is not stored with the chat, but the answer was written
      # to it, so it reads as JSON. An answer that does not, such as a
      # refusal, is left without a category rather than failing the whole
      # batch, whose other answers were billed.
      def classification(answer)
        parsed = answer&.parsed
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
