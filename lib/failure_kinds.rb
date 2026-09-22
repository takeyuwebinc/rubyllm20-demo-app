require "ruby_llm"

# Names a failed provider call and lists its likely causes, so the reader can
# tell whether to fix a credential, top up a balance, or just wait.
#
# Loads without Rails: bin/check_keys uses the same table as the demo runs.
module FailureKinds
  Kind = Data.define(:name, :hint)

  PROVIDER_OUTAGE = "プロバイダー側の障害。時間をおいて実行する".freeze
  NETWORK = "ネットワークか、プロバイダー側の障害".freeze

  # Checked in order with is_a?, so a subclass must come before its parent.
  # ConfigurationError, ModelNotFoundError, and the Faraday errors do not
  # inherit from RubyLLM::Error and are listed on their own.
  TABLE = {
    RubyLLM::UnauthorizedError => Kind.new(
      "認証の失敗",
      "認証情報の誤りか失効。Vertex AI では Application Default Credentials の失効" \
      "（`gcloud auth application-default login` で作り直す）"
    ),
    RubyLLM::BadRequestError => Kind.new(
      "不正なリクエスト",
      "リクエストの内容の誤り。xAI は無効な認証情報もこの種類で返すため、まず認証情報を確かめる"
    ),
    RubyLLM::PaymentRequiredError => Kind.new(
      "支払いが必要",
      "残高の不足。プロバイダーのコンソールで課金の設定と残高を確かめる"
    ),
    RubyLLM::RateLimitError => Kind.new(
      "レート制限",
      "レート制限か、残高の不足。OpenAI は残高の不足もこの種類で返す"
    ),
    RubyLLM::ForbiddenError => Kind.new(
      "権限の不足",
      "モデルへのアクセス権、API の有効化、権限の設定"
    ),
    RubyLLM::ContextLengthExceededError => Kind.new(
      "入力がモデルの上限を超えた",
      "入力がモデルの上限を超えている。入力を短くする"
    ),
    RubyLLM::ServerError => Kind.new("サーバー側のエラー", PROVIDER_OUTAGE),
    RubyLLM::OverloadedError => Kind.new("過負荷", PROVIDER_OUTAGE),
    RubyLLM::ServiceUnavailableError => Kind.new("サービス停止", PROVIDER_OUTAGE),
    RubyLLM::ConfigurationError => Kind.new(
      "設定値の不足",
      "環境変数の未設定か、変数名の誤り。.env を確かめる"
    ),
    RubyLLM::ModelNotFoundError => Kind.new(
      "モデルが見つからない",
      "モデルの識別子の誤り"
    ),
    Faraday::TimeoutError => Kind.new("タイムアウト", NETWORK),
    Faraday::ConnectionFailed => Kind.new("接続の失敗", NETWORK)
  }.freeze

  # Not raised by a provider call: Solid Queue gives up on the jobs a dead
  # worker had claimed and does not run them again.
  WORKER_LOST = Kind.new(
    "ワーカーの異常終了",
    "ジョブのワーカーが止まった。ワーカーが動いていることを確かめ、もう一度実行する"
  )

  # Returns the Kind for +error+, or nil when the table does not know it.
  def self.for(error)
    TABLE.find { |error_class, _| error.is_a?(error_class) }&.last
  end
end
