# An operation that calls something outside this app, one class per
# operation, run with .perform.
#
# A demo scenario's action returns its result, a Hash the run keeps, and lets
# errors propagate. The job that runs it records the error as it was raised,
# since the kind of error is what tells the reader where the cause lies.
#
# A value of the result may be a file the action generated, such as the
# Speech that RubyLLM.speak returns, given as RubyLLM returned it: anything
# with to_blob and mime_type. The run keeps each as an attachment and
# records a reference to it (filename, content_type, byte_size) in its place,
# so the action needs to know nothing of the run or of Active Storage.
#
# An action that stops for a person's approval returns the persisted Chat
# that is awaiting it instead of a result. The chat itself, rather than a
# value of this app's, so that the action stays plain RubyLLM code that the
# demo can show as it is. Its class then also has
# .decide(chat, tool_call_id, approved:), which records the decision, and
# .resume(chat), which continues the chat and again returns a result or the
# chat if it stopped once more.
#
# An action that leaves work with the provider, such as a research job,
# returns that work as RubyLLM returned it: anything with id and pending?.
# It keeps no record of the ID itself, so that it stays plain RubyLLM code
# with nothing of the run in it.
# Its class then also has .resume(id), which waits for the work by its ID
# and returns the result. The job keeps the ID with the run as soon as the
# work is returned, and then calls .resume, so a job that runs again waits
# for the same work instead of starting another. When waiting fails in a
# way that may pass, the job tries .resume again later; .resume only lets
# the error propagate.
class ApplicationAction
  def self.perform(...)
    new(...).perform
  end
end
