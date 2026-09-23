# When a worker dies, Solid Queue marks the jobs it had claimed as failed and
# does not run them again, since the job itself may be what killed the worker.
# A demo run whose job was lost that way would stay running forever, so the
# run is handed over here, and decides for itself: it fails with the reason
# shown to the reader, or, when it has work under way at a provider, queues
# its job again.
#
# The event fires in whichever Solid Queue process notices the dead one, so it
# is subscribed in an initializer that every process loads. The block looks
# the job class up on each call to stay correct across code reloads.
ActiveSupport::Notifications.subscribe("fail_many_claimed.solid_queue") do |event|
  # Handled rather than raised: an error here would interrupt Solid Queue's
  # own cleanup.
  Rails.error.handle(context: { solid_queue_job_ids: event.payload[:job_ids] }) do
    Demos::RunJob.fail_abandoned(event.payload[:job_ids], event.payload[:error])
  end
end
