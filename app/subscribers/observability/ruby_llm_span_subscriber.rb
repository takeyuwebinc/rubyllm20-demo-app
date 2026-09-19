module Observability
  # Turns RubyLLM's instrumentation events into OpenTelemetry spans that follow
  # the GenAI semantic conventions, so any OTLP backend can show an agent run.
  #
  # It subscribes to the public events instead of patching RubyLLM: the payload
  # is a documented contract, while RubyLLM's internal methods are not.
  #
  # Subscribe an instance to /\.ruby_llm\z/. ActiveSupport::Notifications calls
  # #start and #finish around each instrumented block, which is what lets a
  # span stay open while nested events (a request inside a chat) become its
  # children.
  class RubyLLMSpanSubscriber
    # GenAI operation per event. Sentry only recognises this fixed set of
    # operation names, so media generation is reported as generate_content.
    GEN_AI_OPERATIONS = {
      "chat.ruby_llm" => "chat",
      "embedding.ruby_llm" => "embeddings",
      "image.ruby_llm" => "generate_content",
      "speech.ruby_llm" => "generate_content",
      "video.ruby_llm" => "generate_content"
    }.freeze

    # Model work that has no GenAI operation of its own. Traced as plain spans.
    OTHER_OPERATIONS = %w[
      batch compaction moderation ocr rerank research_job tokenization transcription video_job
    ].to_h { |operation| [ "#{operation}.ruby_llm", operation ] }.freeze

    Entry = Struct.new(:span, :token)

    def initialize(tracer:, capture_content:)
      @tracer = tracer
      @capture_content = capture_content
      @stack_key = :"observability_ruby_llm_spans_#{object_id}"
    end

    def start(name, _id, payload)
      stack.push(open_entry(name, payload))
    end

    def finish(name, _id, payload)
      entry = stack.pop
      return unless entry&.span

      close_entry(entry, name, payload)
    end

    private

    # Thread#[] is fiber-local, which matches how OpenTelemetry stores its own
    # context. Tool calls that RubyLLM runs on other threads start a new trace,
    # because neither this stack nor the OpenTelemetry context crosses threads.
    #
    # The stack belongs to this instance. Every subscriber is called in the
    # same order for start and for finish, so a shared stack would hand one
    # subscriber the span another one opened.
    def stack
      Thread.current[@stack_key] ||= []
    end

    def open_entry(name, payload)
      span_name = span_name_for(name, payload)
      return Entry.new unless span_name

      span = @tracer.start_span(span_name, kind: name == "request.ruby_llm" ? :client : :internal)
      Entry.new(span, OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span)))
    rescue StandardError => error
      report(error)
      Entry.new
    end

    def close_entry(entry, name, payload)
      entry.span.add_attributes(attributes_for(name, payload).compact)
      record_failure(entry.span, payload[:exception_object])
    rescue StandardError => error
      report(error)
    ensure
      entry.span.finish
      OpenTelemetry::Context.detach(entry.token)
    end

    # A tracing bug must not fail, or double bill, the model call it observes.
    def report(error)
      Rails.error.report(error, handled: true, source: "observability.ruby_llm")
    end

    def span_name_for(name, payload)
      case name
      when "workflow.ruby_llm" then "invoke_agent #{payload[:workflow_name]}"
      when "workflow_step.ruby_llm" then payload[:workflow_step_name].to_s
      when "tool_call.ruby_llm" then "execute_tool #{payload[:tool_name]}"
      when "request.ruby_llm" then "#{payload[:method].to_s.upcase} #{payload[:url]}"
      when "usage.ruby_llm" then "attempt #{payload[:operation]} #{payload[:model]}".strip
      else
        operation = GEN_AI_OPERATIONS[name] || OTHER_OPERATIONS[name]
        "#{operation} #{payload[:model]}".strip if operation
      end
    end

    def attributes_for(name, payload)
      attributes =
        case name
        when "workflow.ruby_llm" then workflow_attributes(payload)
        when "workflow_step.ruby_llm" then { "ruby_llm.workflow.step.id" => payload[:workflow_step_id]&.to_s }
        when "tool_call.ruby_llm" then tool_attributes(payload)
        when "request.ruby_llm" then request_attributes(payload)
        when "usage.ruby_llm" then attempt_attributes(payload)
        else operation_attributes(name, payload)
        end

      attributes.merge(correlation_attributes(name, payload))
    end

    def workflow_attributes(payload)
      {
        "sentry.op" => "gen_ai.invoke_agent",
        "gen_ai.operation.name" => "invoke_agent",
        "ruby_llm.workflow.id" => payload[:workflow_id]&.to_s
      }
    end

    def operation_attributes(name, payload)
      gen_ai_operation = GEN_AI_OPERATIONS[name]
      attributes = {
        "ruby_llm.operation" => name.delete_suffix(".ruby_llm"),
        "gen_ai.provider.name" => payload[:provider]&.to_s,
        "gen_ai.request.model" => payload[:model]&.to_s
      }
      if gen_ai_operation
        attributes["sentry.op"] = "gen_ai.#{gen_ai_operation}"
        attributes["gen_ai.operation.name"] = gen_ai_operation
      end
      attributes.merge!(usage_attributes(payload[:tokens], payload[:cost]))
      attributes.merge!(chat_attributes(payload)) if name == "chat.ruby_llm"
      attributes
    end

    def chat_attributes(payload)
      response = payload[:response]
      attributes = {
        "gen_ai.response.model" => (payload[:response_model] || payload[:model])&.to_s,
        "gen_ai.request.temperature" => payload[:temperature]&.to_f,
        "gen_ai.request.max_tokens" => payload[:max_output_tokens]&.to_i,
        "gen_ai.response.streaming" => payload[:streaming] ? true : nil
      }
      if response.respond_to?(:finish_reason) && response.finish_reason
        attributes["gen_ai.response.finish_reasons"] = [ response.finish_reason.to_s ].to_json
      end
      attributes.merge!(content_attributes(payload[:input_messages], response)) if @capture_content
      attributes
    end

    def content_attributes(input_messages, response)
      system_messages, conversation = Array(input_messages).partition { |message| message.role.to_s == "system" }
      {
        "gen_ai.system_instructions" => system_messages.filter_map { |message| message.content.presence }.join("\n\n").presence,
        "gen_ai.input.messages" => MessageFormatter.format(conversation).presence&.to_json,
        "gen_ai.output.messages" => MessageFormatter.format([ response ].compact).presence&.to_json
      }
    end

    # RubyLLM reports cache reads and writes beside `input`, and may include
    # thinking inside `output`. The GenAI conventions want totals with the
    # cached and reasoning counts as subsets; Sentry subtracts the subsets from
    # the totals, so a subset larger than its total yields a negative cost.
    def usage_attributes(tokens, cost)
      return {} unless tokens

      input_parts = [ tokens.input, tokens.cache_read, tokens.cache_write ].compact
      input_total = input_parts.sum if input_parts.any?
      reasoning = tokens.thinking if tokens.thinking && tokens.output && tokens.thinking <= tokens.output

      {
        "gen_ai.usage.input_tokens" => input_total,
        "gen_ai.usage.cache_read.input_tokens" => tokens.cache_read,
        "gen_ai.usage.cache_creation.input_tokens" => tokens.cache_write,
        "gen_ai.usage.output_tokens" => tokens.output,
        "gen_ai.usage.reasoning.output_tokens" => reasoning,
        "gen_ai.usage.total_tokens" => (input_total + tokens.output if input_total && tokens.output),
        # Sentry keeps a cost it is given instead of estimating one. Its own
        # estimate knows nothing about batch rates or unlisted models.
        "gen_ai.cost.total_tokens" => cost&.total&.to_f
      }
    end

    def tool_attributes(payload)
      attributes = {
        "sentry.op" => "gen_ai.execute_tool",
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => payload[:tool_name]&.to_s,
        "gen_ai.tool.type" => "function",
        "gen_ai.tool.call.id" => payload[:tool_call_id]&.to_s
      }
      if @capture_content
        attributes["gen_ai.tool.call.arguments"] = payload[:tool_arguments]&.to_json
        attributes["gen_ai.tool.call.result"] = payload[:result_content]&.to_s
      end
      attributes
    end

    # `url` is the path RubyLLM posts to, relative to the provider's API base.
    # It is what tells a Responses API call from a Chat Completions one.
    def request_attributes(payload)
      {
        "sentry.op" => "http.client",
        "ruby_llm.request.provider" => payload[:provider]&.to_s,
        "http.request.method" => payload[:method]&.to_s&.upcase,
        "url.path" => payload[:url]&.to_s,
        "http.response.status_code" => payload[:status]&.to_i
      }
    end

    # One finished physical attempt: retries, fallbacks, and cancelled calls
    # each produce one. Kept out of the gen_ai.usage namespace because the
    # enclosing operation span already carries the same tokens as its total.
    def attempt_attributes(payload)
      tokens = payload[:tokens]
      {
        "ruby_llm.attempt.operation" => payload[:operation]&.to_s,
        "ruby_llm.attempt.provider" => payload[:provider]&.to_s,
        "ruby_llm.attempt.model" => payload[:model]&.to_s,
        "ruby_llm.attempt.status" => payload[:status]&.to_s,
        "ruby_llm.attempt.input_tokens" => tokens&.input,
        "ruby_llm.attempt.output_tokens" => tokens&.output,
        "ruby_llm.attempt.cost" => payload[:cost]&.total&.to_f
      }
    end

    def correlation_attributes(name, payload)
      return {} if name == "request.ruby_llm"

      metadata = payload[:workflow_metadata] || {}
      conversation_id = metadata[:conversation_id] || metadata["conversation_id"]
      {
        "gen_ai.agent.name" => payload[:workflow_name]&.to_s,
        # Sentry uses the id as a URL path segment, so a slash would break the
        # Conversations view.
        "gen_ai.conversation.id" => conversation_id&.to_s&.gsub(/[^A-Za-z0-9_-]/, "_").presence
      }
    end

    # OTLP backends may drop span events (Sentry does), which is where
    # record_exception would put the details. Attributes survive.
    def record_failure(span, error)
      return unless error

      span.add_attributes("error.type" => error.class.name, "error.message" => error.message.to_s)
      span.status = OpenTelemetry::Trace::Status.error(error.message.to_s)
    end
  end
end
