# API キー取得ガイド

このデモアプリが使う 4 プロバイダーの認証情報と Sentry の DSN を取得し、`.env` に置いて疎通確認するまでの手順。

- 最終確認日: 2026-09-19（RubyLLM 2.0.0）
- 検証できた範囲とできていない範囲は、末尾の「このガイドの検証範囲」に分けて記載した。

## 必要な認証情報とデモの対応

全部を一度に揃える必要はない。RubyLLM は未設定のプロバイダーを実際に使った時点で初めて `RubyLLM::ConfigurationError` を出すため、キーがないデモだけが失敗する。実装フェーズ順に取得すればよい。

| 取得順 | サービス | `.env` の変数 | 使うデモ |
|---|---|---|---|
| 0 | Sentry | `SENTRY_DSN`, `SENTRY_ORG` | 全デモ。試行ごとの観察情報を確認する（エージェントトレーシング）。`SENTRY_ORG` は、実行の画面から Sentry へ移動するリンクに使う |
| 1 | OpenAI | `OPENAI_API_KEY` | Responses API / Tool Approval / Batches / Model Fallbacks（主系）/ Speech / Provider Tools / `count_tokens` / Workflow Instrumentation |
| 2 | Anthropic | `ANTHROPIC_API_KEY` | Citations / Model Fallbacks（切替先） |
| 3 | xAI | `XAI_API_KEY` | Video Generation / `RubyLLM.tokenize` |
| 4 | Vertex AI | `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` | Deep Research のみ |

プロバイダーをこの組み合わせにした理由:

- `with_citations`（文書引用）に対応するのは Anthropic / Cohere / Bedrock 上の Claude のみ。
- OpenAI の動画生成（Sora / Videos API）は 2026-09-24 に停止予定で、RubyLLM の既定動画モデルは xAI の `grok-imagine-video-1.5`。
- `RubyLLM.tokenize` に対応するのは xAI / Cohere / GPUStack のみ。xAI なら動画と兼用できる。
- `RubyLLM.research` の実装は Vertex AI にしかない。

## .env の準備

```sh
cp .env.example .env
```

`.env` は `.gitignore` で除外済み（`.env.example` だけが追跡対象）。値は引用符なしで `KEY=value` の形式で書く。Rails では `dotenv-rails` が development / test 環境で自動的に読み込み、[config/initializers/ruby_llm.rb](../config/initializers/ruby_llm.rb) が RubyLLM に渡す。

## 1. OpenAI

1. <https://platform.openai.com/> でアカウントを作成する。
2. Billing で支払い方法を登録し、クレジットをチャージする。
3. <https://platform.openai.com/api-keys> でシークレットキーを作成する。キーは作成直後の 1 回しか表示されない。
4. `.env` の `OPENAI_API_KEY=` に貼り付ける。

注意点:

- **ChatGPT の有料プラン（Plus / Pro など）と API の課金は別**。プランに加入していても API クレジットは付かない。
- 残高がない状態のキーは認証には通るが、生成時に 429（`insufficient_quota`）で失敗する。`bin/check_keys` はこの状態を検出するために実際にチャットを 1 回送る。
- 一部のモデルや機能は Organization の本人確認を求められることがある。403 が返った場合は、コンソールの Organization 設定で確認状況を見る。

## 2. Anthropic

1. <https://platform.claude.com/> で Claude Console のアカウントを作成する。
2. <https://platform.claude.com/settings/billing> でクレジットを購入する。
3. <https://platform.claude.com/settings/keys> でキーを作成する。作成時にキーの種類と有効期限を選ぶ。
4. `.env` の `ANTHROPIC_API_KEY=` に貼り付ける。

注意点:

- **Claude.ai の有料プラン（Pro / Max など）と API クレジットは別**。
- 利用額はティア制で、組織ごとに月次の上限が自動で決まる。現在の上限は Billing ページ、レート制限は <https://platform.claude.com/settings/limits> で確認できる。
- 用途ごとに利用額を分けて見たい場合は Workspace を分ける。このデモでは Default Workspace のままで足りる。

## 3. xAI

1. <https://console.x.ai/> でアカウントを作成する。
2. コンソールでクレジットをチャージする。
3. <https://console.x.ai/team/default/api-keys> でキーを作成する。
4. `.env` の `XAI_API_KEY=` に貼り付ける。

