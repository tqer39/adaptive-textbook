# Better Authと認証専用D1（ローカル統合）

[English](better-auth.md) | [日本語](better-auth.ja.md)

Better Auth 1.7.7をpackage.jsonで固定し、独自Google OAuth/sessionを置換しました。
認証はD1、LLMのBYOK暗号化保存・個人別500円予算はAccountVault Durable Objectです。
API Key pluginは使いません。Google tokenとLLM APIキーを同じ保管方式として扱いません。
サービス名/slugは未確定の差分を保持し、今回新しく確定していません。

初期アクセスは本人だけです。GOOGLE_ALLOWED_EMAILの1件を必須にし、
署名検証済みのverified emailをcallbackと既存sessionで照合します。
[本人限定Devの具体的な承認・入力項目](owner-only-setup.ja.md)を参照してください。

## 変更した認証境界

workers/better-auth.mjsがBetter AuthのGoogle開始/callback/session/sign-outを呼びます。
UIの状態/開始/中断/logout adapterはmetadataのみ返します。生のsession tokenやGoogle tokenは返しません。
実キー入力・変更のgateはfalse、実senderは未登録です。ヘッダーやenv flagでtest identityを選べません。
認証用D1/secret/Google設定/本人の許可emailが欠けるとauth-unconfigured、schema/DB障害時はauth-unavailableで停止します。
静的教材の読書は認証DBへアクセスせず、既存のlocalStorage履歴をクラウドへ同期しません。

Google設定はopenid emailのみ。Better Authのuser表に必要なemailを取り、profile scopeは要求しません。
表示名はLearner、imageはnullにし、Googleの名前/写真を保存しません。offline grant・追加scopeは要求しません。
accountLinkingとemail/password・直接idToken認証の入口は無効です。
Google providerのOAuth tokenをaccount.create/update.beforeで除去し、DBには保持しません。
account.encryptOAuthTokens=trueも設定しますが、ID tokenを含む非保存はhookとDB検証で確認します。
JavaScriptの一時コピーのzeroizeを約束しません。provider署名検証までtokenは一時的に必要です。

採用版のGoogle開始URLは標準のままではnonceを生成しませんでした。
公開plugin initでrequiresIdTokenNonceを結合し、公開verifyProviderIdTokenでRS256・issuer・audience・
iat/exp・nonce・verified emailを検証してからプロフィール処理へ進みます。vendor patchはありません。
不正署名・nonce/issuer/audience/期限・redirectをmock endpointで拒否する試験を用意しました。
Googleの実endpoint受理、実clientのscope同意は未検証です。

## D1とsession失効

D1表はuser/session/account/verification/rateLimitとapp_auth_browser/app_auth_attemptです。
後者はOAuthの暗号処理を置き換えず、browser cookie・CSRF・試行epoch・10分の期限だけを管理します。
stateはhashで記録し、callback前に原子的UPDATEで一回だけclaimします。
Better Authのstate/verifier/nonceは暗号化cookieへ保存し、D1に平文verifierを残しません。
OAuth state cookieだけでは再送を防げると扱わず、D1のclaimも必須にします。

sessionはBetter AuthのDB保存、固定1時間、自動延長なし、cookie cache無効です。
Better Authの標準session.tokenはDBに保存されるため、D1権限・backup・ログ保護は本番運用で確認します。
アプリのbrowser cookieは__Host-、Better Auth cookieは__Secure-で、
いずれもSecure/HttpOnly/SameSite=Lax/Path=/、cross-domain cookieは使いません。
D1はsession.appBrowser/appEpoch/appAttemptを持ち、client入力を許可しません。
中断/logout/再ログインはepochを進めてsessionを削除し、遅着callbackのsession作成・確定を拒否します。
作成直前のhookだけに依存せず、保護APIでもDB sessionと現在epochを再確認します。
DB障害時にcookieだけやメモリ状態へfallbackしません。毎回の失効確認ではcookie cacheを使いません。
logoutはこのアプリの失効で、Google全体のlogoutやgrant取り消しではありません。

