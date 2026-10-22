# ネイティブ最小アプリと開発ハーネス

[English](native-harness.md) | [日本語](native-harness.ja.md)

2026-10-22に着手したSwift／Go構成の最初の実装です。
既存のWeb試作は保持し、`apple/`と`harness/`に分離します。
教材サービスの実LLM送信、同期サーバー、新規契約、公開、署名鍵設定は今回の対象外です。

## 合格条件

- macOS／iOSで共有するSwiftUI画面とSwiftの教材・回答モデルを用意する。
- 固定の日本語教材を読み、理解問題に回答し、根拠付きの解説を読める。
- 回答をSQLiteへ保存し、再起動後も教材の版と結び付けて取得できる。
- 保存失敗を表示し、成功していない保存を成功と表示しない。
- Goハーネスで固定仕様、検証、独立レビュー、上限付き修正を実行する。
- SQLite台帳と実際の終了コード・ログ・コード識別子を保存し、停止・状態確認・再開を提供する。
- 改変された仕様、不正なレビュー、対象外のコードへの承認を受け入れない。
- 同一プロセス群の子孫を含む停止、失敗後の再開、同じ実行の競合を回帰テストで検証する。

## 配置

- `apple/`: Swift Package、SwiftUIアプリ、SQLite保存、iOSビルド経路、Swiftテスト。
- `harness/`: 追加Go依存を持たないローカルCLI、SQLite台帳、実行・レビューの制御。
- `.local-state/`: Git管理外のビルドキャッシュと試験用データ。

Goはリポジトリの`mise.toml`で1.27.1に固定します。macOS／Linuxでは既存のsqlite3 CLIを使います。
SwiftUIとXcodeの検証にはmacOSが必要です。Windows上のハーネス動作は初期版の対象外です。
他のリポジトリや個人dotfilesのパッケージ設定は変更しません。

## 開発時の実行

```bash
mise run harness:check
mise run apple:test
mise run apple:build
```

詳しい起動・タスク仕様は[Apple側の手順](../apple/README.ja.md)と
[ハーネス側の手順](../harness/README.ja.md)を参照してください。
[ツールとSaaSの比較](harness-tools.ja.md)には採用条件と未検証事項を記録します。

## 再利用する開発スキル

この作業ツリーの`.agents/skills/`に、リポジトリ専用スキルを4つ配置しています。
Codexが作業内容に応じて選択でき、次の名前を明示して呼び出すこともできます。自動選択は有効です。
選んだスキルと、その作業に必要な参照先だけを読みます。既存のガイド・スクリプト・ソース上の契約を正本とします。

| 呼び出し | 使用する場面 |
| --- | --- |
| [$harness-development](../.agents/skills/harness-development/SKILL.md) | 上限付きの実装・検証・レビュー・修正ループの実行や保守、中断後の回復。 |
| [$independent-review](../.agents/skills/independent-review/SKILL.md) | 変更の独立レビュー、報告された不具合の回帰テストによる再現。 |
| [$apple-native-validation](../.agents/skills/apple-native-validation/SKILL.md) | Swift／SwiftUIの変更、ネイティブビルド、macOS／iOSの実動作の検証。 |
| [$search-performance-validation](../.agents/skills/search-performance-validation/SKILL.md) | 記事読取・全文検索の正しさと、書き込み競合時の検索時間の検証。 |

