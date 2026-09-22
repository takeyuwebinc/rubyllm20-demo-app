# Keys come from .env (see docs/api-keys.md). RubyLLM only raises
# RubyLLM::ConfigurationError when an unconfigured provider is actually used,
# so a demo whose key is missing fails on its own page without affecting others.
RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"].presence
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"].presence
  config.xai_api_key = ENV["XAI_API_KEY"].presence

  config.vertexai_project_id = ENV["GOOGLE_CLOUD_PROJECT"].presence
  config.vertexai_location = ENV["GOOGLE_CLOUD_LOCATION"].presence
end
