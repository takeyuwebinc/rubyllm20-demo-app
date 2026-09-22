require "test_helper"

module Demos
  class DemoTest < ActiveSupport::TestCase
    Availability = Scenario::Availability

    test "is runnable when any of its scenarios is runnable" do
      availability = demo_with(Availability.new(:missing_config, %w[xai]), Availability.new(:runnable, [])).availability

      assert_equal :runnable, availability.state
    end

    test "lacks settings when none is runnable and one lacks settings" do
      availability = demo_with(Availability.new(:missing_config, %w[xai]), Availability.new(:preparing, [])).availability

      assert_equal :missing_config, availability.state
      assert_equal %w[xai], availability.missing_providers
    end

    test "names each missing provider once" do
      availability = demo_with(Availability.new(:missing_config, %w[openai]), Availability.new(:missing_config, %w[openai xai])).availability

      assert_equal %w[openai xai], availability.missing_providers
    end

    test "is being prepared when every scenario is" do
      assert_equal :preparing, demo_with(Availability.new(:preparing, [])).availability.state
    end

    test "is described only when it has an explanation" do
      assert_predicate demo_with(useful_cases: "Useful", without_it: "Painful"), :described?
      refute_predicate demo_with(useful_cases: nil, without_it: nil), :described?
    end

    private

    StubScenario = Struct.new(:availability)

    def demo_with(*availabilities, **overrides)
      Demo.new(
        key: "demo",
        name: "Demo",
        official_name: nil,
        summary: "Summary",
        useful_cases: nil,
        without_it: nil,
        sources: [],
        scenarios: availabilities.map { |availability| StubScenario.new(availability) },
        **overrides
      )
    end
  end
end
