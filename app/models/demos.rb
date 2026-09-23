module Demos
  def self.table_name_prefix
    "demo_"
  end

  # RubyLLM displays a provider by its class name, which spells xAI as XAI.
  # These are the names the providers go by.
  PROVIDER_NAMES = { "xai" => "xAI" }.freeze

  # The provider's own name, else its name as RubyLLM displays it, or the
  # slug when RubyLLM has no provider by that name.
  def self.provider_name(slug)
    PROVIDER_NAMES[slug.to_s] || RubyLLM::Provider.providers[slug.to_sym]&.display_name || slug.to_s
  end
end
