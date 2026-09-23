module VideoAndSpeech
  # Generates a short promotional video of a product from its description.
  #
  # Video generation is asynchronous on every provider: RubyLLM.animate
  # submits the video and waits until it is done. RubyLLM.animate_later
  # only submits it, and returns a RubyLLM::VideoJob at once, whose id is
  # what the provider knows the work by. The job that runs this keeps that
  # id with the run before calling .resume, so a job stopped while it waits,
  # such as by a restart of the app, waits again from the id instead of
  # generating, and paying for, the video twice.
  #
  # xAI hands the finished video back as a temporary URL. video.to_blob
  # downloads it, which is how this demo keeps the video with the run, and
  # video.save("product.mp4") writes it to a file.
  #
  # RubyLLM lists no price for xAI's video models and its Video does not
  # read the cost xAI reports, so the cost is unknown.
  class GenerateProductVideo < ApplicationAction
    # What the video is for, ahead of the product's description. Video
    # models draw lettering poorly, so the video is asked to have none.
    PREFACE = "架空の EC サイトに載せる、商品の短い紹介動画。次の説明文の商品を、明るく清潔な背景の上で、" \
              "いろいろな角度から見せる。文字やロゴは入れない。".freeze

    # provider_options go to xAI as they are, in xAI's own vocabulary. xAI
    # charges by the second and by resolution: 6 seconds of
    # grok-imagine-video-1.5 at 480p costs 0.48 USD. 480p and 16:9 are
    # xAI's defaults, named here to show where they are chosen.
    OPTIONS = { duration: 6, resolution: "480p", aspect_ratio: "16:9" }.freeze

    # xAI says a video typically takes up to several minutes, so a video not
    # done in 30 minutes is taken as a failure at the provider. Each poll is
    # a request span in the trace; every 10 seconds, rather than RubyLLM's
    # default of 5, keeps them to at most 180.
    TIMEOUT = 30 * 60
    POLL_INTERVAL = 10

    # Waits for the video left with xAI under +id+, and returns it with how
    # it was made. A video that failed, expired, or was not done in time
    # raises RubyLLM::Error from wait.
    def self.resume(id, model:)
      job = reopen(id, model:)
      job.wait(timeout: TIMEOUT, interval: POLL_INTERVAL)
      video = job.video
      # xAI marks a video that moderation filtered out as done, with no URL,
      # and RubyLLM takes it as completed.
      if video.url.blank? && video.data.nil?
        raise RubyLLM::Error, "Video generation #{job.id} finished without a video URL; xAI leaves it empty when moderation filters the video out"
      end

      {
        "video" => video,
        "model" => video.model,
        "job_id" => job.id,
        "duration" => video.duration,
        "resolution" => OPTIONS[:resolution],
        "aspect_ratio" => OPTIONS[:aspect_ratio]
      }
    end

    # Opens the job again from its id alone. RubyLLM 2.0.0 has no public way
    # to do this: VideoJob has no find, unlike Batch and ResearchJob. This
    # builds the job the way RubyLLM's own animate_later does, from methods
    # its guides do not document; the gem's version is pinned, which keeps
    # it working. The job starts pending, because xAI's video is read from
    # the state that wait fetches. Polling xAI's state endpoint directly
    # instead would need the same undocumented connection and could not use
    # wait and video; submitting the video again would pay for it again.
    # TODO(when RubyLLM can find a VideoJob by its id): use that instead.
    def self.reopen(id, model:)
      model_info, provider = RubyLLM::Models.resolve(model, provider: :xai)
      protocol = provider.protocol_for(model_info, operation: :animate).new(provider, model_info)
      RubyLLM::VideoJob.new(id: id, protocol: protocol, model: model_info.id)
    end

    def initialize(description:, model:)
      @description = description
      @model = model
    end

    # Returns the job as soon as xAI accepts the video. A prompt xAI finds
    # too long is accepted here, and fails while resume waits.
    def perform
      RubyLLM.animate_later("#{PREFACE}\n\n#{@description}", model: @model, provider_options: OPTIONS)
    end
  end
end
