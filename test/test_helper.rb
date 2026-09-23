ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/screen_helpers"
require_relative "support/chat_helpers"
require_relative "support/research_helpers"
require_relative "support/document_order_assertions"

# Tests never call a provider. A fake key makes the chats they build
# independent of the developer's .env, and fails any call that slips through.
RubyLLM.config.openai_api_key = "sk-test"

# RubyLLM reads its model registry once per process, from the
# ruby_llm_models table, and falls back to the registry bundled with the gem
# while the table is empty. Some tests create a single model record; a
# registry first read inside one of them would know no other model. It is
# read here, before any test, and the parallel workers inherit it.
RubyLLM.models

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
  include DocumentOrderAssertions
end
