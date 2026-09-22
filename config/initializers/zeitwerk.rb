# RubyLLM registers "RubyLLM" as an acronym, but that only matches the single
# word "rubyllm". A file named ruby_llm_* would otherwise map to RubyLlm*.
# Registering "LLM" globally would also change how RubyLLM's own generators
# derive names, so the override is limited to the files that need it.
Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect("ruby_llm_span_subscriber" => "RubyLLMSpanSubscriber")
end
