# An operation that calls something outside this app, one class per
# operation, run with .perform.
#
# A demo scenario's action returns its result, a Hash the run keeps, and lets
# errors propagate. The job that runs it records the error as it was raised,
# since the kind of error is what tells the reader where the cause lies.
#
# An action that stops for a person's approval returns the persisted Chat
# that is awaiting it instead of a result. Its class then also has
# .decide(chat, tool_call_id, approved:), which records the decision, and
# .resume(chat), which continues the chat and again returns a result or the
# chat if it stopped once more.
class ApplicationAction
  def self.perform(...)
    new(...).perform
  end
end
