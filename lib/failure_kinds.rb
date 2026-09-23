require "ruby_llm"

# Names a failed provider call and lists its likely causes, so the reader can
# tell whether to fix a credential, top up a balance, or just wait.
#
# Loads without Rails: bin/check_keys uses the same table as the demo runs.
module FailureKinds
  Kind = Data.define(:name, :hint)

  PROVIDER_OUTAGE = "プロバイダー側の障害。時間をおいて実行する".freeze
  NETWORK = "ネットワークか、プロバイダー側の障害".freeze

  # Checked in order with is_a?, so a subclass must come before its parent,
  # and the base classes come last. ConfigurationError, ModelNotFoundError,
  # and the Faraday errors do not inherit from RubyLLM::Error and are listed
  # on their own.
  TABLE = {
    # A research job's wait raises TimeoutError at its own deadline and
    # Error when the provider reports failure. The limit belongs to the
    # caller that waits, so the hint gives no number.
    RubyLLM::ResearchJob::TimeoutError => Kind.new(
      "待ち時間の上限",
      "アプリの 1 回の待ちの上限を超えた。プロバイダー側の処理は続いているかもしれない。" \
      "実行の画面のジョブ ID で状態を確かめる"
    ),
    RubyLLM::ResearchJob::Error => Kind.new(
      "調査の失敗",
      "プロバイダーが調査を失敗として報告したか、レポートが空か、応答を解釈できなかった。メッセージの内容を確かめる"
    ),
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
      "レート制限か、残高の不足。OpenAI は残高の不足もこの種類で返す。" \
      "Vertex AI の Deep Research はプロジェクトのクォータ（Google Cloud のコンソールで引き上げを申請する）"
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
    Faraday::ConnectionFailed => Kind.new("接続の失敗", NETWORK),
    # A generated video that holds only a URL is downloaded with Faraday
    # directly, outside RubyLLM's error handling, and its URL is temporary.
    Faraday::ClientError => Kind.new(
      "取得の失敗",
      "プロバイダーが取得を拒んだ（4xx）。動画の URL の期限切れなど。もう一度実行する"
    ),
    # RubyLLM turns the HTTP errors of its requests to a provider's API into
    # its own errors. A bare Faraday error, such as a 5xx or a TLS failure,
    # comes from its plain downloads instead: a generated video or image, an
    # attachment given by URL, or the model registry.
    Faraday::Error => Kind.new("取得の失敗", "#{NETWORK}。もう一度実行する"),
    # RubyLLM raises the base class when a video or research job fails,
    # expires, or runs out of time, and for an HTTP status it has no class
    # for, such as 404.
    RubyLLM::Error => Kind.new(
      "プロバイダーのエラー",
      "プロバイダーがエラーを返した。動画や調査の処理の失敗・期限切れ、待ち時間の上限、表にない HTTP のステータスなど。メッセージを確かめる"
    )
  }.freeze

  # Not raised by a provider call: Solid Queue gives up on the jobs a dead
  # worker had claimed and does not run them again.
  WORKER_LOST = Kind.new(
    "ワーカーの異常終了",
    "ジョブのワーカーが止まった。ワーカーが動いていることを確かめ、もう一度実行する"
  )

  # Not raised by a provider call: Solid Queue puts a job back in the queue
  # when its worker stops gracefully, and a scenario that must not start over
  # cannot go on without a record of where it got to.
  INTERRUPTED = Kind.new(
    "ジョブの中断",
    "ジョブのワーカーが止まってジョブが戻されたが、途中から再開できる記録がない。もう一度実行する"
  )

  # Not raised as its own error: the provider reports that the work was
  # cancelled, which a research job's wait raises as an Error.
  CANCELLED = Kind.new(
    "取り消し",
    "プロバイダー側で調査が取り消された。RubyLLM のジョブの `cancel` など"
  )

  # Not raised as its own error: the provider answers 404 for work the app
  # kept the ID of.
  EXPIRED = Kind.new(
    "期限切れ",
    "プロバイダーの保存期間（7 日）を過ぎたか、ID の誤り"
  )

  # Failures that may pass by themselves: the network, the provider's
  # outage, its rate limit, and credentials that can be renewed while the
  # work waits on the provider's side.
  RETRY_LATER = [
    Faraday::TimeoutError, Faraday::ConnectionFailed,
    RubyLLM::ServerError, RubyLLM::OverloadedError, RubyLLM::ServiceUnavailableError,
    RubyLLM::RateLimitError, RubyLLM::UnauthorizedError
  ].map { |error_class| TABLE.fetch(error_class) }.freeze

  # Returns the Kind for +error+, or nil when the table does not know it.
  #
  # A research job wraps the error of a failed poll in its own Error, which
  # only adds the job's ID to the message. The cause lies in the wrapped
  # error, so a wrapped error the table knows names the kind.
  def self.for(error)
    kind = lookup(error)
    return kind unless error.is_a?(RubyLLM::ResearchJob::Error) && error.cause

    lookup(error.cause) || kind
  end

  def self.lookup(error)
    TABLE.find { |error_class, _| error.is_a?(error_class) }&.last
  end
  private_class_method :lookup

  # Returns the Kind for an error class given by its name, as a result keeps
  # it, judged as .for judges an error of that class. Returns nil when the
  # name is not a class the table knows.
  def self.for_class_name(name)
    error_class = Object.const_get(name) unless name.to_s.empty?
    return unless error_class.is_a?(Class)

    TABLE.find { |table_class, _| error_class <= table_class }&.last
  rescue NameError, TypeError # TypeError: a name under a constant that is not a module
    nil
  end

  # Whether +error+ came from calling a provider rather than from a bug in
  # the caller: any RubyLLM::Error, or an error the table names.
  def self.provider_call?(error)
    error.is_a?(RubyLLM::Error) || !self.for(error).nil?
  end

  # Whether the provider cancelled the research job +error+ was raised for.
  def self.cancelled?(error)
    error.is_a?(RubyLLM::ResearchJob::Error) && error.job&.cancelled? ? true : false
  end

  # Whether the provider answered that it has no such work, in +error+ or
  # in the error it wraps. RubyLLM raises a 404 as a plain RubyLLM::Error,
  # so it is told by the response's status rather than by a row.
  def self.not_found?(error)
    [ error, error.cause ].any? { |raised| raised.is_a?(RubyLLM::Error) && raised.response&.status == 404 }
  end

  # Whether +error+ may pass if the same call is made again later.
  def self.retry_later?(error)
    RETRY_LATER.include?(self.for(error))
  end
end
