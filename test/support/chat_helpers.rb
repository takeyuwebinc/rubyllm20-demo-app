# Stand-ins for the RubyLLM entry points that build a chat, so that code
# building one reaches no provider. The chat handed out is each test's own:
# it answers as that test scripts it.
module ChatHelpers
  # A context as RubyLLM.context returns it, whose chats are the test's.
  # Keeps the configuration the code set up and the options each chat was
  # made with, such as the model.
  class ScriptedContext
    attr_reader :config, :chats

    def initialize(config, chat)
      @config = config
      @chat = chat
      @chats = []
    end

    def chat(**options)
      @chats << options
      @chat
    end
  end

  # A fallback attempt as a chat hands it to after_fallback. RubyLLM offers
  # no public way to build a RubyLLM::Fallback, so this reads the same.
  ScriptedFallback = Data.define(:from, :to, :error, :attempt, :response, :fallback_error) do
    def succeeded? = !response.nil? && fallback_error.nil?
  end

  # Puts a stand-in in place of RubyLLM.chat for the length of a block. The
  # options each call was made with are yielded as they are made.
  def with_chat(chat)
    original = RubyLLM.method(:chat)
    calls = []
    RubyLLM.define_singleton_method(:chat) do |**options|
      calls << options
      chat
    end
    yield calls
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end

  # Puts a stand-in in place of RubyLLM.context for the length of a block.
  # The code's configuration block runs as it would, on a copy of the real
  # configuration. Each context made is yielded as it is made, a
  # ScriptedContext that hands out +chat+.
  def with_context(chat)
    original = RubyLLM.method(:context)
    contexts = []
    RubyLLM.define_singleton_method(:context) do |&configure|
      ScriptedContext.new(original.call(&configure).config, chat).tap { |context| contexts << context }
    end
    yield contexts
  ensure
    RubyLLM.define_singleton_method(:context, original)
  end
end
