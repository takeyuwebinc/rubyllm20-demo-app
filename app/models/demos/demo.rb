module Demos
  # One of the ten RubyLLM 2.0 features: when it helps, what goes wrong
  # without it, the documentation the explanation rests on, and the
  # scenarios that run it.
  class Demo < Data.define(
    :key, :name, :official_name, :summary, :useful_cases, :without_it, :sources, :scenarios
  )
    Source = Data.define(:title, :url)

    def described?
      useful_cases.present?
    end

    # As runnable as its most runnable scenario, so that one missing key does
    # not hide a scenario that works.
    def availability
      availabilities = scenarios.map(&:availability)
      missing = availabilities.select(&:missing_config?)

      if availabilities.any?(&:runnable?)
        Scenario::Availability.new(:runnable, [])
      elsif missing.any?
        Scenario::Availability.new(:missing_config, missing.flat_map(&:missing_providers).uniq)
      else
        Scenario::Availability.new(:preparing, [])
      end
    end
  end
end