注意点:

- xAI は**無効なキーを 401 ではなく 400 で返す**（2026-09-19 に実リクエストで確認）。RubyLLM では `RubyLLM::BadRequestError` になるため、400 が出たらまずキーを疑う。
- 動画生成は秒数に応じた課金で、テキスト生成より 1 回あたりの費用が大きい。デモでは生成結果を Active Storage に保存し、再表示では再生成しない設計にする。

## 4. Vertex AI（Deep Research 用）

Vertex AI には API キーがない。Google Cloud の認証情報（Application Default Credentials、以下 ADC）を使う。このマシンには `gcloud` が導入済み（`~/.local/bin/gcloud`）。

前提（Google の Deep Research ドキュメントに記載）:

- 課金が有効な Google Cloud プロジェクト
- Agent Platform API の有効化
- IAM ロール `roles/aiplatform.user` と `roles/serviceusage.serviceUsageConsumer`
- Deep Research エージェントは **Preview（Pre-GA）** 扱い。利用できるエージェント ID は `deep-research-preview-04-2026`

手順:

```sh
# 1. ログインしてプロジェクトを選ぶ（PROJECT_ID は自分のものに置き換える）
gcloud auth login
gcloud config set project PROJECT_ID

# 2. API を有効化する
gcloud services enable aiplatform.googleapis.com

# 3. ADC を作成し、課金先プロジェクトを紐付ける
gcloud auth application-default login
gcloud auth application-default set-quota-project PROJECT_ID
```

`.env` にはプロジェクト ID とロケーションを書く:

```sh
GOOGLE_CLOUD_PROJECT=PROJECT_ID
GOOGLE_CLOUD_LOCATION=global
```

注意点:

- **ロケーションは `global` 固定**。それ以外だと RubyLLM が `ArgumentError: Vertex AI hosted research requires vertexai_location = "global"` を出す。
- 自分が Owner のプロジェクトなら、上記 2 つのロールは追加付与なしで満たされる。
- 課金は、モデルのトークン利用と、検索などのツール実行の合算になる。
- RubyLLM は ADC の代わりにサービスアカウントキーも受け付けるが、`vertexai_service_account_key` に渡すのは**ファイルパスではなく JSON 文字列そのもの**。`.env` に複数行の JSON を置くのは扱いにくいため、このアプリは ADC のみを配線している。
- Vertex AI の認証には `googleauth` gem が必要（Gemfile に追加済み）。

### Deep Research のクォータ

チャットが通っても、Deep Research のジョブを投入できるとは限らない。2026-09-19 に実際のジョブを投入したところ、間隔を 90 秒以上空けた再試行を含む 3 回とも、次のエラーで拒否された。ジョブは作成されず、費用も発生していない。

```
RubyLLM::RateLimitError: Quota exceeded for quota metric
'aiplatform.googleapis.com/stateful_interaction_creations' and limit
'Stateful Interaction Creation requests per minute per project.'
```

間隔を空けても毎分のクォータを超過するため、このプロジェクトの上限が 0 である可能性が高い。上限値は未確認である。値を読むには `gcloud beta` の導入か、Cloud Quotas API の有効化が必要になる。

対処は、Google Cloud コンソールの「IAM と管理」→「割り当てとシステム上限」で、サービスを Vertex AI に絞り、`Stateful Interaction Creation requests per minute per project` の値を確認して、引き上げを申請する。

## 5. Sentry（観察情報用）

観察情報（試行ごとのプロバイダー、モデル、トークン数、コスト、所要時間、送信先）と、プロンプトと応答の本文は、Sentry のエージェントトレーシングで確認する。モデルのプロバイダーではないが、全デモが使うため最初に用意する。既存の sentry.io の組織を使う。

1. sentry.io の組織で、プロジェクトを新規作成する。プラットフォームは Rails を選ぶ。
2. 作成直後の画面に表示される DSN を控える。後から確認する場合は、プロジェクトの設定の Client Keys (DSN) にある。
3. `.env` の `SENTRY_DSN=` に貼り付ける。
4. 組織の識別子（Organization Slug）を `.env` の `SENTRY_ORG=` に書く。Sentry の画面の URL `https://<組織の識別子>.sentry.io/` の先頭の部分である。DSN には含まれないため、別に設定する。未設定でも計装は動くが、実行の画面に Sentry へのリンクが出ない。

