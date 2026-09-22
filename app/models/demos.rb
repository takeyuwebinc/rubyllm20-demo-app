module Demos
  def self.table_name_prefix
    "demo_"
  end

  # The provider's name as RubyLLM displays it, or the slug when RubyLLM has
  # no provider by that name.
  def self.provider_name(slug)
    RubyLLM::Provider.providers[slug.to_sym]&.display_name || slug.to_s
  end
end
