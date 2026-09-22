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

  test "returns nil for an error outside the table" do
    assert_nil FailureKinds.for(RubyLLM::ToolCallParseError.new)
    assert_nil FailureKinds.for(ArgumentError.new)
  end

  test "describes a worker that died while running a job" do
    assert_equal "ワーカーの異常終了", FailureKinds::WORKER_LOST.name
    assert_match "もう一度実行", FailureKinds::WORKER_LOST.hint
  end
end
