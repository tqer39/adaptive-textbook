# Mac Chrome の初回タイムアウト調査

[English](browser-timeout-investigation.md) | [日本語](browser-timeout-investigation.ja.md)

## 結論

初回 2 件の原因は未特定です。直列通過を原因解消とは扱いません。
最新版 v1.5（4852a0a）では、初回と同じ 2 worker の反復でも再現しませんでした。
アプリの race や runner の資源不足を示す証拠は得られておらず、アプリコードは変更していません。

テスト画像の共有出力先は実際に見つかったため、テストごとの保存先へ修正しました。
ただし、その衝突が初回 timeout の原因だったとは断定しません。
worker を 1 に固定する根拠はないため、通常 Chromium・インストール済み Chrome とも 2 に明示固定します。
30 秒の test timeout と retry なしは維持し、失敗時 trace を保存します。

## 初回ログで確認できること

- desktop の旧回答保持・運用例テスト
  - 名前：`new predictions, applications and old answers survive the version update`
  - 回答・旧履歴保持・3 件の結果表示の assertion は通過済み。
  - applications 画面の `page.screenshot({ fullPage: true })` で 30 秒 timeout。
  - ログは fonts loaded まで進み、その後の画像取得が完了していません。
- mobile の用語説明開閉テスト
  - 名前：`term help preserves reading position, context and focus without scoring`
  - Back → Forward 後、閉じるボタンの locator が一度解決された後に DOM から外れました。
  - locator の再試行が完了せず、30 秒 timeout。
  - 当時の page snapshot は説明画面がなく、読書画面と再開ボタンが表示されていました。

初回は trace と継続的な CPU/メモリ計測を採取していません。
開発途中の厳密な source snapshot も未採取で、現在の反復結果だけでは当時の DOM 変化の理由を識別できません。
当時の raw output はチャットの実行ログが根拠です。古い test-results は後の実行で置換されています。

## 再現試験

すべてユーザーの Chrome profile へ接続せず、Playwright 所有の新しい context で実施しました。
閲覧中の tmux サーバー・教材データ・ユーザーの localStorage は変更していません。

- 修正前の保存先のまま、該当 2 ケース × PC/スマホ × 10 回、2 worker：40 件成功。
  - retry・skip・flaky は 0。21.2 秒、各ケース 576–1042ms。
  - 全 40 trace を取得。失敗した操作なし。
  - console error は favicon.ico の 404 のみ。アプリの例外は観測されていません。
- 保存先の分離後、同じケース × PC/スマホ × 5 回、2 worker：20 件成功、10.6 秒。
- 保存先の分離後、Chrome の全 28 件、2 worker：成功、7.4 秒。
- 通常 Chromium の全 28 件、2 worker：成功、6.1 秒。
- lint・typecheck：成功。

再現試験の JSON / trace / log は端末の一時領域に保存しています。
`/tmp/caa-timeout-parallel.*`、`/tmp/caa-timeout-parallel/`、
`/tmp/caa-timeout-isolated.*`、`/tmp/caa-timeout-isolated/` が該当します。
一時領域のため長期保存は保証しません。

## 仮説の確認

### storage と port

各テストは標準の page fixture を使い、BrowserContext はテストごとに独立しています。
共有 storageState、persistent profile、グローバル page fixture はありません。
[Playwright の context 分離](https://playwright.dev/docs/browser-contexts) と一致する構成です。

localhost:5173 は静的教材と Vite 配信を共有するだけで、学習履歴を保存する server API はありません。
既存 server を再利用し、同じ port の server を二重起動する操作もありません。
アプリ内の回答表示 Map と dialog Map はブラウザ側にあり、context 間で共有しません。

### 画像の保存先

旧実装の term-help.png は PC/スマホ project が同じファイルへ書きました。
ほかの画像も repeat/retry や異なる runner を並行実行すると同じファイルへ書く構成でした。
すべて `testInfo.outputPath()` に変更し、test/project/repeat/retry ごとに保存先を分離しました。
通常 Chromium と Chrome の outputDir も別にしています。
[API](https://playwright.dev/docs/api/class-testinfo#test-info-output-path)
を使用します。

初回の desktop applications と mobile 用語の失敗位置は異なり、
このファイル衝突で両方を説明できる証拠はありません。これは既知のテスト基盤改善です。

### 処理負荷と worker

端末は 64GiB RAM・16 logical CPU。再現試験時に読み取りで資源情報を確認しました。
これは初回の資源不足を否定する計測ではなく、初回の CPU/メモリ推移は不明です。
現在の 2 worker 反復は短時間で通過し、worker を 1 に制限する根拠はありません。

2 worker は元の実行条件を保ち、将来テストファイルが増えても同時 browser 数を無制限に増やさない上限です。
[worker の動作](https://playwright.dev/docs/test-parallel) に従い、timeout 延長や retry で失敗を隠していません。

## 次に再発した場合

`playwright.chrome.config.ts` で再現可能な設定を保存しました。
失敗時の trace、DOM snapshot、navigation/console、画像取得 API の状態から、
画面の再生成・履歴 traversal・画像取得停止を識別します。
資源不足を疑う場合は、その再発時の CPU/メモリを同時記録して判断します。
現段階では原因未特定の観測事項として残し、解消済みとはしません。
