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
    assert_nil FailureKinds.for_class_name("RubyLLM::ToolCallParseError")
    assert_nil FailureKinds.for_class_name("RubyLLM::NoSuchError")
    assert_nil FailureKinds.for_class_name("not a constant")
    assert_nil FailureKinds.for_class_name("RubyLLM::VERSION")
    assert_nil FailureKinds.for_class_name("RubyLLM::VERSION::Error")
    assert_nil FailureKinds.for_class_name(nil)
    assert_nil FailureKinds.for_class_name("")
  end

  test "tells provider failures from bugs" do
    assert FailureKinds.provider_call?(RubyLLM::ToolCallParseError.new)
    assert FailureKinds.provider_call?(RubyLLM::ModelNotFoundError.new("gpt-x"))
    assert FailureKinds.provider_call?(Faraday::ConnectionFailed.new("refused"))
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
