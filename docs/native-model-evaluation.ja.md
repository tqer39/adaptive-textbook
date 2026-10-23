# 固定したネイティブ製品コードのモデル評価

[English](native-model-evaluation.md) | [日本語](native-model-evaluation.ja.md)

[Issue #6](https://github.com/tqer39/adaptive-textbook/issues/6)に対する最初の製品コード評価ケースです。
小さな[実接続スモークテスト](codex-live-validation.ja.md)を補完します。
既知の不具合1件では代表的なモデル品質やコンテキスト効率を証明できないため、Issueは未完了です。

## ケースと固定した判定基準

[ケース入力](../harness/evaluations/native-unsubscribe/protocol.json)は、ソースcommit
`fe1ce0d4e1034643606eaad4b725421ee045aab4`とハッシュ付きの不具合注入パッチを固定します。
パッチは`FeedReaderModel.remove(_:)`から、ローカルの記事・検索結果のスナップショットを調停する処理を取り除きます。
別接続が購読を先に削除した場合、後続の削除結果には新たに削除した記事IDが含まれないことがあります。
その後の再読込に失敗しても、保持対象でない古い記事・選択状態は消え、保持したブックマークと翻訳は利用できる必要があります。

受け入れ条件、既存の全Swiftテスト、Coreの削除結果の動作を固定しています。
修復時に編集できるのは`apple/Sources/TextbookUI/FeedReaderModel.swift`のみで、検出レビューは読み取り専用です。
判定には、空の削除結果・ブックマーク保持の境界を含む既存のSwiftテスト全体を使います。
元の修復実行では、修復前にこの2テストで計8アサーションが失敗し、修復後に107件すべてとネイティブbundleの回帰検証が成功しました。
テストのアサーションは変更していません。ネイティブUI・実機・署名の検証ではありません。

## 2026-10-23の観測

元の3試行の全4モデルturnは`gpt-5.6-sol`、OpenAI、Standard（`default`）を使用し、修復とレビューは別実行です。
各turn前のPro限定チェックは`prolite`を記録し、基準・修復・再レビュー前の共有週次使用率は70%、参照範囲を絞ったturn前は71%、追加クレジットはありませんでした。
共有使用率の差分を、この実験だけの消費とは扱いません。
既存の[利用枠・停止条件](codex-live-validation.ja.md#契約と停止条件)を維持しています。

| 試行 | 結果 | 所要時間 | 累積入力 | 入力に含まれるキャッシュ分 | 出力 |
| --- | --- | --- | --- | --- | --- |
| 基準のソースレビュー | 注入した不具合を検出、`revise` | 62.830 s | 320,381 | 265,984 | 3,509 |
| 参照箇所を絞ったソースレビュー | 同じ不具合を検出、`revise` | 57.120 s | 245,820 | 200,064 | 3,564 |
| 修復と独立した再レビュー | 固定テストを復旧、`approve` | 166.759 s | 621,629 | 522,624 | 7,338 |

検出の2試行はソースハッシュが同一です。
`0f704e6940693dd2045d2ab28eb810f7fb7070085a381e25a0ea8cc0b973be74`
参照箇所を絞ったタスクは、広い読込の前にシンボル検索と狭いソース範囲の参照を指定します。受け入れ条件・モデル・checks・予算は同じです。
両試行とも注入した1件を検出しました。他の不具合の見逃しは測っていません。
参照方法の変更は基準の読込を観測した後に選んだもので、各条件1回のみです。
記録された入力は約23%少なく、出力は少し増えました。
この探索的な比較は、因果関係・一般的な削減効果・請求金額・モデル順位を証明しません。
どちらのレビューにもソースの重複読込が残っています。

トークンカウンターは元の試行の別々の4/4 turnをカバーしています。キャッシュ入力は入力の内数であり、入力に加算する別のトークン数ではありません。
ハーネスでの「同じソースハッシュで同じcheck indexを再実行」という定義では、重複checksは0です。
修復後に必要なchecksは異なるハッシュで実行するため、重複とは数えません。
修復は1サイクル・7操作で、失敗したcheck操作は1回でした。
166.759秒にはpreflight、失敗する全テスト、修復、成功するchecks、レビューを含みます。
最後のテストはビルドキャッシュが温まっており、短縮をプロンプト効率の証拠とは扱いません。

### 実行記録の監査で分かった修復評価の制約

元の作業ツリーのGit `HEAD`には正常な実装が残っていました。
修復役は`git diff`を実行してその解答を参照でき、最終的に同じ実装へ戻しました。
最終ソースハッシュは`4d49c34bd33d79510f6cf0dc8d14360139ab8e5896a4f5c3b817fa1d40ebaaf1`です。
固定テストの復旧とハーネスの修復動作は確認できますが、**解答を参照しない独立した修復の証拠ではありません**。
検出の2試行の記録には、Git履歴・差分・他のチェックアウトの参照やテスト実行はありませんでした。
修復後の別レビューは、渡されたハッシュ付きcheckログを参照しています。モデルによる追加テストは実行していません。
好ましい再実行結果に黙って置き換えず、この制約を保持します。

run ID、タスク・ソース・ログのハッシュ、正確なカウンター、操作情報と制約を
[公開結果レコード](../harness/evaluations/native-unsubscribe/results-2026-10-23.json)に保存しています。
生ログとSQLite台帳は非公開です。ハッシュと本レポートだけでは、参照できない生ログの真正性を独立に確認できません。
基準試行のスナップショットは修復前の記録であり、不具合入りソースの現在の合格判定ではありません。
検出試行は修復を禁止しているため`repair-budget-exhausted`で終了します。これは依頼した不具合検出の記録で、モデルの異常終了ではありません。

## Gitの基準に解答を含めない再現手順

[準備コマンド](../scripts/prepare-native-evaluation.py)は固定ソースを書き出し、不具合注入パッチを照合・適用した後、
不具合入りコードだけを唯一のcommitとする新しいリポジトリを作ります。
正常なcommitのcloneやremote設定は行いません。
管理対象のタスクテンプレートに引数を設定し、既存CLIの`freeze-task`または`prepare-product`を呼びます。
モデル起動、製品checks、認証値の読込、既存出力ディレクトリの上書きは行いません。
既存ハーネスへの入力準備であり、別のランナーではありません。

前提はPython 3.9以上、Git、固定commitが存在するローカルリポジトリ、ビルド済みGoハーネスです。
実際の修復checksには[Appleツールチェーン](../apple/README.ja.md)も必要です。
モデルを後で実行する前に、現在許可されたモデルと認証経路を選んでください。
出力はソースのチェックアウト外に非公開で保持し、試行ごとに新しい出力ディレクトリを使います。

```bash
mkdir -p .local-state
mise exec -- go build -C harness -o "$PWD/.local-state/textbook-harness" ./cmd/harness
python3 scripts/prepare-native-evaluation.py \
  --case native-unsubscribe \
  --variant focused \
  --output /absolute/path/new-evaluation \
  --harness-binary "$PWD/.local-state/textbook-harness" \
  --codex-binary /absolute/path/native-codex \
  --codex-home /absolute/path/configured-codex-home \
  --model AUTHORIZED_MODEL_ID
```

caseは`native-unsubscribe`（互換性を維持した既定値）と[回答履歴の初期化](history-model-evaluation.ja.md)です。
variantは`detection`・`focused`・`recovery`です。
caseごとに編集可能なソースファイルを宣言し、修復ではそれ以外のcontrolsを固定します。
修復は管理対象の`apple-tests`プロファイルとpreflightを使い、受け入れ条件を保持します。
絶対パス・モデル・手順によってtask hashは変わるため、過去の非公開タスクとの一致は期待しません。
`manifest.json`・`task.json`・評価用ソースを確認した後、既存CLIで明示的に実行します。

```bash
.local-state/textbook-harness run \
  -task /absolute/path/new-evaluation/task.json \
  -state /absolute/path/new-evaluation/state -allow-codex
.local-state/textbook-harness summary \
  -state /absolute/path/new-evaluation/state -run RUN_ID
```

モデル実行はサブスクリプションの利用枠を消費します。不明・失敗の結果を自動再実行せず、
[停止・復旧手順](../harness/README.ja.md)に従ってください。
全試行を残し、モデルの判定とは別にソース同一性・固定controls・ログ・トークン取得範囲・テスト結果を照合します。
実際の参照先も監査してください。Gitの隔離は、他のチェックアウトへのファイルシステムアクセスを遮断するものではありません。

改訂した`snapshot-only-v2`の準備は、2026-10-23にモデル呼出しなしで検証しました。
上記と同じ不具合入りソースハッシュを再現し、commitは不具合入りの1件のみで、正常な基準commitは解決できませんでした。
6件の準備回帰テストで3種類のvariant、caseごとの編集範囲、固定controls、既存出力の保存、パッチ・control改変の拒否を確認します。
ローカルと既存のLinux/macOS CIで、`mise run harness:check`から実CLIを使って実行します。

### 改訂手順での修復結果

同日の後続run `58d9edc365ad4292ed8ec154`で`snapshot-only-v2`を実行し、元の解答参照があった試行も保持しています。
固定した全テストは同じ2件・8アサーションで再び失敗し、1回の修復で107件すべてとbundle回帰検証が成功しました。
別の読み取り専用レビューが、最終ソースハッシュ
`2c31b42dfe253450089cbded98f04596dab9296138c9a3783fb66e169d572e9b`を変更せず承認しました。
最終状態は`accepted`、`stale=false`で、7操作・修復1サイクル・失敗check 1回・同一ソースの重複checks 0です。
所要時間は153.738秒で、2 turnの累積入力765,337、うちキャッシュ入力627,072、出力6,789を記録し、取得範囲は2/2です。
両turnは同じモデル・provider・Standard設定を使い、共有週次使用率73%、追加クレジットなしを確認しています。
これで全記録試行のカウンター取得範囲は6/6 turnです。

実行記録の監査では現在のソース・テスト、標準のskill・契約、渡したcheckログだけを参照しており、正常な基準オブジェクト・他のチェックアウト・履歴・ネットワーク取得は観測していません。
修復役の`git diff`は、不具合入りの初期commitとの比較です。
変更は許可したモデルファイルのみで、[修復パッチ](../harness/evaluations/native-unsubscribe/snapshot-v2-repair.patch)と操作ハッシュを結果レコードに保持しています。
このrunでは観測されたGit経由の解答参照を取り除けました。ただし、明示した条件と既存テストがある既知の不具合であり、未知の課題ではありません。
入力は元の修復より増えており、実行条件が変わった両者の時間・トークン差から効率の改善は結論しません。
別の[回答履歴初期化ケース](history-model-evaluation.ja.md)を加え、永続化境界も含む2ケースの計測を記録しています。
より広い確信度には対象を明示した将来の評価コーパスが必要で、この結果を任意の製品開発へ一般化しません。
Issue #6を閉じる前に、ハーネス関連PRのレビュー・統合が残っています。
