require "test_helper"

module Tokenization
  class TokenizeTextTest < ActiveSupport::TestCase
    test "tokenizes the text once, with the model, on xAI" do
      calls = []
      returned = tokenization([ [ 1001, "返品", [ 232, 191, 148, 229, 147, 129 ] ] ])

      with_tokenize(->(text, **options) { calls << [ text, options ]; returned }) do
        TokenizeText.perform(text: "返品", model: "grok-4.3")
      end

      text, options = calls.sole
      assert_equal "返品", text
      assert_equal({ model: "grok-4.3", provider: :xai }, options)
    end

    test "returns the count, the model, and each token's id, string, and bytes in text order" do
      returned = tokenization([ [ 5001, "返品", [ 232, 191, 148, 229, 147, 129 ] ], [ 5002, "でき", [ 227, 129, 167, 227, 129, 141 ] ], [ 5003, " OK", [ 32, 79, 75 ] ] ])

      result = with_tokenize(->(_text, **) { returned }) do
        TokenizeText.perform(text: "返品でき OK", model: "grok-4.3")
      end

      assert_equal %w[count model tokens], result.keys
      assert_equal 3, result["count"]
      assert_equal "grok-4.3", result["model"]
      assert_equal [
        { "id" => 5001, "string" => "返品", "bytes" => [ 232, 191, 148, 229, 147, 129 ] },
        { "id" => 5002, "string" => "でき", "bytes" => [ 227, 129, 167, 227, 129, 141 ] },
        { "id" => 5003, "string" => " OK", "bytes" => [ 32, 79, 75 ] }
      ], result["tokens"]
    end

    # The Tokenization here holds another model than the one asked for, and
    # more ids than tokens in raw, so that each value can only have come
    # from where the action should take it.
    test "takes the count and the model from the Tokenization, and the tokens from its raw answer" do
      raw = { "token_ids" => [ { "token_id" => 11, "string_token" => "返", "token_bytes" => [ 232, 191, 148 ] } ] }
      returned = RubyLLM::Tokenization.new(ids: [ 11, 12 ], model: "grok-4.3-resolved", raw: raw)

      result = with_tokenize(->(_text, **) { returned }) do
        TokenizeText.perform(text: "返品", model: "grok-4.3")
      end

      assert_equal 2, result["count"]
      assert_equal "grok-4.3-resolved", result["model"]
      assert_equal [ { "id" => 11, "string" => "返", "bytes" => [ 232, 191, 148 ] } ], result["tokens"]
    end

    # xAI splits a four-byte character such as 🙏 (f0 9f 99 8f) partway, and
    # gives each part an empty string.
    test "keeps the tokens that end partway through a character, with their empty strings and their bytes" do
      returned = tokenization([ [ 7001, "します", [ 227, 129, 151, 227, 129, 190, 227, 129, 153 ] ], [ 7002, "", [ 240, 159, 153 ] ], [ 7003, "", [ 143 ] ] ])

      result = with_tokenize(->(_text, **) { returned }) do
        TokenizeText.perform(text: "します🙏", model: "grok-4.3")
      end

      assert_equal 3, result["count"]
      assert_equal [
        { "id" => 7002, "string" => "", "bytes" => [ 240, 159, 153 ] },
        { "id" => 7003, "string" => "", "bytes" => [ 143 ] }
      ], result["tokens"].last(2)
      assert_equal "します🙏", result["tokens"].flat_map { |token| token["bytes"] }.pack("C*").force_encoding(Encoding::UTF_8)
    end

    test "returns a text of one token as a count of 1 and a list of one" do
      returned = tokenization([ [ 1, "   ", [ 32, 32, 32 ] ] ])

      result = with_tokenize(->(_text, **) { returned }) do
        TokenizeText.perform(text: "   ", model: "grok-4.3")
      end

      assert_equal 1, result["count"]
      assert_equal [ { "id" => 1, "string" => "   ", "bytes" => [ 32, 32, 32 ] } ], result["tokens"]
    end

    test "lets a failed tokenization propagate" do
      error = assert_raises(RubyLLM::BadRequestError) do
        with_tokenize(->(_text, **) { raise RubyLLM::BadRequestError.new("Bad data: Text cannot be empty") }) do
          TokenizeText.perform(text: "返品", model: "grok-4.3")
        end
      end

      assert_equal "Bad data: Text cannot be empty", error.message
    end

    private

    # A Tokenization as RubyLLM builds it from xAI's answer, from
    # [id, string, bytes] triples.
    def tokenization(tokens)
      raw = { "token_ids" => tokens.map { |id, string, bytes| { "token_id" => id, "string_token" => string, "token_bytes" => bytes } } }
      RubyLLM::Tokenization.new(ids: tokens.map(&:first), model: "grok-4.3", raw: raw)
    end

    # Replaces RubyLLM.tokenize for the block, so that no provider is called.
    # The body runs as a method of RubyLLM, so it cannot call this test's
    # helpers.
    def with_tokenize(body)
      original = RubyLLM.method(:tokenize)
      RubyLLM.define_singleton_method(:tokenize, body)
      yield
    ensure
      RubyLLM.define_singleton_method(:tokenize, original)
    end
  end
end
