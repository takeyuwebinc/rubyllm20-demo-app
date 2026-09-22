require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Rubyllm20DemoApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Run times are shown in the local time of the one person using this app.
    config.time_zone = "Tokyo"
    # Generated speech is played back in the run page's audio element, which
    # plays only a file served inline. Active Storage serves any other type
    # as a download.
    config.active_storage.content_types_allowed_inline += %w[audio/mpeg]
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
