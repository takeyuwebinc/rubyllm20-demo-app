module Demos
  # The demos and their scenarios, read from config/demos.yml. They are kept
  # in version control beside the handlers they name rather than in the
  # database, so a demo and the code it runs change together.
  module Catalog
    PATH = Rails.root.join("config/demos.yml")

    class << self
      def demos
        @demos ||= YAML.load_file(PATH).map { |attributes| build_demo(attributes) }.freeze
      end

      def demo(key)
        demos.find { |demo| demo.key == key }
      end

      def scenario(key)
        scenarios.find { |scenario| scenario.key == key }
      end

      def scenarios
        demos.flat_map(&:scenarios)
      end

      private

      def build_demo(attributes)
        Demo.new(
          key: attributes.fetch("key"),
          name: attributes.fetch("name"),
          official_name: attributes["official_name"],
          summary: attributes.fetch("summary"),
          useful_cases: attributes["useful_cases"],
          without_it: attributes["without_it"],
          sources: attributes.fetch("sources").map { |source| Demo::Source.new(title: source.fetch("title"), url: source.fetch("url")) },
          scenarios: attributes.fetch("scenarios").map { |scenario| build_scenario(scenario, demo_key: attributes.fetch("key")) }
        )
      end

      def build_scenario(attributes, demo_key:)
        Scenario.new(
          key: attributes.fetch("key"),
          demo_key: demo_key,
          name: attributes.fetch("name"),
          providers: attributes.fetch("providers", []),
          models: attributes.fetch("models", {}),
          inputs: attributes.fetch("inputs", []).map { |input| build_input(input) },
          handler_name: attributes["handler"],
          result_kind: attributes["result_kind"],
          retryable: attributes["retryable"]
        )
      end

      def build_input(attributes)
        Scenario::Input.new(
          name: attributes.fetch("name"),
          label: attributes.fetch("label"),
          default: attributes.fetch("default", ""),
          required: attributes.fetch("required", false)
        )
      end
    end
  end
end
