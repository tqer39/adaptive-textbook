# 開発ハーネスのツール選定

[English](harness-tools.md) | [日本語](harness-tools.ja.md)

2026-10-22に公式資料とContext7で確認した選定記録です。
既存実装の言語を選定条件にせず、SwiftのネイティブアプリとGoのサービスを開発するための構成を比較しました。
採用方針と実接続の確認は別です。契約、外部トレース送信、実モデル呼び出し、課金をこの調査では行っていません。

## 初期構成

開発の制御はローカルのGoランナー、永続状態はSQLiteに置きます。
エージェント実行は公式のCodex App Serverをstdioで接続する境界に分離します。
製品の教材生成用DB・予算・資格情報とは分けます。
現在のOpenAI Proを開発の主軸とし、Anthropicの追加契約や複数のSaaSを前提にしません。

各段階の入力、コードの識別子、検証結果、レビュー指摘、停止理由を保存します。
同じコードに対する検証証拠を確認してから次へ進み、結果不明の外部操作を無条件に再送しません。
App Serverのプロトコル試験にはfake executableを使い、実認証・モデル利用資格・利用枠の消費確認を分離します。
この試験だけで実サービスへの接続成功を主張しません。

## 比較と判断

| 候補 | 今回の判断 | 導入・再検討の条件 |
| --- | --- | --- |
| Codex App Server | 接続境界として採用。実通信は未確認 | CLI・認証・モデルを実接続前に確認 |
| Temporal | 初期は見送り | 複数ホストや長期の待機が増え、独自復旧の維持が負担になった場合 |
| Langfuse | 初期は見送り | 多数の実行・モデルの品質や失敗原因を横断比較する場合 |
| LangSmith | 初期は見送り | 評価・運用画面の共有効果が送信・契約・運用負担を上回る場合 |
| GitHub Actions | CIの再検証に使用 | 設定と実行予算を整え、GoとApple向けの検証を追加 |
| Kanary Relay | 任意の対話補助 | 複数GUIで設計・レビューを往復する作業が増えた場合 |

## 公式資料から確認した範囲

### Codex App Server

App Serverは会話履歴、承認、認証、agentイベントの統合用インターフェースです。
stdio上のJSON-RPCでthreadとturnを扱えます。
ランナー側では応答の最終状態、承認要求、プロセス終了、中断を区別し、成功扱いを決めます。
利用できる認証経路とモデルは実アカウントで未確認です。
Pro契約は、別途APIキーで呼び出す経路の課金を一括して許可するものとは扱いません。
[OpenAI公式のApp Server資料](https://learn.chatgpt.com/docs/app-server)を参照します。

### Temporal

Workflowは保存された履歴から状態を再構築するため、決定的な実行が必要です。
Activityの再試行やworker停止後の再実行に備え、外部操作には冪等性と結果照合が必要です。
Temporalを入れるだけで、LLM送信や決済などの重複した副作用が自動的になくなるわけではありません。
初期ランナーでも、実行前の記録、結果不明の保留、再送の判断を設けます。
[Temporal公式のTasks](https://docs.temporal.io/tasks)と
[Activityの定義](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-definition.mdx)を参照します。

### Langfuse・LangSmith

両方とも、モデルの呼び出しと評価を可視化する候補です。
LangSmithは特定のフレームワークだけに限定されず、複数のproviderや実装との連携を案内しています。
Langfuseの自己ホスト構成には、アプリ以外にPostgreSQL、ClickHouse、Redis、オブジェクト保存などの構成要素があります。
今回の単一ランナーに対して、それらを初期必須にはしません。
[Langfuseの自己ホスト資料](https://langfuse.com/self-hosting)と
[LangSmithのObservability資料](https://docs.langchain.com/langsmith/observability)を参照します。

導入時には、プロンプト・回答・コード・個人情報のどこまでを送信・保存するかを先に決めます。
ローカル記録でも本文や秘密を無条件に収集せず、タスクID、段階、時間、終了コード、成果物の参照を基本にします。
観測用SaaSを、権限制御や予算停止の代わりにはしません。

### GitHub Actions・Kanary Relay

GitHub-hosted runnerにはLinux、Windows、macOSがあり、CIでの独立再検証に使えます。
第三者actionは完全なcommit SHAで固定し、権限と秘密を必要な範囲に限定します。
個人Macを、信頼できないPRも実行する共有のself-hosted runnerとして登録する構成は初期案に含めません。
[GitHubのrunner資料](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners)と
[安全な利用の資料](https://docs.github.com/en/actions/reference/security/secure-use)を参照します。

Kanary Relayは、読み手が送信を選ぶGUI間の受け渡し補助として公式に説明されています。
停止・再開・予算・テスト証拠を管理する無人ランナーは、別途必要です。
[Kanaryの公式説明](https://kanary.to/blog/harness-of-harnesses)を参照します。

## pstackの位置付け

追加調査で、[Cursor公式Marketplaceのpstack](https://cursor.com/marketplace/cursor/pstack)を確認しました。
Cursorが配布・検証する開発用プラグイン／Agent Skills集で、Unixのスタックトレース用pstackとは別です。
[公開元のREADME](https://github.com/cursor/plugins/blob/main/pstack/README.md)では、
`/add-plugin pstack`、`/setup-pstack`、`/poteto-mode`を入口として案内しています。
単独の`/pstack`という組込コマンドは、確認した一次資料では見つかりませんでした。

`/interrogate`の独立した複数モデルによる反対レビュー、`/benchmark-checklist`の計測条件確認は今回の方針に合います。
これらは作業手順・判断基準であり、Goランナーの台帳・停止・権限・証拠保存の代替とは扱いません。
現在の別会話によるレビューを、異系列モデルを使う比較と同じ条件とは称しません。

[Grok Bot公式のSkills and routines](https://docs.x.ai/grok-bot/skills-routines-and-automations)は、
パッケージ化されたskillを追加し、デスクトップの`/`メニューから呼ぶ方式を説明しています。
本人の契約・カタログでpstackを追加できるか、ホスト間で同じskillがそのまま動くかは未確認です。
第三者のGrok Build向け移植を、Grok Botの公式対応と混同しません。
今回インストールや設定変更は行わず、必要なskillと対象版を確認してから評価する候補にします。

## 費用と未確認事項

SaaSの契約、利用枠、追加料金、macOSのCI実行費、自己ホストの基盤費は未見積です。
無料枠や既存契約だけで全処理を賄えるとは約束しません。
開発用Pro利用枠、開発用API費用、製品の教材生成費用は別に記録・管理します。
外部トレースや新しい有料基盤を有効にする前に、対象データ、保持条件、適用料金、予算を確認します。
