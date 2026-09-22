# An operation that calls something outside this app, one class per
# operation, run with .perform.
#
# A demo scenario's action returns its result and lets errors propagate. The
# job that runs it records the error as it was raised, since the kind of error
# is what tells the reader where the cause lies.
class ApplicationAction
  def self.perform(...)
    new(...).perform
  end
end
