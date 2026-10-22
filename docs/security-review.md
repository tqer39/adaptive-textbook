# Pre-publication security review

[English](security-review.md) | [日本語](security-review.ja.md)

Before creating the PR on 2026-10-17, the current files and Git history intended for publication were reviewed.
This review is neither a penetration test nor a guarantee of complete security. It does not authorize enabling OAuth or sending requests to a real LLM.

## Secrets, personal information, and history

- Betterleaks 1.9.0 scanned all refs covering the 24 commits from the previous work with its default rules and found 0 secrets.
  validation=false, with redaction enabled. No real keys were sent to an external validation service.
- The real allowlisted email and Cloudflare account/D1 IDs were removed from tracked files and separated into ignored Dev configuration.
  .env/.dev.vars, .local-state, .wrangler, node_modules, and test-results are excluded from publication.
- The original working history is preserved in the old directory and the local prototype/caa-section branch; it will not be pushed.
  The PR organizes the final code on top of the existing main. New commits use a GitHub noreply author email.
- The initial commit on the existing main contains the previous author name/email. These are not secrets, but become visible when the repository is public.
  The remote main history has not been rewritten. There is no guarantee that no personal information will be published.
- DNS/iodef email addresses in the text are instructional examples; OAuth fixtures use invalid test values.

## Authentication and authorization boundaries

The production entry validates Google's signature, issuer, audience, nonce, exp, verified email, and a single-user allowlist.
A browser-supplied userId or a test header/env flag cannot select the authenticated identity. Missing real configuration stops operation.
state is single-use through a cookie and an atomic D1 claim/epoch, rejecting late callbacks after cancel/logout.
HTTPS Secure/HttpOnly/SameSite cookies, exact Origin, CSRF, and body-size limits are checked.
Private Dev serves every asset only after Worker authentication and delivers the textbook with no-store/CSP.
Google tokens are removed by a storage hook, but Better Auth session tokens remain in D1.
D1, backups, and the Cloudflare account still need protection.

## BYOK, logs, and generated content

AES-256-GCM uses a random 96-bit nonce, with owner/provider/revision/key version bound into the AAD.
The encryption key is a Secret separate from storage/the repository; the credential API returns metadata only.
Tests cover per-user DOs, CSRF, revision, idempotency, concurrency, and rejection of replay after deletion.
No paths were added that expose credentials through logs, URLs, localStorage, or exports. Provider error bodies are not returned either.
AI-generated JS/MDX/eval is not executed. Restricted Markdown is rendered through DOM textContent; HTML and links remain strings.
Generated proposals pass through a strict schema, fixed source IDs, and the user's explicit selection. Arbitrary URLs are not fetched.
Real key entry and transmission are unconditionally disabled in production. Test dependency injection cannot be activated from production.

## Budget and remaining limitations

Each user has a shared JPY 500 ledger across both providers, with advance reservations that include fixed costs, a safety margin, and upper-bound unit prices.
Requests are not sent before persistence is confirmed. Unknown reservations are not automatically released by cancellation, deletion, or a change of month. There is no retry/fallback.
Real billing paths are currently disabled because only test adapters are accepted.
This ledger is not a Cloudflare-wide billing cutoff. Shared free quotas, actual CPU use, exchange rates, costs, and abuse controls
need separate confirmation before a real connection; an operational guarantee of JPY 500 per month cannot be given.

The dependency audit found 0 runtime vulnerabilities and 5 high-severity findings across all dependencies. A development glob DoS in braces remains unresolved.
Execution uses fixed lint patterns, CI timeouts, contents-read-only permissions, and no Secrets. No audit exclusion or forced downgrade was applied.
See the [audit details](dependency-audit.md).

lint/typecheck/build, 33 unit tests, 32 server tests, and 28 Workers tests were run.
They include forged signatures, CSRF, separation between users, ciphertext tampering, restart, deletion, budget concurrency, and retention of unknown reservations.
Desktop/mobile tests in Chromium and Chrome also include XSS-string regressions. CI runs the same principal checks.
Real Google grants/cookie delivery, real LLM requests, physical Windows/Linux machines, backup recovery, and load testing have not been exercised.
The audit changes are also not being redeployed to the published Dev environment in this work.
