# 公開前セキュリティ確認

[English](security-review.md) | [日本語](security-review.ja.md)

2026-10-17のPR作成前に、現在のファイルと公開予定のGit履歴を確認しました。
このレビューは侵入試験や完全な安全保証ではありません。OAuth/実LLM送信を有効にする承認ではありません。

## 秘密・個人情報・履歴

- Betterleaks 1.9.0の既定ルールで旧作業24コミットを全ref走査し、secret検出0件。
  validation=false、redact有効。実鍵を外部検証サービスへ送っていません。
- 実許可メール、Cloudflare account/D1 IDを追跡ファイルから除去し、ignoredのDev設定へ分離。
  .env/.dev.vars、.local-state、.wrangler、node_modules、test-resultsは公開対象外。
- 元の作業履歴は旧ディレクトリとローカルprototype/caa-sectionに保全し、pushしません。
  PRは既存main上へ最終コードを整理したもの。新規コミット作者はGitHub noreplyを使用します。
- 既存mainの初回コミットには従来の作者名/メールがあります。secretではありませんがpublic化で見える情報です。
  リモートmainの履歴改変は行っていません。個人情報を一切公開しないという保証はできません。
- 本文中のDNS/iodefメールはexampleの教材、OAuth fixtureは無効なテスト値です。

## 認証・権限境界

本番entryではGoogle署名/issuer/audience/nonce/exp/verified emailと単一allowlistを検証します。
ブラウザ指定userIdやtest用header/env flagで本人を選べません。実設定の欠落は停止します。
stateはcookieとD1の原子的claim/epochで一回限りにし、cancel/logout後の遅いcallbackを拒否します。
HTTPS Secure/HttpOnly/SameSite cookie、正確なOrigin、CSRF、本文上限を検証します。
private Devは全assetをWorker認証後に渡し、no-store/CSPで教材を配信します。
Googleトークンは保存hookで除去しますが、Better Auth session tokenはD1内に保持します。
D1/backup/Cloudflare accountの保護は引き続き必要です。

## BYOK・ログ・生成内容

AES-256-GCMとランダム96bit nonceを使用し、owner/provider/revision/key versionをAADで拘束します。
暗号鍵はstorage/repoと分離したSecret、credential APIはmetadataだけを返します。
利用者別DO・CSRF・revision・idempotency・競合/削除後replay拒否を試験しました。
ログ/URL/localStorage/exportへ資格情報を出す経路は追加していません。provider error bodyも返しません。
AI生成JS/MDX/evalは実行しません。制限MarkdownはDOM textContentで描画し、HTML/linkも文字列です。
生成提案はstrict schema・固定source ID・本人選択を通します。任意URLへfetchしません。
実キー入力と実送信はproductionで固定無効。テスト依存注入を本番から起動できません。

## 予算と残る制限

利用者ごとに両provider共通500円台帳を持ち、固定費/安全余裕/上限単価を含めて事前予約します。
永続化の確認前に送信せず、不明な予約は中断・削除・月跨ぎで自動解放しません。retry/fallbackなし。
現在はテスト用adapter以外を受け付けないため実課金経路は無効です。
この台帳はCloudflare全体の課金停止機能ではありません。共有無料枠・実CPU・為替・費用・abuse対策は
実接続前に別途確認が必要で、月500円の実運用保証はできません。

依存監査はruntime 0件、全依存high 5件です。bracesの開発用glob DoSが未修正で残っています。
固定lint pattern・CI timeout・contents readのみ・Secretなしで実行し、監査除外やforce downgradeはしていません。
[監査の詳細](dependency-audit.ja.md)を参照してください。

lint/typecheck/build、単体33件、server32件、Workers28件を実行しました。
署名偽造/CSRF/他者分離/暗号文改変/再起動/削除/予算競合・unknown保持を含みます。
ChromiumとChromeのdesktop/mobile試験はXSS文字列回帰も含みます。CIは同じ主要チェックを実行します。
実Google grant/cookie配送、実LLM送信、Windows/Linux実機、backup復旧、負荷試験は未実施です。
公開中Devへの監査変更の再deployも今回行いません。