呼び出し例：`$search-performance-validation を使って、変更後の検索実装を検証して`。
各スキルは既存手順を参照し、新しい課金や実行権限を与えるものではありません。
スキル・ドキュメントだけの更新には文書検証を行い、ネイティブビルド・実モデル呼び出し・大規模ベンチマークは、影響する動作や依頼された検証で必要な場合だけ選択します。
Codexはスキルの変更を自動検出します。表示されない場合はCodexを再起動してください。[公式スキル文書](https://learn.chatgpt.com/docs/build-skills)も参照してください。

## 境界

コマンドを実行できるローカルハーネスであり、任意の第三者タスクを安全に実行するOSサンドボックスではありません。
信頼済みのタスクだけを入力し、実行範囲・環境・ログ上限を制限します。
worktreeの分離は編集競合対策であり、資格情報の隔離とは区別します。
実製品のキー・学習履歴・署名／公開資格情報を開発担当へ渡さない構成を維持します。

Codexの接続コードと実モデル推論の成功は別に検証します。
ローカルのプロトコル試験を、実アカウントの利用可否や生成品質の検証結果として扱いません。
教材アプリの生成予算と、開発用Codexの契約内利用枠を混同しません。

## 検証記録

2026-10-22、Mac Studio M4 Max・64GB、Go 1.27.1、Swift 6.3.3、Xcode 26.6で検証しました。

- `mise run harness:check`: 整形・go vet・競合検出付きGoテストが成功。
- `mise run apple:test`: Swiftの11テストが警告なしで成功。
- macOSのreleaseアプリとiOS Simulator用アプリがビルド成功。iOSは署名なしでarm64／x86_64をコンパイル。
- macOSの実操作で、誤答の解説、正答の解説、回答2件の保存、再起動後の履歴保持を確認。
- iPhone 17 Pro／iOS 26.5 Simulatorの実操作で、教材、正答の解説、回答保存、履歴1件を確認。
- Go CLIの一時Git作業場で、checks→reviewの修正要求→repair→checks→approveを実行。
  修正1巡・証拠5件でacceptedになり、コード削除後のstale表示とresume拒否も確認。
  これはローカルfixtureの検証であり、モデルによる意味的レビューの評価ではありません。
- 導入済みCodex 0.148.0のschemaとadapter契約を照合。
  最小版の初回検証は空の専用HOMEでinitialize／account読取まで行い、推論は送信していません。
- 既存Web試作の型検査・ビルド、教材33件＋サーバー32件の試験が成功。
- `mise run lint`: ESLintと17文書のMarkdown検査が成功。

独立レビューで再現した日時の精度損失、正誤整数の32bit丸め、保存中の画面遷移、
古いコードへの合格表示、review回復時の証拠・時間・前後hash検査、作業範囲の排他を修正しました。
修正後の回帰試験と、別担当による再確認を行いました。

CIへGoのmacOS／Linux検証とAppleのビルド経路を追加しましたが、今回push・GitHub上での実行はしていません。
Linux実機、物理iPhone、署名・公証・App Sandbox、DB暗号化は未検証です。
続く[Codex実接続の検証](codex-live-validation.ja.md)で、実装・review・修正を実モデルへ接続しました。
既存Pro認証のTerraで5つの別threadと修正1巡が完走し、境界試験の不合格→合格を確認しました。
製品側の教材生成は引き続き未接続です。
ローカルランナーを強いOS隔離や、円／tokenの厳密な課金上限の完成形とは扱いません。

## RSS・ブックマーク・端末内翻訳への拡張

共有SwiftUIへ情報収集タブを追加しました。RSS／Atomを取得し、原文・ブックマーク・日本語訳を
別の`feed-library.sqlite`へ保存します。回答履歴のDBは保持します。
初期の11テストを維持し、拡張初期にはフィード・保存・非同期の競合を含む38テストの成功を確認しました。
MacではApple公式RSSの148記事、ブックマーク、日本語訳の生成・SQLiteへの保存を実操作で確認しました。
iPhone 17 ProのSimulatorでもRSS追加・記事への移動・ブックマーク一覧を確認しました。
Apple Translation自体の検証はMacで行い、Simulatorで翻訳成功とは判定しません。

実アプリへの初期適用では、自律的な合格まで到達していません。
大きい実装要求の通信量を保存ログと同じ1MiBに制限していたため、中断が発生しました。
通信と保存ログの上限を分離し、失敗理由を区別する回帰テストを追加しました。
最新のコンパイル診断をrepairへ直接渡す処理も追加し、古い失敗だけを直し続ける問題に対応しました。
長い試験出力の前半にある失敗行も、hash照合済みログから上限付きで渡します。
Swift 6の翻訳セッション分離は親担当が修正し、独立サブエージェントが再現した4件の不具合も修正しました。
実アプリでの自律ループの完走は、これらのローカル修正・試験と分けて検証します。