verified user.idから `better-auth:<id>` のsubjectを作り、session.idを既存principalへ渡します。
AccountVault DOはsubject hashから決まり、メール・Googleプロフィール・client指定userIdを所有者にしません。
credential APIのsession別CSRF・所有者固定・版・不明予算保持は維持しています。
外部アカウント/実データが未作成なので、旧 `google:<sub>`や独自sessionの移行は実装しません。
アカウント削除/再作成と費用照合の運用は、この置換で完了した扱いにはしません。

## ローカル検証と実行

```bash
npm ci
npm run dev
npm run workers:local
npm run test:workers
```

workers:localは外部fetch・認証設定を読む処理を無効にしたMiniflare配信です。
実キー・Google接続は有効になりません。Ctrl+Cで停止します。
テストは一時D1・一時DO・Googleに通用しない署名鍵/ダミーsecretと、mock token/JWKS endpointだけを使います。
テスト終了時に一時DBを除去し、実Cloudflareアカウントや既存秘密を探索しません。

migrations/auth/0001_better_auth.sqlは固定版からローカル生成、0002_app_guard.sqlはアプリの安全境界です。
生成を再現する場合は `node scripts/auth-schema.mjs`（一時Miniflare D1のみ）を使います。
本番requestはmigrationを自動実行しません。wrangler.jsoncのAUTH_DBは実database_id未設定です。
旧LoginState DO/AUTH_SESSIONS/AUTH_STATE_KEYRINGは不要になりました。

検証：mise run lint・typecheck・frontend/Workers build、frontend33件・server32件・Workers24件が成功。
Chromium82件・インストール済みChrome82件も成功しました。320px/390px/1440pxの既存QAを含みます。
一時Workers配信で390px/1440pxの実キー無効・auth/session 503を確認し、画像を取得後に停止しました。
本番CPU・Google受理・Cookie配送・料金は未検証です。

## 実環境へ進む最小手順

1. 保留中の名称/公開先が確定した後、HTTPS APP_ORIGINと本人限定Devのアクセス保護を確認する。
2. 本人がGoogle Web client/test usersを登録する。redirectはAPP_ORIGIN＋/api/auth/callback/google。
   設定するのはGOOGLE_CLIENT_IDとGOOGLE_CLIENT_SECRET。必要scopeはopenid email。
3. 本人承認後に認証用D1 AUTH_DBとmigration、AccountVault DO bindingを環境別に準備する。
   BETTER_AUTH_SECRETとBYOK_ENCRYPTION_KEYRINGを別々に安全に設定し、backup/rotationを確認する。
4. 本人限定Devで実認証・cookie・中断/logout/失効・保存/復旧を確認してから実キー入力gateをレビューする。
5. 個人別500円のDB/基盤費とAI費上界・送信条件を確認し、別途承認された小さい実API試験へ進む。

秘密をchat/repo/logへ貼りません。OAuth登録・実grant・実秘密設定・クラウド作成・
購入・push/PR/deploy・実Google/LLM送信は今回行っていません。

## 実環境で残る確認

Mac StudioのMiniflare試験は本番のCPU/遅延/料金保証ではありません。
Googleの署名検証・state暗号化・D1/DOアクセスのCPUとcold startを、本人限定Devの実metricsで確認する必要があります。
ローカルbundleは約2.48MB、gzip約421KBです。
Workers FreeのCPU上限を満たしたとは扱いません。bundleサイズの確認もCPU試験の代わりにはなりません。
D1/DOの費用を個人の固定運用費へ含め、適用料金・無料枠・課金の上界を確認します。
本番のCookie配送、D1障害/backup/PITR、実課金、Windows/Linux実機は未検証です。

公式資料（2026-10-11確認）：

- [Better Auth Google](https://better-auth.com/docs/authentication/google)
- [DBとD1 migration](https://better-auth.com/docs/concepts/database)
- [Session失効とcookie cache](https://better-auth.com/docs/concepts/session-management)
- [公開plugin API](https://better-auth.com/docs/concepts/plugins)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
