require "test_helper"

module VideoAndSpeech
  class SpeakAnswerTest < ActiveSupport::TestCase
    include ScreenHelpers

    test "reads the answer aloud once, in the chosen voice, format, and manner" do
      calls = []
      speech = fake_speech(data: "mp3 bytes", model: "gpt-4o-mini-tts", voice: "marin", format: "mp3")

      with_speak(->(text, **options) { calls << [ text, options ]; speech }) do
        SpeakAnswer.perform(text: "ご注文の商品は明日お届けします。", model: "gpt-4o-mini-tts")
      end

      text, options = calls.sole
      assert_equal "ご注文の商品は明日お届けします。", text
      assert_equal "gpt-4o-mini-tts", options[:model]
      assert_equal "marin", options[:voice]
      assert_equal "mp3", options[:format]
      assert_match(/サポートデスク/, options.dig(:provider_options, :instructions))
    end

    test "returns the audio as RubyLLM gave it, with its model, voice, format, and the length of the answer" do
      speech = fake_speech(model: "gpt-4o-mini-tts-2025-12-15", voice: "cedar", format: "wav")

      result = with_speak(->(_text, **) { speech }) do
        SpeakAnswer.perform(text: "明日お届けします。", model: "gpt-4o-mini-tts")
      end

      assert_same speech, result["speech"]
      assert_equal "gpt-4o-mini-tts-2025-12-15", result["model"]
      assert_equal "cedar", result["voice"]
      assert_equal "wav", result["format"]
      assert_equal 9, result["characters"]
      assert_equal %w[speech model voice format characters], result.keys
    end

    test "lets a failed generation propagate" do
      error = assert_raises(RubyLLM::BadRequestError) do
        with_speak(->(_text, **) { raise RubyLLM::BadRequestError.new("Input of 2345 tokens is over the maximum input limit of 2000 tokens") }) do
          SpeakAnswer.perform(text: "長い回答文", model: "gpt-4o-mini-tts")
        end
      end

      assert_match(/maximum input limit/, error.message)
    end

    private

    # Replaces RubyLLM.speak for the block, so that no provider is called.
    def with_speak(body)
      original = RubyLLM.method(:speak)
      RubyLLM.define_singleton_method(:speak, body)
      yield
    ensure
      RubyLLM.define_singleton_method(:speak, original)
    end
  end
end
