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

  test "describes a job that was put back with nothing to continue from" do
    assert_equal "ジョブの中断", FailureKinds::INTERRUPTED.name
    assert_match "再開できる記録がない", FailureKinds::INTERRUPTED.hint
    assert_match "もう一度実行", FailureKinds::INTERRUPTED.hint
  end
end
