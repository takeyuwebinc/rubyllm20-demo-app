ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/screen_helpers"

# Tests never call a provider. A fake key makes the chats they build
# independent of the developer's .env, and fails any call that slips through.
RubyLLM.config.openai_api_key = "sk-test"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  include ScreenHelpers
end
