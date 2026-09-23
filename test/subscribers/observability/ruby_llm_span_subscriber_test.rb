require "test_helper"

module Observability
  class RubyLLMSpanSubscriberTest < ActiveSupport::TestCase
    FakeMessage = Struct.new(:role, :content, :tool_calls, :tool_call_id, :thinking, :finish_reason, :model, keyword_init: true)
    FakeToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)
    FakeThinking = Struct.new(:text, keyword_init: true)

    setup do
      @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      @provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      @provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter))
      subscriber = RubyLLMSpanSubscriber.new(tracer: @provider.tracer("test"), capture_content: true)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, subscriber)
    end

    teardown do
      ActiveSupport::Notifications.unsubscribe(@subscription)
      @provider.shutdown
    end

    test "nests chat and request spans under the workflow as one agent run" do
      instrument("workflow.ruby_llm", workflow_name: "Summarize ticket", workflow_id: "run-1") do
        instrument("workflow_step.ruby_llm", workflow_step_name: "Classify") do
          instrument("chat.ruby_llm", chat_payload) do |payload|
            instrument("request.ruby_llm", provider: "openai", method: :post, url: "responses") { |p| p[:status] = 200 }
            complete(payload)
          end
        end
      end

      workflow, step, chat, request = spans_named("invoke_agent Summarize ticket", "Classify", "chat gpt-5-nano", "POST responses")

      assert_equal "gen_ai.invoke_agent", workflow.attributes["sentry.op"]
      assert_equal "Summarize ticket", workflow.attributes["gen_ai.agent.name"]
      assert_equal workflow.span_id, step.parent_span_id
      assert_equal step.span_id, chat.parent_span_id
      assert_equal chat.span_id, request.parent_span_id
      assert_equal [ workflow.trace_id ], [ step, chat, request ].map(&:trace_id).uniq
    end

    test "describes the chat call with GenAI attributes" do
      instrument("chat.ruby_llm", chat_payload(temperature: 0.2, max_output_tokens: 300)) { |payload| complete(payload) }

      attributes = span("chat gpt-5-nano").attributes

      assert_equal "gen_ai.chat", attributes["sentry.op"]
      assert_equal "chat", attributes["gen_ai.operation.name"]
      assert_equal "openai", attributes["gen_ai.provider.name"]
      assert_equal "gpt-5-nano", attributes["gen_ai.request.model"]
      assert_equal "gpt-5-nano-2025-08-07", attributes["gen_ai.response.model"]
      assert_in_delta 0.2, attributes["gen_ai.request.temperature"]
      assert_equal 300, attributes["gen_ai.request.max_tokens"]
      assert_equal '["stop"]', attributes["gen_ai.response.finish_reasons"]
    end

    test "reports input tokens as a total that includes cache reads and writes" do
      tokens = RubyLLM::Tokens.new(input: 100, output: 50, cache_read: 900, cache_write: 20, thinking: 30)

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, tokens: tokens) }

      attributes = span("chat gpt-5-nano").attributes

      assert_equal 1020, attributes["gen_ai.usage.input_tokens"]
      assert_equal 900, attributes["gen_ai.usage.cache_read.input_tokens"]
      assert_equal 20, attributes["gen_ai.usage.cache_creation.input_tokens"]
      assert_equal 50, attributes["gen_ai.usage.output_tokens"]
      assert_equal 30, attributes["gen_ai.usage.reasoning.output_tokens"]
      assert_equal 1070, attributes["gen_ai.usage.total_tokens"]
    end

    test "omits a reasoning count that exceeds the output total" do
      tokens = RubyLLM::Tokens.new(input: 10, output: 5, thinking: 40)

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, tokens: tokens) }

      assert_not_includes span("chat gpt-5-nano").attributes.keys, "gen_ai.usage.reasoning.output_tokens"
    end

    test "sends the cost RubyLLM calculated, and nothing when it is unknown" do
      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, cost: 0.00042) }
      instrument("chat.ruby_llm", chat_payload(model: "unpriced")) { |payload| complete(payload, cost: nil) }

      assert_in_delta 0.00042, span("chat gpt-5-nano").attributes["gen_ai.cost.total_tokens"]
      assert_not_includes span("chat unpriced").attributes.keys, "gen_ai.cost.total_tokens"
    end

    test "captures the conversation as role and parts messages" do
      history = [
        FakeMessage.new(role: :system, content: "You are a support agent."),
        FakeMessage.new(role: :user, content: "Where is my order?"),
        FakeMessage.new(role: :assistant, content: nil, tool_calls: { "call_1" => FakeToolCall.new(id: "call_1", name: "find_order", arguments: { "id" => 42 }) }),
        FakeMessage.new(role: :tool, content: "shipped", tool_call_id: "call_1")
      ]
      answer = FakeMessage.new(role: :assistant, content: "It shipped.", thinking: FakeThinking.new(text: "Look up the order."), finish_reason: :stop, model: "gpt-5-nano")

      instrument("chat.ruby_llm", chat_payload(input_messages: history)) { |payload| complete(payload, response: answer) }

      attributes = span("chat gpt-5-nano").attributes
      input = JSON.parse(attributes["gen_ai.input.messages"])
      output = JSON.parse(attributes["gen_ai.output.messages"])

      assert_equal "You are a support agent.", attributes["gen_ai.system_instructions"]
      assert_equal %w[user assistant tool], input.map { |message| message["role"] }
      assert_equal({ "type" => "tool_call", "id" => "call_1", "name" => "find_order", "arguments" => { "id" => 42 } }, input[1]["parts"].first)
      assert_equal({ "type" => "tool_call_response", "id" => "call_1", "result" => "shipped" }, input[2]["parts"].first)
      assert_equal [ { "type" => "reasoning", "content" => "Look up the order." }, { "type" => "text", "content" => "It shipped." } ], output.first["parts"]
    end

    test "captures the steps the provider ran as tool calls after the model's own, and leaves citations out" do
      answer = RubyLLM::Message.new(
        role: :assistant, content: "Ruby 3.5 is the latest.", model: "gpt-5-nano",
        tool_calls: { "call_1" => RubyLLM::ToolCall.new(id: "call_1", name: "find_order", arguments: { "id" => 42 }) },
        server_tool_calls: [
          RubyLLM::ServerToolCall.new(type: "web_search_call", id: "ws_1", input: { "type" => "search", "queries" => [ "latest ruby" ] }, raw: {}),
          RubyLLM::ServerToolCall.new(type: "server_tool_use", name: "web_search", id: "srvtoolu_1", input: { "query" => "ruby" }, raw: {}),
          RubyLLM::ServerToolCall.new(type: "web_search_call", id: "ws_2", raw: {})
        ],
        citations: [ { url: "https://www.ruby-lang.org/", title: "Ruby", text: "Ruby 3.5" } ]
      )

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, response: answer) }

      output = JSON.parse(span("chat gpt-5-nano").attributes["gen_ai.output.messages"])
      assert_equal [
        { "type" => "text", "content" => "Ruby 3.5 is the latest." },
        { "type" => "tool_call", "id" => "call_1", "name" => "find_order", "arguments" => { "id" => 42 } },
        { "type" => "tool_call", "id" => "ws_1", "name" => "web_search_call", "arguments" => { "type" => "search", "queries" => [ "latest ruby" ] } },
        { "type" => "tool_call", "id" => "srvtoolu_1", "name" => "web_search", "arguments" => { "query" => "ruby" } },
        { "type" => "tool_call", "id" => "ws_2", "name" => "web_search_call", "arguments" => {} }
      ], output.sole["parts"]
    end

    test "captures a response that holds only the provider's steps and no text" do
      answer = RubyLLM::Message.new(
        role: :assistant, content: "", model: "gpt-5-nano",
        server_tool_calls: [ { type: "web_search_call", id: "ws_1", input: { type: "open_page", url: "https://www.ruby-lang.org/" } } ]
      )

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, response: answer) }

      output = JSON.parse(span("chat gpt-5-nano").attributes["gen_ai.output.messages"])
      assert_equal [ { "role" => "assistant", "parts" => [
        { "type" => "tool_call", "id" => "ws_1", "name" => "web_search_call", "arguments" => { "type" => "open_page", "url" => "https://www.ruby-lang.org/" } }
      ] } ], output
    end

    test "captures a response without provider steps as before, whether it has none or cannot have any" do
      [
        RubyLLM::Message.new(role: :assistant, content: "pong", model: "gpt-5-nano", server_tool_calls: []),
        FakeMessage.new(role: :assistant, content: "pong", finish_reason: :stop, model: "gpt-5-nano")
      ].each do |answer|
        @exporter.reset
        instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload, response: answer) }

        output = JSON.parse(span("chat gpt-5-nano").attributes["gen_ai.output.messages"])
        assert_equal [ { "role" => "assistant", "parts" => [ { "type" => "text", "content" => "pong" } ] } ], output, answer.class.name
      end
    end

    test "leaves prompts and responses out when content capture is off" do
      ActiveSupport::Notifications.unsubscribe(@subscription)
      subscriber = RubyLLMSpanSubscriber.new(tracer: @provider.tracer("test"), capture_content: false)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, subscriber)

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload) }

      keys = span("chat gpt-5-nano").attributes.keys
      assert_empty keys.grep(/messages|system_instructions/)
      assert_includes keys, "gen_ai.usage.input_tokens"
    end

    test "groups spans into a conversation from workflow metadata" do
      metadata = { conversation_id: "chat/42 (draft)" }

      instrument("workflow.ruby_llm", workflow_name: "Reply", workflow_id: "run-2", workflow_metadata: metadata) do
        instrument("chat.ruby_llm", chat_payload(workflow_name: "Reply", workflow_metadata: metadata)) { |payload| complete(payload) }
      end

      workflow, chat = spans_named("invoke_agent Reply", "chat gpt-5-nano")

      assert_equal "chat_42__draft_", workflow.attributes["gen_ai.conversation.id"]
      assert_equal "chat_42__draft_", chat.attributes["gen_ai.conversation.id"]
      assert_equal "Reply", chat.attributes["gen_ai.agent.name"]
    end

    # RubyLLM gives an inner workflow's events only the inner workflow's own
    # metadata, so ordinary code that opens a workflow inside a run's
    # workflow would otherwise fall out of the run's conversation.
    test "carries the conversation of an outer workflow into an inner workflow without metadata" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer", workflow_metadata: { conversation_id: "run-1" }) do
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_parent_id: "outer") do
          instrument("workflow_step.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_step_name: "Classify") do
            instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket", workflow_id: "inner")) { |payload| complete(payload) }
          end
        end
      end

      inner, step, chat = spans_named("invoke_agent Answer ticket", "Classify", "chat gpt-5-nano")

      assert_equal %w[run-1 run-1 run-1], [ inner, step, chat ].map { |span| span.attributes["gen_ai.conversation.id"] }
      assert_equal "Answer ticket", chat.attributes["gen_ai.agent.name"]
    end

    test "keeps the conversation an inner workflow names for itself" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer", workflow_metadata: { conversation_id: "run-1" }) do
        inner_metadata = { conversation_id: "ticket-7" }
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_metadata: inner_metadata) do
          instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket", workflow_metadata: inner_metadata)) { |payload| complete(payload) }
        end
      end

      outer, inner, chat = spans_named("invoke_agent Run", "invoke_agent Answer ticket", "chat gpt-5-nano")

      assert_equal "run-1", outer.attributes["gen_ai.conversation.id"]
      assert_equal "ticket-7", inner.attributes["gen_ai.conversation.id"]
      assert_equal "ticket-7", chat.attributes["gen_ai.conversation.id"]
    end

    test "leaves the conversation out when no enclosing workflow names one" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer") do
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_parent_id: "outer") do
          instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket")) { |payload| complete(payload) }
        end
      end

      spans = spans_named("invoke_agent Run", "invoke_agent Answer ticket", "chat gpt-5-nano")

      spans.each { |span| assert_not_includes span.attributes.keys, "gen_ai.conversation.id", span.name }
    end

    test "carries the conversation through several levels of nesting" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "a", workflow_metadata: { conversation_id: "run-1" }) do
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "b", workflow_parent_id: "a") do
          instrument("workflow.ruby_llm", workflow_name: "Review", workflow_id: "c", workflow_parent_id: "b") do
            instrument("chat.ruby_llm", chat_payload(workflow_name: "Review")) { |payload| complete(payload) }
          end
        end
      end

      innermost, chat = spans_named("invoke_agent Review", "chat gpt-5-nano")

      assert_equal "run-1", innermost.attributes["gen_ai.conversation.id"]
      assert_equal "run-1", chat.attributes["gen_ai.conversation.id"]
    end

    test "takes the conversation of the innermost enclosing workflow that names one" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "a", workflow_metadata: { conversation_id: "run-1" }) do
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "b", workflow_metadata: { conversation_id: "ticket-7" }) do
          instrument("workflow.ruby_llm", workflow_name: "Review", workflow_id: "c", workflow_parent_id: "b") do
            instrument("chat.ruby_llm", chat_payload(workflow_name: "Review")) { |payload| complete(payload) }
          end
        end
      end

      innermost, chat = spans_named("invoke_agent Review", "chat gpt-5-nano")

      assert_equal "ticket-7", innermost.attributes["gen_ai.conversation.id"]
      assert_equal "ticket-7", chat.attributes["gen_ai.conversation.id"]
    end

    test "carries the conversation into an inner workflow whose metadata names none" do
      inner_metadata = { user_id: 1 }

      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer", workflow_metadata: { conversation_id: "run-1" }) do
        instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_metadata: inner_metadata) do
          instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket", workflow_metadata: inner_metadata)) { |payload| complete(payload) }
        end
      end

      inner, chat = spans_named("invoke_agent Answer ticket", "chat gpt-5-nano")

      assert_equal "run-1", inner.attributes["gen_ai.conversation.id"]
      assert_equal "run-1", chat.attributes["gen_ai.conversation.id"]
    end

    test "keeps a workflow's conversation for inner spans when its own span cannot be opened" do
      tracer = @provider.tracer("test")
      flaky = Object.new
      flaky.define_singleton_method(:start_span) do |name, **options|
        raise "tracer exploded" if name == "invoke_agent Run"

        tracer.start_span(name, **options)
      end
      ActiveSupport::Notifications.unsubscribe(@subscription)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, RubyLLMSpanSubscriber.new(tracer: flaky, capture_content: true))

      assert_error_reported(RuntimeError) do
        instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer", workflow_metadata: { conversation_id: "run-1" }) do
          instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "inner", workflow_parent_id: "outer") do
            instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket")) { |payload| complete(payload) }
          end
        end
      end

      inner, chat = spans_named("invoke_agent Answer ticket", "chat gpt-5-nano")

      assert_not_includes @exporter.finished_spans.map(&:name), "invoke_agent Run"
      assert_equal "run-1", inner.attributes["gen_ai.conversation.id"]
      assert_equal "run-1", chat.attributes["gen_ai.conversation.id"]
    end

    # RubyLLM passes metadata through without checking its type.
    test "treats metadata that is not a hash as naming no conversation, and keeps the other attributes" do
      assert_no_error_reported do
        instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "outer", workflow_metadata: "run-1") do
          instrument("chat.ruby_llm", chat_payload(workflow_name: "Run", workflow_metadata: "run-1")) { |payload| complete(payload) }
        end
      end

      workflow, chat = spans_named("invoke_agent Run", "chat gpt-5-nano")

      assert_not_includes workflow.attributes.keys, "gen_ai.conversation.id"
      assert_not_includes chat.attributes.keys, "gen_ai.conversation.id"
      assert_equal "gen_ai.invoke_agent", workflow.attributes["sentry.op"]
      assert_equal "Run", chat.attributes["gen_ai.agent.name"]
    end

    test "does not carry the conversation of a workflow that has already finished" do
      instrument("workflow.ruby_llm", workflow_name: "Run", workflow_id: "first", workflow_metadata: { conversation_id: "run-1" }) { :done }
      instrument("workflow.ruby_llm", workflow_name: "Answer ticket", workflow_id: "second") do
        instrument("chat.ruby_llm", chat_payload(workflow_name: "Answer ticket")) { |payload| complete(payload) }
      end

      later, chat = spans_named("invoke_agent Answer ticket", "chat gpt-5-nano")

      assert_not_includes later.attributes.keys, "gen_ai.conversation.id"
      assert_not_includes chat.attributes.keys, "gen_ai.conversation.id"
    end

    test "records a tool execution with its arguments and result" do
      payload = { provider: "openai", model: "gpt-5-nano", tool_name: "issue_refund", tool_call_id: "call_9", tool_arguments: { "order_id" => 42 } }

      instrument("tool_call.ruby_llm", payload) { |event| event[:result_content] = "Refunded order 42" }

      attributes = span("execute_tool issue_refund").attributes

      assert_equal "gen_ai.execute_tool", attributes["sentry.op"]
      assert_equal "issue_refund", attributes["gen_ai.tool.name"]
      assert_equal '{"order_id":42}', attributes["gen_ai.tool.call.arguments"]
      assert_equal "Refunded order 42", attributes["gen_ai.tool.call.result"]
    end

    test "shows the destination of each provider request" do
      instrument("request.ruby_llm", provider: "openai", method: :post, url: "responses") { |payload| payload[:status] = 200 }

      request = span("POST responses")

      assert_equal :client, request.kind
      assert_equal "http.client", request.attributes["sentry.op"]
      assert_equal "openai", request.attributes["ruby_llm.request.provider"]
      assert_equal "responses", request.attributes["url.path"]
      assert_equal 200, request.attributes["http.response.status_code"]
    end

    test "records every physical attempt, including failed ones" do
      tokens = RubyLLM::Tokens.new(input: 12, output: 0)

      instrument("usage.ruby_llm", operation: :chat, provider: "openai", model: "gpt-5-nano", status: :failed, tokens: tokens, cost: FakeCost.new(nil))

      attributes = span("attempt chat gpt-5-nano").attributes

      assert_equal "failed", attributes["ruby_llm.attempt.status"]
      assert_equal 12, attributes["ruby_llm.attempt.input_tokens"]
      assert_empty attributes.keys.grep(/\Agen_ai\.usage/), "attempt spans must not be double counted with the chat span"
    end

    test "marks the span as failed and keeps the error as attributes" do
      assert_raises(RubyLLM::RateLimitError) do
        instrument("chat.ruby_llm", chat_payload) { raise RubyLLM::RateLimitError.new("slow down") }
      end

      chat = span("chat gpt-5-nano")

      assert_equal OpenTelemetry::Trace::Status::ERROR, chat.status.code
      assert_equal "RubyLLM::RateLimitError", chat.attributes["error.type"]
      assert_equal "slow down", chat.attributes["error.message"]
    end

    test "traces other model operations with their usage" do
      payload = { provider: "openai", model: "gpt-image-1", tokens: RubyLLM::Tokens.new(input: 9), cost: FakeCost.new(0.001) }

      instrument("image.ruby_llm", payload)

      attributes = span("generate_content gpt-image-1").attributes

      assert_equal "gen_ai.generate_content", attributes["sentry.op"]
      assert_equal "image", attributes["ruby_llm.operation"]
      assert_equal 9, attributes["gen_ai.usage.input_tokens"]
    end

    test "describes generated speech by its voice, format, and size, with the text read aloud as the input" do
      instrument("speech.ruby_llm", speech_payload) { |payload| complete_speech(payload) }

      attributes = span("generate_content gpt-4o-mini-tts").attributes

      assert_equal "gen_ai.generate_content", attributes["sentry.op"]
      assert_equal "generate_content", attributes["gen_ai.operation.name"]
      assert_equal "speech", attributes["ruby_llm.operation"]
      assert_equal "openai", attributes["gen_ai.provider.name"]
      assert_equal "gpt-4o-mini-tts", attributes["gen_ai.request.model"]
      assert_equal "marin", attributes["ruby_llm.speech.voice"]
      assert_equal "mp3", attributes["ruby_llm.speech.format"]
      assert_equal 48_000, attributes["ruby_llm.speech.audio_bytes"]
      assert_equal [ { "role" => "user", "parts" => [ { "type" => "text", "content" => "ご注文の商品は明日お届けします。" } ] } ],
        JSON.parse(attributes["gen_ai.input.messages"])
      assert_not_includes attributes.keys, "gen_ai.output.messages"
    end

    test "leaves the text read aloud out when content capture is off, and still describes the speech" do
      ActiveSupport::Notifications.unsubscribe(@subscription)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, RubyLLMSpanSubscriber.new(tracer: @provider.tracer("test"), capture_content: false))

      instrument("speech.ruby_llm", speech_payload) { |payload| complete_speech(payload) }

      attributes = span("generate_content gpt-4o-mini-tts").attributes

      assert_empty attributes.keys.grep(/messages/)
      assert_equal "marin", attributes["ruby_llm.speech.voice"]
      assert_equal "mp3", attributes["ruby_llm.speech.format"]
      assert_equal 48_000, attributes["ruby_llm.speech.audio_bytes"]
    end

    test "leaves the input out when the text read aloud is empty, and still describes the speech" do
      instrument("speech.ruby_llm", speech_payload.merge(input: "")) { |payload| complete_speech(payload) }

      attributes = span("generate_content gpt-4o-mini-tts").attributes

      assert_not_includes attributes.keys, "gen_ai.input.messages"
      assert_equal "marin", attributes["ruby_llm.speech.voice"]
      assert_equal "mp3", attributes["ruby_llm.speech.format"]
      assert_equal 48_000, attributes["ruby_llm.speech.audio_bytes"]
    end

    test "marks failed speech as failed, without an audio size" do
      assert_raises(RubyLLM::BadRequestError) do
        instrument("speech.ruby_llm", speech_payload) { raise RubyLLM::BadRequestError.new("Input of 2345 tokens is over the maximum input limit of 2000 tokens") }
      end

      speech = span("generate_content gpt-4o-mini-tts")

      assert_equal OpenTelemetry::Trace::Status::ERROR, speech.status.code
      assert_equal "RubyLLM::BadRequestError", speech.attributes["error.type"]
      assert_match(/maximum input limit of 2000 tokens/, speech.attributes["error.message"])
      assert_not_includes speech.attributes.keys, "ruby_llm.speech.audio_bytes"
      assert_equal "marin", speech.attributes["ruby_llm.speech.voice"], "the voice asked for"
      assert_equal "mp3", speech.attributes["ruby_llm.speech.format"], "the format asked for"
    end

    test "counts the tokens of a tokenized text, beside the attributes of other operations" do
      workflow = { workflow_name: "Demos::RunJob", workflow_id: "run-1", workflow_metadata: { conversation_id: "run-abc" } }

      instrument("workflow.ruby_llm", workflow) do
        instrument("tokenization.ruby_llm", tokenization_payload(**workflow)) { |payload| payload[:result] = tokenization(count: 58) }
      end

      attributes = span("tokenization grok-4.3").attributes

      assert_equal 58, attributes["ruby_llm.tokenization.count"]
      assert_equal "tokenization", attributes["ruby_llm.operation"]
      assert_equal "xai", attributes["gen_ai.provider.name"]
      assert_equal "grok-4.3", attributes["gen_ai.request.model"]
      assert_equal "Demos::RunJob", attributes["gen_ai.agent.name"]
      assert_equal "run-abc", attributes["gen_ai.conversation.id"]
      assert_not_includes attributes.keys, "sentry.op"
      assert_empty attributes.keys.grep(/\Agen_ai\.(usage|cost)\./)
    end

    test "marks a failed tokenization as failed, without a token count" do
      assert_raises(RubyLLM::BadRequestError) do
        instrument("tokenization.ruby_llm", tokenization_payload) { raise RubyLLM::BadRequestError.new("Bad data: Text cannot be empty") }
      end

      tokenization = span("tokenization grok-4.3")

      assert_equal OpenTelemetry::Trace::Status::ERROR, tokenization.status.code
      assert_equal "RubyLLM::BadRequestError", tokenization.attributes["error.type"]
      assert_equal "Bad data: Text cannot be empty", tokenization.attributes["error.message"]
      assert_not_includes tokenization.attributes.keys, "ruby_llm.tokenization.count"
      assert_equal "xai", tokenization.attributes["gen_ai.provider.name"]
    end

    test "leaves the token count out of a tokenization whose result has no count, and keeps the other attributes" do
      instrument("tokenization.ruby_llm", tokenization_payload) { |payload| payload[:result] = Object.new }

      attributes = span("tokenization grok-4.3").attributes

      assert_not_includes attributes.keys, "ruby_llm.tokenization.count"
      assert_equal "tokenization", attributes["ruby_llm.operation"]
      assert_equal "xai", attributes["gen_ai.provider.name"]
      assert_equal "grok-4.3", attributes["gen_ai.request.model"]
    end

    # A String has a count that takes an argument, so calling it fails.
    test "reports a result whose count fails, and keeps the other attributes of the tokenization" do
      assert_error_reported(ArgumentError) do
        instrument("tokenization.ruby_llm", tokenization_payload) { |payload| payload[:result] = "not a tokenization" }
      end

      attributes = span("tokenization grok-4.3").attributes

      assert_not_includes attributes.keys, "ruby_llm.tokenization.count"
      assert_equal "tokenization", attributes["ruby_llm.operation"]
      assert_equal "xai", attributes["gen_ai.provider.name"]
      assert_equal "grok-4.3", attributes["gen_ai.request.model"]
    end

    test "counts the tokens of a tokenized text when content capture is off" do
      ActiveSupport::Notifications.unsubscribe(@subscription)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, RubyLLMSpanSubscriber.new(tracer: @provider.tracer("test"), capture_content: false))

      instrument("tokenization.ruby_llm", tokenization_payload) { |payload| payload[:result] = tokenization(count: 3) }

      assert_equal 3, span("tokenization grok-4.3").attributes["ruby_llm.tokenization.count"]
    end

    test "ignores events that are not model work" do
      instrument("models.refresh.ruby_llm", remote_only: true)

      assert_empty @exporter.finished_spans
    end

    test "keeps its open spans apart from another subscriber's" do
      # Two subscribers attach and detach OpenTelemetry contexts in the same
      # order, which OpenTelemetry reports as mismatched. It still unwinds the
      # context correctly, and the app only ever registers one subscriber.
      original_logger, OpenTelemetry.logger = OpenTelemetry.logger, Logger.new(IO::NULL)
      other_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      other_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      other_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(other_exporter))
      other = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, RubyLLMSpanSubscriber.new(tracer: other_provider.tracer("other"), capture_content: false))

      instrument("chat.ruby_llm", chat_payload) { |payload| complete(payload) }

      assert_includes span("chat gpt-5-nano").attributes.keys, "gen_ai.input.messages"
      assert_not_includes other_exporter.finished_spans.sole.attributes.keys, "gen_ai.input.messages"
    ensure
      ActiveSupport::Notifications.unsubscribe(other)
      other_provider.shutdown
      OpenTelemetry.logger = original_logger
    end

    test "never lets an instrumentation failure break the model call" do
      broken = Object.new
      def broken.start_span(*, **) = raise("tracer exploded")
      ActiveSupport::Notifications.unsubscribe(@subscription)
      @subscription = ActiveSupport::Notifications.subscribe(/\.ruby_llm\z/, RubyLLMSpanSubscriber.new(tracer: broken, capture_content: true))

      result = instrument("chat.ruby_llm", chat_payload) { :answer }

      assert_equal :answer, result
    end

    private

    FakeCost = Struct.new(:total)

    def instrument(name, payload = {}, &block)
      ActiveSupport::Notifications.instrument(name, payload, &block)
    end

    def chat_payload(**overrides)
      {
        provider: "openai", model: "gpt-5-nano", streaming: false,
        input_messages: [ FakeMessage.new(role: :user, content: "ping") ]
      }.merge(overrides)
    end

    # What RubyLLM.speak instruments before the provider answers: the voice
    # and format asked for, and usage that stays empty for OpenAI.
    def speech_payload
      {
        provider: "openai", model: "gpt-4o-mini-tts", input: "ご注文の商品は明日お届けします。",
        voice: "marin", format: "mp3", provider_options: { instructions: "落ち着いた口調で" }, streaming: false,
        tokens: RubyLLM::Tokens.new, cost: FakeCost.new(nil)
      }
    end

    def complete_speech(payload)
      payload.merge!(response_model: "gpt-4o-mini-tts", voice: "marin", format: "mp3", audio_bytes: 48_000)
    end

    # What RubyLLM.tokenize instruments before the provider answers: the
    # model and the provider, without the text.
    def tokenization_payload(**overrides)
      { model: "grok-4.3", provider: :xai }.merge(overrides)
    end

    def tokenization(count:)
      RubyLLM::Tokenization.new(ids: Array.new(count) { |index| 1000 + index }, model: "grok-4.3")
    end

    def complete(payload, tokens: RubyLLM::Tokens.new(input: 13, output: 75), cost: 0.00003, response: nil)
      payload[:response] = response || FakeMessage.new(role: :assistant, content: "pong", finish_reason: :stop, model: "gpt-5-nano")
      payload[:response_model] = "gpt-5-nano-2025-08-07"
      payload[:tokens] = tokens
      payload[:cost] = FakeCost.new(cost)
    end

    def span(name)
      @exporter.finished_spans.find { |finished| finished.name == name } || flunk("no span named #{name.inspect}; got #{@exporter.finished_spans.map(&:name).inspect}")
    end

    def spans_named(*names) = names.map { |name| span(name) }
  end
end
