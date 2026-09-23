# Puts a stand-in in place of RubyLLM.chat for the length of a block, so
# that code building a chat reaches no provider. The stand-in is each test's
# own: it answers as that test scripts it. The options each call was made
# with, such as the model, are yielded as they are made.
module ChatHelpers
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
end
