module Demos
  # The demos and their scenarios, read from config/demos.yml. They are kept
  # in version control beside the handlers they name rather than in the
  # database, so a demo and the code it runs change together.
  module Catalog
    PATH = Rails.root.join("config/demos.yml")

    class << self
      def demos
        @demos ||= build(YAML.load_file(PATH))
      end

      # The demos from their attributes, as config/demos.yml holds them.
      def build(attributes)
        attributes.map { |demo| build_demo(demo) }.freeze
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
          documents: attributes.fetch("documents", []).map { |document| build_document(document) },
          handler_name: attributes["handler"],
          result_kind: attributes["result_kind"],
          retryable: attributes["retryable"]
        ).tap { |scenario| refuse_shared_names(scenario) }
      end

      def build_input(attributes)
        Scenario::Input.new(
          name: attributes.fetch("name"),
          label: attributes.fetch("label"),
          default: attributes.fetch("default", ""),
          required: attributes.fetch("required", false)
        )
      end

      def build_document(attributes)
        Scenario::Document.new(
          name: attributes.fetch("name"),
          label: attributes.fetch("label"),
          path: attributes.fetch("path")
        )
      end

      # The handler takes the inputs, the models, and the documents as the
      # keywords of one call, where a later value of a name wins. A shared
      # name would let what a person typed stand in for a model or for the
      # path of a file to send.
      def refuse_shared_names(scenario)
        names = scenario.inputs.map(&:name) + scenario.models.keys + scenario.documents.map(&:name)
        shared = names.tally.select { |_, count| count > 1 }.keys
        return if shared.empty?

        raise ArgumentError, "Scenario #{scenario.key} gives more than one of its inputs, models, and documents the name #{shared.join(", ")}"
      end
    end
  end
end
