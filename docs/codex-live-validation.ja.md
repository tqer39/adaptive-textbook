# Codex実接続の検証

[English](codex-live-validation.md) | [日本語](codex-live-validation.ja.md)

開発ハーネスを、既存のChatGPT契約で認証されたCodex App Serverへ接続する検証です。
教材アプリが利用者向けの翻訳・教材生成を提供するためのAPI接続とは別です。

## 契約と停止条件

[OpenAI公式の認証説明](https://learn.chatgpt.com/docs/auth)では、
ChatGPTログインは契約内利用、APIキーは従量課金の経路として区別されています。
この検証はChatGPT認証だけを許可し、APIキーを渡しません。
[利用枠と追加クレジットの説明](https://learn.chatgpt.com/docs/pricing)も確認します。

- 各モデルturnの送信前に`account/read`と`account/rateLimits/read`を確認する。
- 契約内の既知の残量を要求し、使用率80%以上、枠到達、追加クレジットあり、情報不足では送信しない。
- Fast／Ultrafastを継承せず、Standardで実行する。
- 購入、入金、追加クレジット消費の選択、獲得済み枠リセット、APIへの切替を自動実行しない。
- 操作数、修正巡数、処理時間を制限し、未知の送信結果を自動再送しない。

残量は共有アカウントの時点情報です。1turn分を予約する機能ではありません。
CLI 0.148.0のprotocolには、円建ての上限や「契約内枠だけを予約する」指定はありません。
課金額の絶対上限や、並行して別のチャットを使った場合の消費量を保証する機構ではありません。
追加費用が必要な状態では実行を保留し、利用者へ知らせます。

## 実モデルによる試験

`scripts/codex-live-smoke.py`は秘密を持たない一時Git作業場を作り、
日本語教材の自由記述回答に使う小さなGo採点関数を検証します。

1. Run Aで実モデルが実装し、固定の基本試験と独立した実モデルのレビューを通す。
2. driverがUnicode空白の処理を壊す、明示的な試験用の不具合を注入する。
3. Run Bで別の実モデルレビューが不具合を検出し、修正担当へ指摘を渡す。
4. 修正、基本試験、再レビューを自動で実行する。
5. driverが保持するUnicodeの境界試験を別の作業コピーで実行し、前の失敗と修正後の成功を照合する。

レビュー担当に`revise`を指示しません。注入後に不具合を見逃した場合はsmokeを失敗とします。
基本試験だけでは見落とす受入条件を、独立レビューが見つけられるかを確認します。
人工的な小課題の結果であり、実製品の任意の課題への対応やレビュー精度全般の証明ではありません。

## 再現方法

Goの実行ファイル、native Codex、認証済みCODEX_HOME、モデルIDを明示します。
認証値は引数へ入れません。`model/list`で実際に提供されるモデルIDを確認してください。

```bash
GOCACHE="$PWD/.local-state/go-cache" go build -C harness \
  -o "$PWD/.local-state/textbook-harness" ./cmd/harness
python3 scripts/codex-live-smoke.py \
  --harness-binary "$PWD/.local-state/textbook-harness" \
  --codex-binary /absolute/path/native-codex \
  --codex-home /absolute/path/configured-codex-home \
  --model MODEL_ID \
  --go-binary /absolute/path/go \
  --output "$PWD/.local-state/codex-live"
```

出力先は新規のディレクトリを使います。既存の結果を上書きしません。
本番用の署名鍵・APIキー・学習履歴を検証フォルダへ置かないでください。

## 記録

実モデル推論前に、公式CLI 0.148.0経由で次のメタデータを確認しました。
メールアドレス、アカウントID、認証値、raw protocolは記録の対象外です。

- 認証方式: `chatgpt`、契約種別: `prolite`。
- 共有の週次利用枠: 使用率8%、追加クレジットなし、支出制御・枠到達なし。
- `model/list`の既定: `gpt-5.6-sol`。このCLIで取得した提供モデル一覧に基づいて選択する。

実行結果はモデルの最終出力、コードハッシュ、固定仕様ハッシュ、検証ログ、thread／turn IDと結び付けます。
CLI単体の接続確認やfake serverの試験と、実際の推論成功を区別します。

### 実接続で修正した差異

- `hooks`はイベント配列だけでなく、信頼状態を保持する`state`辞書も含む。
  `state`を配列で上書きするとthread作成が失敗するため、イベントと区別する回帰試験を追加した。
- CLI 0.148.0では`features.hooks=false`を起動時とthread設定の両方へ指定する。
  イベント配列を空にするだけでは、別の設定層の`hooks.json`を無効化できない。
  legacy通知も別に`notify=[]`で無効化する。
- `failed`・`interrupted`・結果不明を区別し、公式エラー種別とHTTP statusだけを保存する。
  `responseTooManyFailedAttempts`とHTTP 429を実接続で確認した。

Solでの試行では実装と独立レビューが合格し、故障注入後のレビューもUnicodeの不具合を検出した。
修正turnはHTTP 429で失敗し、保存済み履歴とコード未変更を読取確認した。
間隔を置いた別作業場でのSol再試行も429だったため、同じPro認証で提供されるTerraを選択した。
失敗したturnの自動再送や、APIキー・追加購入への切替は行っていない。

### 合格した実モデル試験

2026-10-22、Codex CLI 0.148.0、`gpt-5.6-terra`、Standard、既存の個人Pro認証で完走した。
途中で人が実装・レビュー・修正へ介入せず、driverとGoハーネスが次の順序を実行した。

| 対象 | 確認結果 |
| --- | --- |
| Run A | 実モデル実装 → 基本試験 → 独立レビューの`approve` |
| 故障注入 | Unicode空白の処理を壊し、固定境界試験が失敗することを確認 |
| Run B | 基本試験 → `revise` → 実モデル修正 → 基本試験 → 別threadの`approve` |
| 修正後 | 固定Unicode境界試験が合格、仕様・検証ファイルの不変を確認 |
| モデル | 5操作とも要求・解決モデルが一致、5つすべて別thread、turn状態`completed` |
| 状態照合 | `accepted`、`stale=false`、現在のコードと最終承認のhashが一致 |
| 所要時間 | 合格した2runの一連の試験で101.13秒。準備中の診断・失敗試行は含まない |

実行IDはRun Aが`c6bd6d684e9d60b0bec96937`、Run Bが`60d7ac4648a7e328d28cbd67`。
詳細はGit管理外の`.local-state/codex-live-20261022-terra2/report.json`と両runのSQLite台帳へ保存した。
最終読取でもChatGPT／`prolite`、週次使用率11%、追加クレジットなし、支出制御・枠到達なしだった。
使用率は共有アカウント全体のため、この試験だけの消費率としては扱わない。
追加契約、クレジット購入、APIキー課金は行っていない。

Goは最終コードで`mise run harness:check`が合格した（gofmt・go vet・race、76.003秒）。
Pythonの構文、準備だけの実行、既存出力先の拒否、固定試験の故障検出も確認した。

Terraの前試行はreviewの承認要求で停止したため、reviewのpolicyを`on-request`へ調整した。
`readOnly`、通信禁止、追加権限要求の拒否は維持している。
以後のHTTP 429なども自動で課金経路へ切り替えず停止する。モデルの自動切替や自動再試行は未実装。
