# Development dependency audit record

[English](dependency-audit.md) | [日本語](dependency-audit.ja.md)

Rechecked on 2026-10-10 on the CAA prototype branch `prototype/caa-section`.
`npm audit` covered all dependencies. No audit exclusions were configured.

## What the initial nine findings meant

The nine findings were not nine independent defects; they aggregated three root causes and their affected dependents.
All originated from the development-only `markdownlint-cli2@0.23.3` dependency.

- high: braces, micromatch, fast-glob, globby, markdownlint-cli2 (5 findings)
- moderate: smol-toml (1 finding)
- low: katex, micromark-extension-math, markdownlint (3 findings)

## Applying available fixes

Scoped overrides in `package.json` updated only the following two lint dependencies.
No direct dependencies were changed, and no audit severity was excluded.

- smol-toml: 1.8.0 → 1.9.1
- katex: 0.16.47 → 0.18.2

The same lockfile was reinstalled with `npm ci` for verification.
The updated TOML `parse` and KaTeX `renderToString` APIs were also checked.
The lesson renderer uses neither library.

### smol-toml (moderate)

Path: markdownlint-cli2 → smol-toml.
Synchronous parsing has quadratic CPU growth for inputs containing many ordinary TOML keys.
The fix is available in 1.9.0 and later. The issue affects the CLI's TOML configuration parsing.
Updating to 1.9.1 resolved it in this work.
The [official advisory](https://github.com/advisories/GHSA-r4xh-jqrq-34v2) was reviewed.

### KaTeX (low)

Path: markdownlint-cli2 → markdownlint → micromark-extension-math → katex.
In an environment already affected by prototype pollution, inherited options can change restrictions such as trust.
KaTeX itself does not cause the pollution.
The issue requires conditions such as rendering a malicious formula and inserting its HTML into a web page.
Updating to the fixed 0.18.2 resolved all three findings along this path.
The [official advisory](https://github.com/advisories/GHSA-238p-pmpm-9mq7) was reviewed.

## Remaining findings without an available fix (high)

Dependency paths:

```text
markdownlint-cli2@0.23.3
├─ micromatch@4.0.8 → braces@3.0.3
└─ globby@16.2.4 → fast-glob@3.3.3 → micromatch → braces
```

Extremely deeply nested brace patterns can exhaust the stack through recursion,
causing a denial of service that stops the lint Node.js process.
The [official advisory](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)
listed affected versions as `<=3.0.3` and patched versions as None.
The latest npm registry release was also 3.0.3, so a normal update could not resolve it.

npm audit counts five affected packages, including dependents, as high severity.
They share a single underlying braces defect.
The latest CLI, 0.23.3, also had this dependency.
The audit's suggested change to CLI 0.21.0 did not resolve it during the previous check and was not adopted.

At the time of this audit, lint input patterns were fixed to `README.md docs/*.md`.
For current documentation coverage, see the [documentation rules](rules/documentation.md) and `package.json`.
No path passed textbook content, user answers, localStorage, or HTTP requests into globs.
These dependencies were not included in the production bundle.
However, process termination remained a risk if future CLI arguments/configuration accepted external globs,
or when linting untrusted repository changes.
No configuration was added to ignore the audit based on an unsupported claim of safety.
The plan was to update after a fix was released or reconsider linter execution when introducing CI.

## Verification after the fixes

- `npm ci`: passed; lockfile reproducibility confirmed
- `mise run lint` / `npm run lint`: passed
- `npm run typecheck`: passed
- `npm test`: 5 unit tests passed
- `npm run test:browser`: 10 desktop/mobile tests passed in total
- `npm run build`: passed
- `npm audit`: 5 high findings; 0 moderate/low/critical; exit code 1
- `npm audit --omit=dev`: 0 findings; exit code 0

The fixed CAA lesson, history, and authentication scope were unchanged.
The local URL remained <http://127.0.0.1:5173/>.
No external push, PR, or publication was performed.

## After adding Workers dependencies (2026-10-11)

Wrangler 4.149.0, its matching Miniflare 5.20261006.1-alpha, esbuild 0.28.2, and jose were added.
The repeat audit found only the same five high markdownlint-related findings. The npm registry's latest braces remained 3.0.3.
These were not classified as new Workers/provider runtime vulnerabilities. No audit exclusions or forced downgrades were applied.
The installed workerd/esbuild worked in local tests. No additional global installations or permission changes were made.

## After adding the pinned Better Auth version (2026-10-11)

Better Auth 1.7.7 was added as a pinned dependency. npm audit found only the five known high markdownlint-related findings.
There were no new findings from Better Auth dependencies. No fix exclusions, forced downgrades, or global installs were applied.
Authentication nonce/signature guarantees were verified through explicit public-API checks and mock OAuth tests, not audit results alone.

## Re-audit before the public PR (2026-10-17)

npm ci --ignore-scripts reproduced the lockfile, and npm audit confirmed that the five high findings were confined to the same development-only paths.
npm audit --omit=dev reported zero findings. The latest braces was 3.0.3, and the official advisory still listed Patched versions: None.
The [official advisory](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm) was checked again.
CI used fixed patterns, a 15-minute timeout, contents read-only permission, and no repository Secrets.
Because CI executes untrusted PR code, real accounts and production settings continued to be excluded.
