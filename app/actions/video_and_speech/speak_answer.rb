module VideoAndSpeech
  # Reads a support desk's answer aloud.
  #
  # RubyLLM.speak returns a RubyLLM::Speech holding the audio bytes. It is
  # returned as it is: speech.save("answer.mp3") writes it to a file, and
  # speech.to_blob gives the bytes to attach to a Rails record, which is how
  # this demo keeps the audio with the run.
  #
  # OpenAI reports no usage for speech, and RubyLLM lists no price for its
  # speech models, so the cost is unknown: speech.cost.total is nil.
  #
  # OpenAI's usage policies require telling listeners that the voice is
  # AI-generated.
  class SpeakAnswer < ApplicationAction
    # One of the two voices OpenAI recommends for gpt-4o-mini-tts.
    VOICE = "marin"

    # How to speak. provider_options is sent to OpenAI as it is, in OpenAI's
    # own vocabulary; tts-1 and tts-1-hd do not take instructions.
    INSTRUCTIONS = "サポートデスクの担当者として、落ち着いた丁寧な口調で読み上げてください。"

    def initialize(text:, model:)
      @text = text
      @model = model
    end

    # The text is not measured here. OpenAI refuses text that is too long
    # for the model, and RubyLLM raises RubyLLM::BadRequestError with
    # OpenAI's message.
    def perform
      # mp3 is the default format, named here to show where it is chosen.
      # Every major browser plays it.
      speech = RubyLLM.speak(
        @text,
        model: @model,
        voice: VOICE,
        format: "mp3",
        provider_options: { instructions: INSTRUCTIONS }
      )

      {
        "speech" => speech,
        "model" => speech.model,
        "voice" => speech.voice,
        "format" => speech.format,
        "characters" => @text.length
      }
    end
  end
end
