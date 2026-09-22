# Helpers that pin the settings a screen depends on, so that screen tests do
# not depend on the developer's .env.
module ScreenHelpers
  def with_openai_key(value)
    original = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = value
    yield
  ensure
    RubyLLM.config.openai_api_key = original
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| ENV[key] = value }
  end

  def create_run(scenario_key: "answer_inquiry", **attributes)
    Demos::Run.create!(scenario_key: scenario_key, input: { "inquiry" => "Where is my order?" }, **attributes)
  end
end
