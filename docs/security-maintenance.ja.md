# セキュリティの継続保守

[English](security-maintenance.md) | [日本語](security-maintenance.ja.md)

## 実行環境と証明書のインシデント対応

2026-10-21の[Node.jsセキュリティ更新](https://nodejs.org/en/blog/vulnerability/october-2026-security-releases)は、eMudhra認証局の問題と実行環境の脆弱性に対処しています。
本リポジトリでは[Node.js 26.12.1](https://nodejs.org/en/blog/release/v26.12.1)と、X.509のセキュリティ修正を含む[Go 1.27.3](https://go.dev/doc/devel/release#go1.27.0)を選択しています。
Nodeの最低版は22.23.4、24.22.1、26.12.1で、新しいメジャー系列にはレビューが必要です。
これは確認日の最低版であり、将来の脆弱性への対処を保証するものではありません。

PHPの実行環境は宣言されていません。他のPHPサービスを使う場合は、[PHP公式の勧告](https://www.php.net/archive/2026.php)に沿った対応が別途必要です。
Nodeの開発ツール・バックエンドはNodeの証明書処理を使い、AppleのURLSessionはOSの信頼情報の更新に依存します。
Cloudflare Workersは基盤側が管理する実行環境です。ローカルのNodeを更新しただけでは、Workers、ブラウザー、OSのストア、Python/certifi、Git for Windows、起動済みプロセスまで修正済みとは確認できません。
稼働する各プロセスを棚卸しし、提供元の手順で実行環境と証明書を更新して再起動し、実際の版とTLSの動作を確認します。
信頼できなくなった証明書への接続を復旧するために、証明書検証を無効にしないでください。

## 継続する検査

```bash
mise install
mise run security:check
mise exec -- npm ci
mise run security:audit
mise exec -- npm audit signatures
mise run security:go
```

`security:check`は、実際に動くNodeの版、実行環境の固定値、インストール方針、ロックファイルの取得先・完全性、既定の形式で書かれたworkflowの参照先・権限を検査します。
npmの子プロセスがmiseのshimより前にある別の実行ファイルを使わないよう、このリポジトリではmiseのaggressive activationを有効にしています。
明示的なTLS検証の無効化、固定されていない外部Action、権限を持つPRトリガー、これらのworkflowの書込権限を拒否します。
リポジトリの方針を検査するものであり、完全なYAML解析器や、検査自体の悪意ある変更を防ぐサンドボックスではありません。

プロジェクトの`.npmrc`でインストール時のフックを抑止し、engineとTLSの検証を必須にします。
`npm run`で明示したコマンドは実行されます。ビルド・テストの依存コードは動くため、更新レビューとCI権限の制限も必要です。
ロックファイルの取得先はnpmレジストリ、完全性情報はSHA-512とし、npmが取得内容を照合します。
`npm audit signatures`は利用できるレジストリ署名・来歴を検証します。すべてのパッケージの作者や、悪意あるコードがないことを保証するものではありません。

PRとmainのCIでは、lint・テストを動かす前に、本番・開発の両方の依存を監査します。
日次の`security.yml`はUbuntuのみで監査と署名検証を繰り返し、版を固定したGo脆弱性スキャナーも実行します。
PRの依存レビューでは、新しく導入するlow以上の脆弱性も拒否し、PRコメントは投稿しません。
Goの検査は、対象OSで到達できる処理に関する検出を扱います。終了コード0でも、すべてのOSや未知の脆弱性まで安全とは証明できません。
日次workflowではmacOS/iOSアプリを再ビルドせず、デプロイ用Secretも使いません。

## Renovateと緊急更新

`renovate.json5`は[tqer39/renovate-config](https://github.com/tqer39/renovate-config)を継承します。
共有設定では通常リリースを14日間待機させ、公開日時を必須にし、インストールスクリプト・プラグインの実行を抑止してActionのdigestを固定します。
このリポジトリでは、脆弱性修正と一致するpackage ruleも含め、自動マージを明示的に無効にします。
既知の脆弱性修正PRは公開後の待機期間と実行スケジュールを外しますが、レビューとCI成功は必要です。
実行環境・認証局の問題では、パッケージ警告や自動PRがなくても手動更新が必要な場合があります。

設定はデフォルトブランチに入り、インストール済みAppがリポジトリへアクセスできて初めて有効になります。
新しいDependency Dashboardまたは実際の更新PRと、設定エラーの有無を確認します。Appとファイルが存在するだけではBotの成功は確認できません。
修正後はmainの新しいCIとDependabotの再検出を確認します。表示を消す目的で警告を却下しないでください。
緊急時は一次資料を読み、対象の実行環境・パッケージを更新し、上記検査と関連回帰を実行します。レビュー済みの修正をマージしてから、対象プロセスを再起動・再デプロイし、証拠を残します。
