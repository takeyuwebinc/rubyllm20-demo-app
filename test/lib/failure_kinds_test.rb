require "test_helper"

class FailureKindsTest < ActiveSupport::TestCase
  test "names each provider error and gives its likely causes" do
    {
      RubyLLM::UnauthorizedError => "認証の失敗",
      RubyLLM::BadRequestError => "不正なリクエスト",
      RubyLLM::PaymentRequiredError => "支払いが必要",
      RubyLLM::RateLimitError => "レート制限",
      RubyLLM::ForbiddenError => "権限の不足",
      RubyLLM::ContextLengthExceededError => "入力がモデルの上限を超えた",
      RubyLLM::ServerError => "サーバー側のエラー",
      RubyLLM::OverloadedError => "過負荷",
      RubyLLM::ServiceUnavailableError => "サービス停止"
    }.each do |error_class, name|
      kind = FailureKinds.for(error_class.new("boom"))

      assert_equal name, kind.name, error_class.name
      assert_predicate kind.hint, :present?, error_class.name
    end
  end

  test "covers the setup errors that do not inherit from RubyLLM::Error" do
    assert_equal "設定値の不足", FailureKinds.for(RubyLLM::ConfigurationError.new("missing")).name
    assert_equal "モデルが見つからない", FailureKinds.for(RubyLLM::ModelNotFoundError.new("gpt-x")).name
  end

  test "covers timeouts and connection failures raised by the HTTP client" do
    assert_equal "タイムアウト", FailureKinds.for(Faraday::TimeoutError.new("slow")).name
    assert_equal "接続の失敗", FailureKinds.for(Faraday::ConnectionFailed.new("refused")).name
  end

  test "points out that OpenAI reports an empty balance as a rate limit" do
    assert_match "残高", FailureKinds.for(RubyLLM::RateLimitError.new).hint
  end

  # RubyLLM raises the base error when a video or a research job fails,
  # expires, or runs out of time, and for an HTTP status it has no class for.
  test "names any other RubyLLM error a provider error, with causes to check" do
    [
      RubyLLM::Error.new("Video generation failed: expired"),
      RubyLLM::Error.new("Video generation timed out after 1800 seconds"),
      RubyLLM::ToolCallParseError.new("unexpected token")
    ].each do |error|
      kind = FailureKinds.for(error)

      assert_equal "プロバイダーのエラー", kind.name, error.class.name
      assert_match "メッセージを確かめる", kind.hint, error.class.name
    end
  end

  # A generated video that holds only a URL is downloaded, outside RubyLLM's
  # error handling, and its URL is only good for a while.
  test "names a download the provider refused a failed download, with causes to check" do
    [ Faraday::ResourceNotFound.new("404"), Faraday::ForbiddenError.new("403"), Faraday::ClientError.new("410") ].each do |error|
      kind = FailureKinds.for(error)

      assert_equal "取得の失敗", kind.name, error.class.name
      assert_match "URL の期限切れ", kind.hint, error.class.name
    end
  end

  # RubyLLM turns the HTTP errors of its requests to a provider's API into
  # its own errors, so a bare Faraday error comes from a plain download.
  test "names a download that failed at the provider or on the way a failed download, with causes to check" do
    [ Faraday::ServerError.new("the server responded with status 503"), Faraday::SSLError.new("certificate verify failed") ].each do |error|
      kind = FailureKinds.for(error)

      assert_equal "取得の失敗", kind.name, error.class.name
      assert_match "もう一度実行する", kind.hint, error.class.name
      assert_no_match(/4xx/, kind.hint, error.class.name)
      assert FailureKinds.provider_call?(error), error.class.name
    end
  end

  test "names a subclass by its own row rather than the base rows" do
    assert_equal "認証の失敗", FailureKinds.for(RubyLLM::UnauthorizedError.new("bad key")).name
    assert_equal "サービス停止", FailureKinds.for(RubyLLM::ServiceUnavailableError.new("down")).name
    assert_equal "タイムアウト", FailureKinds.for(Faraday::TimeoutError.new("slow")).name
    assert_equal "接続の失敗", FailureKinds.for(Faraday::ConnectionFailed.new("refused")).name
  end

  test "returns nil for an error outside the table" do
    assert_nil FailureKinds.for(ArgumentError.new)
    assert_nil FailureKinds.for(IOError.new("disk full"))
  end

  test "names an error from its class name" do
    assert_equal "接続の失敗", FailureKinds.for_class_name("Faraday::ConnectionFailed").name
    assert_equal "レート制限", FailureKinds.for_class_name("RubyLLM::RateLimitError").name
  end

  # A provider error the table does not list, known by the class it inherits.
  class SlowDownError < RubyLLM::RateLimitError; end

  test "judges a class name in the same order and by the same inheritance as an error" do
    [ *FailureKinds::TABLE.keys, SlowDownError ].each do |error_class|
      assert_equal FailureKinds.for(error_class.allocate), FailureKinds.for_class_name(error_class.name), error_class.name
    end
  end

  test "returns nil for a class name it does not know, without raising" do
    assert_nil FailureKinds.for_class_name("JSON::ParserError")
    assert_nil FailureKinds.for_class_name("RubyLLM::NoSuchError")
    assert_nil FailureKinds.for_class_name("not a constant")
    assert_nil FailureKinds.for_class_name("RubyLLM::VERSION")
    assert_nil FailureKinds.for_class_name("RubyLLM::VERSION::Error")
    assert_nil FailureKinds.for_class_name(nil)
    assert_nil FailureKinds.for_class_name("")
  end

  test "tells provider failures from bugs" do
    assert FailureKinds.provider_call?(RubyLLM::ToolCallParseError.new)
    assert FailureKinds.provider_call?(RubyLLM::Error.new("Video generation failed: expired"))
    assert FailureKinds.provider_call?(RubyLLM::ModelNotFoundError.new("gpt-x"))
    assert FailureKinds.provider_call?(Faraday::ConnectionFailed.new("refused"))
    assert FailureKinds.provider_call?(Faraday::ResourceNotFound.new("404"))
    refute FailureKinds.provider_call?(NoMethodError.new("content"))
  end

  test "describes a worker that died while running a job" do
    assert_equal "ワーカーの異常終了", FailureKinds::WORKER_LOST.name
    assert_match "もう一度実行", FailureKinds::WORKER_LOST.hint
  end

  test "names a research job that failed and a wait that ran out of time" do
    job = research_job(:failed)
    timeout = FailureKinds.for(RubyLLM::ResearchJob::TimeoutError.new("Research timed out (job j1)", job: research_job(:pending)))
    failure = FailureKinds.for(RubyLLM::ResearchJob::Error.new("Research failed: boom (job j1)", job: job))

    assert_equal "待ち時間の上限", timeout.name
    assert_match "ジョブ ID", timeout.hint
    # The limit is the handler's own; the hint does not repeat its number.
    refute_match(/\d+\s*分/, timeout.hint)
    assert_equal "調査の失敗", failure.name
    assert_match "メッセージ", failure.hint
    assert FailureKinds.provider_call?(RubyLLM::ResearchJob::TimeoutError.new("t", job: job))
    assert FailureKinds.provider_call?(RubyLLM::ResearchJob::Error.new("e", job: job))
  end

  test "names a research error that wraps a known error after the error it wraps" do
    job = research_job(:pending)

    unauthorized = with_cause(RubyLLM::ResearchJob::Error.new("Research request failed: denied (job j1)", job: job), RubyLLM::UnauthorizedError.new("denied"))
    slow_poll = with_cause(RubyLLM::ResearchJob::TimeoutError.new("Research request timed out (job j1)", job: job), Faraday::TimeoutError.new("slow"))
    unknown = with_cause(RubyLLM::ResearchJob::Error.new("Research request failed: odd (job j1)", job: job), ArgumentError.new("odd"))

    assert_equal "認証の失敗", FailureKinds.for(unauthorized).name
    assert_equal FailureKinds.for(RubyLLM::UnauthorizedError.new).hint, FailureKinds.for(unauthorized).hint
    assert_equal "タイムアウト", FailureKinds.for(slow_poll).name
    assert_equal "調査の失敗", FailureKinds.for(unknown).name
  end

  test "names a wait that ran past its deadline during a poll after the deadline, not after what interrupted the poll" do
    # RubyLLM interrupts a poll that would run past the deadline with an
    # error of its own that the table does not know.
    deadline = with_cause(RubyLLM::ResearchJob::TimeoutError.new("Research request timed out (job j1)", job: research_job(:pending)), StandardError.new("deadline"))

    assert_equal "待ち時間の上限", FailureKinds.for(deadline).name
    refute FailureKinds.retry_later?(deadline)
  end

  test "points out that Vertex AI's Deep Research is limited by the project's quota" do
    assert_match "Vertex AI", FailureKinds.for(RubyLLM::RateLimitError.new).hint
    assert_match "クォータ", FailureKinds.for(RubyLLM::RateLimitError.new).hint
  end

  test "describes work the provider cancelled and work it no longer has" do
    assert_equal "取り消し", FailureKinds::CANCELLED.name
    assert_match "取り消", FailureKinds::CANCELLED.hint
    assert_equal "期限切れ", FailureKinds::EXPIRED.name
    assert_match "7 日", FailureKinds::EXPIRED.hint
    assert_match "ID", FailureKinds::EXPIRED.hint
  end

  test "tells a cancelled research job only from the job the error holds" do
    assert FailureKinds.cancelled?(RubyLLM::ResearchJob::Error.new("Research cancelled:  (job j1)", job: research_job(:cancelled)))
    refute FailureKinds.cancelled?(RubyLLM::ResearchJob::Error.new("Research failed: boom (job j1)", job: research_job(:failed)))
    refute FailureKinds.cancelled?(RubyLLM::ResearchJob::TimeoutError.new("Research timed out (job j1)", job: research_job(:pending)))
    refute FailureKinds.cancelled?(RubyLLM::Error.new("cancelled"))
    refute FailureKinds.cancelled?(ArgumentError.new)
  end

  test "tells work the provider cannot find from a 404 response of the error or of the error it wraps" do
    not_found = RubyLLM::Error.new("Not found", response: http_response(404))

    assert FailureKinds.not_found?(not_found)
    assert FailureKinds.not_found?(with_cause(RubyLLM::ResearchJob::Error.new("Research request failed (job j1)", job: research_job(:pending)), not_found))
    refute FailureKinds.not_found?(RubyLLM::ServerError.new("boom", response: http_response(500)))
    refute FailureKinds.not_found?(RubyLLM::Error.new("no response"))
    refute FailureKinds.not_found?(ArgumentError.new)
  end

  test "tells failures worth trying again later from the ones that will fail the same way" do
    job = research_job(:pending)
    later = [
      Faraday::TimeoutError.new("slow"),
      Faraday::ConnectionFailed.new("refused"),
      RubyLLM::ServerError.new,
      RubyLLM::OverloadedError.new,
      RubyLLM::ServiceUnavailableError.new,
      RubyLLM::RateLimitError.new,
      RubyLLM::UnauthorizedError.new,
      with_cause(RubyLLM::ResearchJob::Error.new("Research request failed (job j1)", job: job), RubyLLM::UnauthorizedError.new),
      with_cause(RubyLLM::ResearchJob::TimeoutError.new("Research request timed out (job j1)", job: job), Faraday::TimeoutError.new("slow"))
    ]
    final = [
      RubyLLM::ResearchJob::TimeoutError.new("Research timed out (job j1)", job: job),
      RubyLLM::ResearchJob::Error.new("Research failed: boom (job j1)", job: research_job(:failed)),
      RubyLLM::BadRequestError.new,
      RubyLLM::ForbiddenError.new,
      RubyLLM::ConfigurationError.new("missing"),
      ArgumentError.new
    ]

    later.each { |error| assert FailureKinds.retry_later?(error), error.inspect }
    final.each { |error| refute FailureKinds.retry_later?(error), error.inspect }
  end

  test "describes a job that was put back with nothing to continue from" do
    assert_equal "ジョブの中断", FailureKinds::INTERRUPTED.name
    assert_match "再開できる記録がない", FailureKinds::INTERRUPTED.hint
    assert_match "もう一度実行", FailureKinds::INTERRUPTED.hint
  end

  test "describes work that the provider ended without finishing it" do
    assert_equal "プロバイダー側の処理の失敗", FailureKinds::REMOTE_JOB_FAILED.name
    assert_match "24 時間以内に処理されなかった", FailureKinds::REMOTE_JOB_FAILED.hint
    assert_match "完了した分は課金され", FailureKinds::REMOTE_JOB_FAILED.hint
  end

  test "describes work that was cancelled at the provider" do
    assert_equal "プロバイダー側の処理の取り消し", FailureKinds::REMOTE_JOB_CANCELLED.name
    assert_match "取り消された", FailureKinds::REMOTE_JOB_CANCELLED.hint
    assert_match "完了した分は結果に残る", FailureKinds::REMOTE_JOB_CANCELLED.hint
  end

  test "keeps the kinds for work ended at the provider out of the table of errors" do
    assert_not_includes FailureKinds::TABLE.values, FailureKinds::REMOTE_JOB_FAILED
    assert_not_includes FailureKinds::TABLE.values, FailureKinds::REMOTE_JOB_CANCELLED
    assert_equal "レート制限", FailureKinds.for(RubyLLM::RateLimitError.new).name
    assert_equal "プロバイダーのエラー", FailureKinds.for(RubyLLM::Error.new("expired")).name
    assert FailureKinds.provider_call?(RubyLLM::Error.new("expired"))
    refute FailureKinds.provider_call?(ArgumentError.new)
  end

  private

  # Only the job's state is read from an error, so a stand-in answers for it.
  def research_job(status)
    Data.define(:status) { def cancelled? = status == :cancelled }.new(status)
  end

  def http_response(status)
    Data.define(:status, :body).new(status, "")
  end

  # The error as RubyLLM raises it while handling +cause+.
  def with_cause(error, cause)
    raise error, cause: cause
  rescue StandardError => raised
    raised
  end
end
