require "test_helper"

module Demos
  class CatalogTest < ActiveSupport::TestCase
    test "lists the ten features in the order of the requirements" do
      assert_equal %w[
        responses-api citations tool-approval batches model-fallbacks
        video-and-speech provider-tools deep-research tokenization workflow-instrumentation
      ], Catalog.demos.map(&:key)
    end

    test "gives every demo a summary and at least one RubyLLM source" do
      Catalog.demos.each do |demo|
        assert_predicate demo.summary, :present?, demo.key
        assert demo.sources.any? { |source| source.url.start_with?("https://rubyllm.com/") }, demo.key
      end
    end

    test "has both explanations or neither" do
      Catalog.demos.each do |demo|
        assert_equal demo.useful_cases.present?, demo.without_it.present?, demo.key
      end
    end

    test "has two scenarios only for Video and Speech, Provider Tools, and Tokenization" do
      counts = Catalog.demos.to_h { |demo| [ demo.key, demo.scenarios.size ] }

      assert_equal %w[video-and-speech provider-tools tokenization], counts.select { |_, size| size == 2 }.keys
      assert counts.except("video-and-speech", "provider-tools", "tokenization").values.all?(1)
    end

    test "uses unique scenario keys" do
      keys = Catalog.demos.flat_map(&:scenarios).map(&:key)

      assert_equal keys.uniq, keys
    end

    test "looks up a demo and a scenario by key" do
      assert_equal "Responses API", Catalog.demo("responses-api").name
      assert_equal "responses-api", Catalog.scenario("answer_inquiry").demo.key
      assert_nil Catalog.demo("missing")
      assert_nil Catalog.scenario("missing")
    end
  end
end
