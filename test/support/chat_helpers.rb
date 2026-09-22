# Puts a stand-in in place of RubyLLM.chat for the length of a block, so
# that code building a chat reaches no provider. The stand-in is each test's
# own: it answers as that test scripts it.
module ChatHelpers
  def with_chat(chat)
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**| chat }
    yield
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end
end
