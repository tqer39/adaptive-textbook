# 開発用依存の監査記録

2026-10-10、CAA 試作 branch `prototype/caa-section` で再確認しました。
全依存を対象に `npm audit` を実行しています。監査除外は設定していません。

## 最初の 9 件の意味

9 件は独立した 9 つの欠陥ではなく、根本原因 3 件と影響を受ける依存元の集計です。
すべて開発用の `markdownlint-cli2@0.23.3` を起点とします。

- high: braces、micromatch、fast-glob、globby、markdownlint-cli2（5 件）
- moderate: smol-toml（1 件）
- low: katex、micromark-extension-math、markdownlint（3 件）

## 修正版の適用

`package.json` の scoped overrides で、lint に属する以下の 2 依存だけを更新しました。
直接依存の変更や audit severity の除外はしていません。

- smol-toml: 1.8.0 → 1.9.1
- katex: 0.16.47 → 0.18.2

同じ lockfile を `npm ci` で再インストールして確認しました。
更新後の TOML `parse` と KaTeX `renderToString` の API 動作も確認しました。
教材の renderer はこの 2 ライブラリを使用していません。

### smol-toml（moderate）

経路: markdownlint-cli2 → smol-toml。
TOML の通常のキーを多数含む入力で同期解析の CPU 使用量が二次的に増加します。
修正版は 1.9.0 以降。CLI の TOML 設定解析に関係する問題です。
今回は 1.9.1 へ更新して解消しました。
[公式 advisory](https://github.com/advisories/GHSA-r4xh-jqrq-34v2)を確認しました。

### KaTeX（low）

経路: markdownlint-cli2 → markdownlint → micromark-extension-math → katex。
すでに prototype pollution が起きている環境で、継承された設定が
trust 制限などを変える問題です。KaTeX 自体が汚染を発生させるものではありません。
悪意ある数式を描画し、その HTML を web page に挿入する等の前提が必要です。
修正版 0.18.2 へ更新して、この経路の計 3 件を解消しました。
[公式 advisory](https://github.com/advisories/GHSA-238p-pmpm-9mq7)を確認しました。

## 修正版がない残件（high）

経路は次のとおりです。

```text
markdownlint-cli2@0.23.3
├─ micromatch@4.0.8 → braces@3.0.3
└─ globby@16.2.4 → fast-glob@3.3.3 → micromatch → braces
```

非常に深く入れ子にした brace パターンを与えると、再帰処理でスタックを使い切り
lint の Node.js プロセスが停止する DoS です。
[公式 advisory](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)では
影響範囲が `<=3.0.3`、修正版は None でした。
npm registry の最新版も 3.0.3 で、通常更新では解消できません。

npm audit は影響元を含む 5 パッケージを high と数えます。
根本原因は同じ braces の 1 欠陥です。
CLI 最新版 0.23.3 でもこの依存があります。
audit が提案する CLI 0.21.0 への変更は前回確認時に解消せず、採用していません。

現在の lint の入力パターンは固定の `README.md docs/*.md` です。
教科書本文、利用者回答、localStorage、HTTP リクエストを glob に渡す経路はありません。
production bundle にも含まれません。
一方、将来 CLI 引数・設定ファイルに外部由来の glob を入れる場合や、
信頼できない repository 変更を lint する場合のプロセス停止リスクは残ります。
今回、根拠なく安全と判断して監査を無視する設定は追加していません。
修正版の公開後に更新するか、将来の CI 導入時に linter の実行方式を検討します。

## 修正後の検証

- `npm ci`: 成功、lockfile の再現性を確認
- `mise run lint` / `npm run lint`: 成功
- `npm run typecheck`: 成功
- `npm test`: unit 5 件成功
- `npm run test:browser`: desktop/mobile 計 10 件成功
- `npm run build`: 成功
- `npm audit`: high 5 件、moderate/low/critical は 0、終了コード 1
- `npm audit --omit=dev`: 0 件、終了コード 0

CAA の固定教材・履歴・認証の範囲は変更していません。
ローカル URL は <http://127.0.0.1:5173/> のままです。
外部 push / PR / 公開は行っていません。

## Workers依存追加後（2026-10-11）

Wrangler 4.149.0 / 対応Miniflare 5.20261006.1-alpha / esbuild 0.28.2とjoseを追加しました。
再監査は同じmarkdownlint系のhigh 5件のみです。npm registryのbraces最新版は引き続き3.0.3でした。
新しいWorkers/provider runtimeの脆弱性として分類していません。監査除外・force downgradeはしていません。
インストール済みworkerd/esbuildはローカル試験で動作を確認しました。追加のglobal installや権限設定はありません。

## Better Auth固定版追加後（2026-10-11）

Better Auth 1.7.7を固定して追加しました。npm auditは既知のmarkdownlint系high 5件のみです。
Better Auth依存から新しい指摘はありません。修正除外・force downgrade・global installはしていません。
認証のnonce/署名保証は監査結果だけに頼らず、公開APIの明示検証とmock OAuth試験で確認しました。

## 公開PR前の再監査（2026-10-17）

npm ci --ignore-scriptsでlockfileを再現し、npm auditのhigh 5件が同じ開発用経路だけであることを確認しました。
npm audit --omit=devは0件です。braces最新版は3.0.3、公式advisoryもPatched versions: Noneのままです。
[公式advisory](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)を再確認しました。
CIは固定pattern・15分timeout・contents readのみで、repository Secretを使いません。
未信頼のPRコードを実行するため、実アカウントや本番設定をCIへ渡さない前提を維持します。
