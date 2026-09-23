require "test_helper"

module VideoAndSpeech
  class GenerateProductVideoTest < ActiveSupport::TestCase
    DESCRIPTION = "ステンレス製の電気ケトル。容量は 1.0 リットルで、注ぎ口が細い。".freeze

    # Stands in for a reopened RubyLLM::VideoJob: it keeps what it was asked
    # to wait with, and hands back the video, or the error, it was given.
    class FakeVideoJob
      attr_reader :id, :waits

      def initialize(id:, video: nil, error: nil)
        @id = id
        @video = video
        @error = error
        @waits = []
      end

      def wait(**options)
        @waits << options
        raise @error if @error

        self
      end

      def video = @video
    end

    test "leaves the video with xAI once, with the description in the prompt, and the duration, resolution, and aspect ratio" do
      calls = []
      job = FakeVideoJob.new(id: "video-1")

      returned = with_animate_later(->(prompt, **options) { calls << [ prompt, options ]; job }) do
        GenerateProductVideo.perform(description: DESCRIPTION, model: "grok-imagine-video-1.5")
      end

      assert_same job, returned
      prompt, options = calls.sole
      assert_includes prompt, DESCRIPTION
      assert_match(/紹介動画/, prompt)
      assert_equal "grok-imagine-video-1.5", options[:model]
      assert_equal({ duration: 6, resolution: "480p", aspect_ratio: "16:9" }, options[:provider_options])
    end

    test "lets a failed submission propagate" do
      error = assert_raises(RubyLLM::RateLimitError) do
        with_animate_later(->(_prompt, **) { raise RubyLLM::RateLimitError, "Rate limit reached" }) do
          GenerateProductVideo.perform(description: DESCRIPTION, model: "grok-imagine-video-1.5")
        end
      end

      assert_equal "Rate limit reached", error.message
    end

    test "reopens the job by its id and model, waits up to 30 minutes every 10 seconds, and returns the video with its details" do
      video = RubyLLM::Video.new(url: "https://vidgen.x.ai/video-1.mp4", mime_type: "video/mp4", model: "grok-imagine-video-1.5", duration: 6)
      job = FakeVideoJob.new(id: "video-1", video: video)
      reopened = []

      result = with_reopen(->(id, model:) { reopened << [ id, model ]; job }) do
        GenerateProductVideo.resume("video-1", model: "grok-imagine-video-1.5")
      end

      assert_equal [ [ "video-1", "grok-imagine-video-1.5" ] ], reopened
      assert_equal [ { timeout: 1800, interval: 10 } ], job.waits
      assert_same video, result["video"]
      assert_equal({
        "model" => "grok-imagine-video-1.5", "job_id" => "video-1", "duration" => 6, "resolution" => "480p", "aspect_ratio" => "16:9"
      }, result.except("video"))
      assert_equal %w[video model job_id duration resolution aspect_ratio], result.keys
    end

    test "leaves the duration empty when xAI reports none" do
      video = RubyLLM::Video.new(url: "https://vidgen.x.ai/video-1.mp4", mime_type: "video/mp4", model: "grok-imagine-video-1.5")

      result = with_reopen(->(id, model:) { FakeVideoJob.new(id: id, video: video) }) do
        GenerateProductVideo.resume("video-1", model: "grok-imagine-video-1.5")
      end

      assert_nil result["duration"]
    end

    # xAI marks a video that moderation filtered out as done, with an empty
    # URL, and RubyLLM takes it as completed.
    test "refuses a finished video without a URL" do
      [ nil, "" ].each do |url|
        video = RubyLLM::Video.new(url: url, mime_type: "video/mp4", model: "grok-imagine-video-1.5")

        error = assert_raises(RubyLLM::Error, url.inspect) do
          with_reopen(->(id, model:) { FakeVideoJob.new(id: id, video: video) }) do
            GenerateProductVideo.resume("video-1", model: "grok-imagine-video-1.5")
          end
        end

        assert_match(/video-1/, error.message)
        assert_match(/URL/, error.message)
      end
    end

    test "lets a failed, expired, or timed out video propagate" do
      [
        "Video generation failed: {\"code\" => \"invalid_argument\", \"message\" => \"Prompt is too long\"}",
        "Video generation failed: expired",
        "Video generation timed out after 1800 seconds"
      ].each do |message|
        error = assert_raises(RubyLLM::Error, message) do
          with_reopen(->(id, model:) { FakeVideoJob.new(id: id, error: RubyLLM::Error.new(message)) }) do
            GenerateProductVideo.resume("video-1", model: "grok-imagine-video-1.5")
          end
        end

        assert_equal message, error.message
      end
    end

    # The reopened job must poll xAI for the same work, and start pending so
    # that wait fetches the state the video is read from.
    test "reopens a pending job of xAI's that polls the video by its id" do
      job = GenerateProductVideo.reopen("0eb6910f-a353-4699-9d1e-6a4f7a5b39e2", model: "grok-imagine-video-1.5")

      assert_kind_of RubyLLM::VideoJob, job
      assert_equal "0eb6910f-a353-4699-9d1e-6a4f7a5b39e2", job.id
      assert_equal "grok-imagine-video-1.5", job.model
      assert_predicate job, :pending?
      protocol = job.instance_variable_get(:@protocol)
      assert_equal "xai", protocol.provider.slug
      assert_equal "videos/0eb6910f-a353-4699-9d1e-6a4f7a5b39e2", protocol.video_job_url(job)
    end

    private

    # Replaces RubyLLM.animate_later for the block, so that no provider is called.
    def with_animate_later(body)
      original = RubyLLM.method(:animate_later)
      RubyLLM.define_singleton_method(:animate_later, body)
      yield
    ensure
      RubyLLM.define_singleton_method(:animate_later, original)
    end

    # Replaces reopening the job for the block, so that no provider is polled.
    def with_reopen(body)
      original = GenerateProductVideo.method(:reopen)
      GenerateProductVideo.define_singleton_method(:reopen, body)
      yield
    ensure
      GenerateProductVideo.define_singleton_method(:reopen, original)
    end
  end
end
