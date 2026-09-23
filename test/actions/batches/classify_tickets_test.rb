require "test_helper"

module Batches
  class ClassifyTicketsTest < ActiveSupport::TestCase
    include BatchHelpers

    TICKETS = [
      "注文した電気ケトルがまだ届きません。",
      "サイズが合わないので返品したいです。",
      "ドライヤーの電源が入りません。",
      "クレジットカードで二重に請求されています。",
      "ギフト用の包装はできますか。"
    ].freeze

    setup do
      create_model_record
    end

    test "submits every ticket in one batch, each in a chat of its own with the instructions and the schema" do
      with_openai_batches do |openai|
        batch = perform(TICKETS.join("\n\n"))

        assert_kind_of RubyLLM::Batch, batch
        assert_equal "batch_1", batch.id
        assert_equal 1, openai.submissions.size
        requests = openai.submissions.sole
        assert_equal 5, requests.size
        assert_equal [ "gpt-5-nano" ], requests.map { |request| request[:model] }.uniq
        requests.each_with_index do |request, index|
          body = request[:payload].to_json
          assert_includes body, "サポートデスクで、届いたチケットを振り分ける担当者"
          assert_includes body, TICKETS[index]
          format = request[:payload].dig(:text, :format)
          assert_equal "json_schema", format[:type]
          assert_equal ClassifyTickets::CATEGORIES, format.dig(:schema, :properties, :category, :enum)
        end

        chats = Chat.order(:id).last(5)
        chats.each_with_index do |chat, index|
          assert_equal %w[system user], chat.messages.order(:id).map(&:role)
          assert_equal ClassifyTickets::INSTRUCTIONS, chat.messages.find_by(role: "system").content
          assert_equal TICKETS[index], chat.messages.find_by(role: "user").content
        end
        record = RubyLLM::ActiveRecord::Batch.find_by!(provider_batch_id: "batch_1")
        assert_equal "openai", record.provider
        assert_equal chats.map(&:id), record.chat_ids
      end
    end

    test "lets a failed submission raise, keeping no batch" do
      fake = FakeOpenAIBatches.new
      fake.errors[:create] = RubyLLM::BadRequestError.new("Invalid file format for Batch API")

      with_openai_batches(fake) do
        assert_raises(RubyLLM::BadRequestError) { perform(TICKETS.join("\n\n")) }
      end

      assert_equal 0, RubyLLM::ActiveRecord::Batch.count
    end

    test "splits tickets at blank lines, however they are written, and drops empty ones" do
      expected = [ "配送が遅れています。\n追跡番号を教えてください。", "返品したいです。" ]
      inputs = [
        "配送が遅れています。\n追跡番号を教えてください。\n\n返品したいです。",
        "\n\n配送が遅れています。\n追跡番号を教えてください。\n\n\n\n返品したいです。\n\n",
        "配送が遅れています。\n追跡番号を教えてください。\n  \t\n返品したいです。",
        "配送が遅れています。\r\n追跡番号を教えてください。\r\n\r\n返品したいです。\r\n",
        "  配送が遅れています。\n追跡番号を教えてください。  \n\n　\n  返品したいです。  "
      ]

      with_openai_batches do |openai|
        inputs.each do |input|
          assert_difference -> { Chat.count }, 2, input.inspect do
            perform(input)
          end

          assert_equal expected, Chat.order(:id).last(2).map { |chat| chat.messages.find_by!(role: "user").content }, input.inspect
          assert_equal 2, openai.submissions.last.size, input.inspect
        end
      end
    end

    test "submits a single ticket as a batch of one" do
      with_openai_batches do |openai|
        assert_difference -> { Chat.count }, 1 do
          perform("注文した電気ケトルがまだ届きません。")
        end

        assert_equal 1, openai.submissions.size
        assert_equal 1, openai.submissions.sole.size
      end
    end

    test "checks on the batch without instrumenting it, in a context of its own each time" do
      with_openai_batches do |openai|
        perform(TICKETS.join("\n\n"))
        openai.raw_status = "in_progress"
        openai.request_counts = { "total" => 5, "completed" => 2, "failed" => 0 }

        events = capture_events(/\.ruby_llm\z/) do
          2.times { ClassifyTickets.check("batch_1") }
        end
        batch = ClassifyTickets.check("batch_1")

        assert_empty events
        assert_equal [ nil ], openai.checks.map { |check| check[:config].instrumenter }.uniq
        assert_equal 3, openai.checks.map { |check| check[:config].object_id }.uniq.size
        refute_includes openai.checks.map { |check| check[:config] }, RubyLLM.config
        assert_not_nil RubyLLM.config.instrumenter
        assert_equal "in_progress", batch.raw_status
        assert_equal({ "total" => 5, "completed" => 2, "failed" => 0 }, batch.request_counts)
        refute_predicate batch, :complete?
      end
    end

    test "lets a failed check raise" do
      with_openai_batches do |openai|
        perform(TICKETS.join("\n\n"))
        openai.errors[:check] = Faraday::ConnectionFailed.new("Failed to open TCP connection")

        assert_raises(Faraday::ConnectionFailed) { ClassifyTickets.check("batch_1") }
      end
    end

    test "collects the answers of a completed batch into its chats, and reads each ticket's category" do
      with_openai_batches do |openai|
        perform(TICKETS.first(3).join("\n\n"))
        end_batch(openai, "completed", { "total" => 3, "completed" => 2, "failed" => 1 }, [
          [ 0, classification_answer("配送", "未着の問い合わせのため"), nil ],
          [ 1, nil, :failed ],
          [ 2, classification_answer("商品の不具合", "電源が入らないため"), nil ]
        ])

        result = nil
        events = capture_events("usage.ruby_llm") { result = ClassifyTickets.resume("batch_1") }

        assert_equal({
          "batch_id" => "batch_1",
          "provider" => "openai",
          "raw_status" => "completed",
          "request_counts" => { "total" => 3, "completed" => 2, "failed" => 1 },
          "model" => "gpt-5-nano-2025-08-07",
          "tickets" => [
            { "text" => TICKETS[0], "status" => "succeeded", "category" => "配送", "reason" => "未着の問い合わせのため" },
            { "text" => TICKETS[1], "status" => "failed", "category" => nil, "reason" => nil },
            { "text" => TICKETS[2], "status" => "succeeded", "category" => "商品の不具合", "reason" => "電源が入らないため" }
          ]
        }, result)
        assert_equal [ "batch_1" ], openai.collections
        chats = Chat.order(:id).last(3)
        assert_equal [ %w[system user assistant], %w[system user], %w[system user assistant] ], chats.map { |chat| chat.messages.order(:id).map(&:role) }
        assert_equal 2, events.size
        assert_equal [ :chat ], events.map { |event| event.payload[:operation] }.uniq
        assert_equal [ 180 ], events.map { |event| event.payload[:tokens].input }.uniq
      end
    end

    test "collects a batch again without adding any answer twice" do
      with_openai_batches do |openai|
        perform(TICKETS.first(2).join("\n\n"))
        end_batch(openai, "completed", { "total" => 2, "completed" => 2, "failed" => 0 }, [
          [ 0, classification_answer("配送", "未着のため"), nil ],
          [ 1, classification_answer("返品・返金", "返品の申し出のため"), nil ]
        ])

        first = ClassifyTickets.resume("batch_1")
        events = capture_events("usage.ruby_llm") do
          assert_no_difference -> { Message.count } do
            assert_equal first, ClassifyTickets.resume("batch_1")
          end
        end

        assert_empty events
      end
    end

    test "marks every ticket failed when no request of a completed batch succeeded" do
      with_openai_batches do |openai|
        perform(TICKETS.first(2).join("\n\n"))
        end_batch(openai, "completed", { "total" => 2, "completed" => 0, "failed" => 2 }, [ [ 0, nil, :failed ], [ 1, nil, :failed ] ])

        result = ClassifyTickets.resume("batch_1")

        assert_equal %w[failed failed], result["tickets"].map { |ticket| ticket["status"] }
        assert_nil result["model"]
      end
    end

    test "collects a batch of one ticket as a list of one" do
      with_openai_batches do |openai|
        perform(TICKETS.first)
        end_batch(openai, "completed", { "total" => 1, "completed" => 1, "failed" => 0 }, [ [ 0, classification_answer("配送", "未着のため"), nil ] ])

        assert_equal [ "配送" ], ClassifyTickets.resume("batch_1")["tickets"].map { |ticket| ticket["category"] }
      end
    end

    test "collects what an expired batch finished, and marks the rest failed" do
      with_openai_batches do |openai|
        perform(TICKETS.first(3).join("\n\n"))
        end_batch(openai, "expired", { "total" => 3, "completed" => 1, "failed" => 0 }, [ [ 0, classification_answer("配送", "未着のため"), nil ] ])

        result = ClassifyTickets.resume("batch_1")

        assert_equal "expired", result["raw_status"]
        assert_equal [ [ "succeeded", "配送" ], [ "failed", nil ], [ "failed", nil ] ], result["tickets"].map { |ticket| ticket.values_at("status", "category") }
      end
    end

    test "collects what a cancelled batch finished, and marks the rest cancelled" do
      with_openai_batches do |openai|
        perform(TICKETS.first(2).join("\n\n"))
        end_batch(openai, "cancelled", { "total" => 2, "completed" => 1, "failed" => 0 }, [ [ 0, classification_answer("配送", "未着のため"), nil ] ])

        result = ClassifyTickets.resume("batch_1")

        assert_equal [ [ "succeeded", "配送" ], [ "cancelled", nil ] ], result["tickets"].map { |ticket| ticket.values_at("status", "category") }
      end
    end

    test "lets a failed collection raise" do
      with_openai_batches do |openai|
        perform(TICKETS.first(2).join("\n\n"))
        end_batch(openai, "completed", { "total" => 2, "completed" => 2, "failed" => 0 }, [])
        openai.errors[:collect] = RubyLLM::ServerError.new("The server had an error")

        assert_raises(RubyLLM::ServerError) { ClassifyTickets.resume("batch_1") }
      end
    end

    private

    def perform(tickets)
      ClassifyTickets.perform(tickets: tickets, model: "gpt-5-nano")
    end

    # OpenAI ends the batch, and the run's check finds it ended.
    def end_batch(openai, raw_status, request_counts, results)
      openai.raw_status = raw_status
      openai.request_counts = request_counts
      openai.results = results
      ClassifyTickets.check("batch_1")
    end

    def capture_events(pattern)
      events = []
      subscription = ActiveSupport::Notifications.subscribe(pattern) { |event| events << event }
      yield
      events
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end
end