注意点:

- Sentry の Ruby SDK は、`config.dsn` を設定しない場合に `SENTRY_DSN` 環境変数を読む。変数が空なら、SDK は何も送信しない。
- 計装は OpenTelemetry で行い、Sentry の OTLP Integration（`config.otlp.enabled` と `config.otlp.setup_otlp_traces_exporter`）で送る。OTLP の送信先は DSN から自動で決まる。
- OTLP Integration は Sentry SDK 自身のトレーシングと併用しない。`traces_sample_rate` は設定しない。
- RubyLLM 2.0.0 に対応した既製の OpenTelemetry 計装はない。このアプリは RubyLLM の計装イベントから OpenTelemetry のスパンを作る。
  - `ruby_llm-opentelemetry` 0.1.0 は中身のない予告版である。
  - `opentelemetry-instrumentation-ruby_llm` 0.7.1 は、RubyLLM 2.0.0 でチャットの呼び出しを `NoMethodError` で失敗させる。警告なしでインストールされるため、導入しない。
- Sentry の OTLP の取り込みは公開ベータである。スパンイベントは取り込み時に破棄される。
- DSN は送信先を示す値で、API キーほどの権限は持たないが、`.env` に置いてコミットしない。
- **プロンプトと応答の本文が Sentry に送られる。代表シナリオの入力に、実データや個人情報を入力しない。**
- Sentry が独自に推定するコストは、未知のモデル、バッチ料金、トークン課金以外の料金を対象としない。このアプリは RubyLLM が算出したコストを Sentry に送る。

## 疎通確認

```sh
bin/check_keys
```

Rails を起動せずに、プロバイダーごとに最小のチャットを 1 回送る。費用は 1 回あたり数トークン分。

```
OpenAI     OK    gpt-5-nano (in=14 out=9 tokens)
Anthropic  OK    claude-haiku-4-5 (in=15 out=4 tokens)
xAI        SKIP  XAI_API_KEY が未設定
Vertex AI  SKIP  GOOGLE_CLOUD_PROJECT が未設定
```

- `SKIP` は未設定を示すだけで失敗ではない。終了コードは、`NG` が 1 つでもあれば 1、それ以外は 0。
- Vertex AI の行が確認するのは「ADC・プロジェクト・API の有効化」まで。Deep Research のジョブを投入できるかは別で、上の「Deep Research のクォータ」を参照する。

`NG` の行には、エラーの種類とクラス名が出て、次の行に原因の候補が出る。デモの実行が失敗したときに画面に出るものと、同じ対応表を使う。

`NG` のときの原因:

| エラー | 主な原因 | 対処 |
|---|---|---|
| `UnauthorizedError` | キーの貼り間違い、失効。Vertex AI では ADC が未作成 | キーを再発行する。Vertex AI は `gcloud auth application-default login` |
| `BadRequestError`（xAI） | キーが無効 | キーを確認する |
| `RateLimitError`（OpenAI） | 残高不足（`insufficient_quota`） | Billing でチャージする |
| `PaymentRequiredError` | 残高不足 | 同上 |
| `ForbiddenError` | モデルへのアクセス権なし、API 未有効化、IAM ロール不足 | 各コンソールの権限と、Vertex AI は手順 2 を確認する |
| `ConfigurationError` | `.env` の変数名の誤り | `.env.example` と見比べる |

## キーの扱い

- `.env` はコミットしない。`git status` に `.env` が出ていないことを確認する。
- このアプリは利用額の上限を設けない方針のため、キーが漏えいした場合の請求に歯止めがない。漏えいが疑われたら、各コンソールでキーを即時に無効化して再発行する。
- アプリはローカルでのみ起動する。外部に公開する場合は、先に認証を入れる。

## このガイドの検証範囲

公式ドキュメントまたは実行で確認したもの:

- 各プロバイダーのキー発行ページ・Billing ページの URL（Anthropic と xAI は公式ドキュメント、OpenAI は API のエラーメッセージに記載された URL）
- RubyLLM が読む設定名と、Vertex AI の認証方式・`global` 制約・`googleauth` 依存（gem 2.0.0 のソース）
- Deep Research の前提条件、Preview 扱い、エージェント ID（Google Cloud のドキュメント）
- Sentry の Ruby SDK が `SENTRY_DSN` を読むこと、OTLP Integration の設定項目と `traces_sample_rate` を併用しない決まり、OTLP の取り込みの制限、コスト推定の対象外（Sentry のドキュメント）
- 既製の OpenTelemetry 計装 gem が 2 つとも使えないこと（gem の中身の確認と、RubyLLM 2.0.0 での実行）
- RubyLLM の計装イベントから作った OpenTelemetry のスパンを、Sentry が OTLP で受理すること。トレース画面で `gen_ai.invoke_agent`、`gen_ai.chat`、`http.client` の各スパンが親子関係つきで表示され、Agent Activity のタブと、エージェント用のスパン詳細（Agent Name、Input、Output）が出ること（2026-09-19 に実送信し、利用者が Sentry の画面で確認）
- アプリの計装で送った会話が、Sentry の Agents の Conversations に表示されること。2 ターンの会話が、会話 ID で 1 つにまとまり、LLM の呼び出し回数、トークン数、コスト、ツールの呼び出し（名前と引数）、発話と応答の本文が出ること（2026-09-19 に実アプリ経由で送信し、利用者が Sentry の画面で確認）
- アプリの画面から実行した代表シナリオのトレースが、Puma から fork したジョブのワーカーからも Sentry に届くこと。`http.client` のスパンが `POST responses` になり、OpenAI のモデルが Responses API で送られていること。実行の画面が組み立てた URL で、トレースと会話の画面が開けること（2026-09-22 に F1 を実行し、利用者が Sentry の画面で確認）
- `bin/check_keys` の SKIP 経路、無効なキーでの NG 経路、有効な認証情報での OK 経路（4 プロバイダーとも、2026-09-19 に実リクエストで確認）。上の出力例のトークン数は例示
- 失効した ADC では Vertex AI が `UnauthorizedError` になり、`gcloud auth application-default login` で解消すること（実リクエスト）
- Deep Research のリクエストを受けるサービスが `aiplatform.googleapis.com` であること（クォータ超過のエラーメッセージに記載）
- Deep Research のジョブの投入が、このプロジェクトではクォータの超過として拒否されること（実リクエスト）
- RubyLLM 2.0.0 が Rails 8.1.3.1 / Ruby 4.0.6 で起動すること

確認できていないもの:

- 各コンソールのログイン後の画面遷移（ボタン名やメニュー位置）。ログインが必要なため未確認。
- Deep Research のクォータの上限値と、引き上げの申請が通るかどうか。
- Sentry が表示するコストが、RubyLLM が算出して送った値か、Sentry 自身の推定かの区別。確認した会話ではどちらも 0.01 ドル未満で、表示から判別できなかった。バッチ料金のように両者が食い違う実行で確認する。
- OpenAI の Organization 本人確認が必要になるモデルの範囲。

## 参照

- [RubyLLM: Provider Setup](https://rubyllm.com/configuration-providers/)
- [RubyLLM: Hosted Research](https://rubyllm.com/hosted-research/)
- [RubyLLM: Provider API Coverage](https://rubyllm.com/provider-coverage/)
- [Claude API overview](https://platform.claude.com/docs/en/api/overview)
- [xAI: Getting started](https://docs.x.ai/docs/tutorial)
- [Google Cloud: Use Deep Research](https://docs.cloud.google.com/gemini-enterprise-agent-platform/agents/use-deep-research)
- [OpenAI: Developer quickstart](https://developers.openai.com/api/docs/quickstart)
- [Sentry: OpenTelemetry (OTLP) for Rails](https://docs.sentry.io/platforms/ruby/guides/rails/integrations/otlp/)
- [Sentry: Direct OTLP Traces](https://docs.sentry.io/concepts/otlp/direct/traces/)
- [Sentry: Instrument Agents](https://docs.sentry.io/platforms/ruby/guides/rails/tracing/instrumentation/custom-instrumentation/ai-agents-module/)
