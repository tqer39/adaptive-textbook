# Better Auth and an authentication-only D1 database (local integration)

[English](better-auth.md) | [日本語](better-auth.ja.md)

Better Auth 1.7.7 is pinned in package.json and replaces the custom Google OAuth/session implementation.
Authentication uses D1; encrypted LLM BYOK storage and the per-person ¥500 budget use the AccountVault Durable Object.
The API Key plugin is not used. Google tokens and LLM API keys are not treated as having the same storage requirements.
Pending changes to the service name/slug have been preserved; this work did not finalize them.

Initial access is restricted to the owner. Exactly one GOOGLE_ALLOWED_EMAIL is required,
and the signature-verified, verified email is checked in both callbacks and existing sessions.
See the [specific approvals and inputs for owner-only Dev](owner-only-setup.md).

## Updated authentication boundaries

workers/better-auth.mjs invokes Better Auth for Google sign-in initiation, callbacks, sessions, and sign-out.
The UI adapters for status, initiation, cancellation, and logout return metadata only, never raw session or Google tokens.
The real-key entry/change gate is false, and no live sender is registered. Headers and environment flags cannot select a test identity.
Missing authentication D1/secret/Google settings/owner allowlisted email stops authentication with auth-unconfigured;
schema or database failures stop it with auth-unavailable.
Reading static lessons does not access the authentication database, and existing localStorage history is not synced to the cloud.

Google is configured for openid email only. The email required by Better Auth's user table is obtained without requesting the profile scope.
The display name is Learner and image is null; Google's name and photo are not stored. No offline grant or additional scopes are requested.
Account linking, email/password authentication, and direct idToken authentication entry points are disabled.
Google provider OAuth tokens are removed by account.create/update.before and are not retained in the database.
account.encryptOAuthTokens=true is also set, but non-retention, including ID tokens, is checked through hooks and database inspection.
Immediate zeroization of temporary JavaScript copies is not promised. Tokens are temporarily needed for provider signature verification.

The adopted version's default Google authorization URL did not generate a nonce.
A public plugin init adds requiresIdTokenNonce, and the public verifyProviderIdToken verifies RS256, issuer, audience,
iat/exp, nonce, and verified email before profile processing. There is no vendor patch.
Tests reject invalid signatures, nonce/issuer/audience/expiry, and redirects through mock endpoints.
Acceptance by Google's live endpoints and scope consent for the real client remain unverified.

## D1 and session revocation

D1 tables are user/session/account/verification/rateLimit and app_auth_browser/app_auth_attempt.
The latter do not replace OAuth cryptography; they manage only the browser cookie, CSRF, attempt epoch, and 10-minute expiry.
State is recorded as a hash and claimed exactly once with an atomic UPDATE before the callback.
Better Auth state/verifier/nonce are stored in an encrypted cookie; no plaintext verifier remains in D1.
The OAuth state cookie alone is not considered replay protection; the D1 claim is also required.

Sessions are stored in Better Auth's database, last a fixed one hour, do not automatically extend, and have cookie caching disabled.
Better Auth's standard session.token is stored in the database, so D1 permissions, backups, and log protection need production review.
Application browser cookies use `__Host-`; Better Auth cookies use `__Secure-`.
Both use Secure/HttpOnly/SameSite=Lax/Path=/; cross-domain cookies are not used.
D1 stores session.appBrowser/appEpoch/appAttempt, with no client-supplied values allowed.
Cancellation, logout, and re-login advance the epoch and delete sessions, rejecting session creation and finalization by late callbacks.
Protected APIs recheck both the database session and current epoch, rather than relying solely on the hook before creation.
Database failures do not fall back to cookies alone or in-memory state. Cookie caching is not used for per-request revocation checks.
Logout revokes this application's session; it does not log out of Google globally or revoke the Google grant.

A `better-auth:<id>` subject is derived from verified user.id, and session.id is passed to the existing principal.
The AccountVault DO is selected from the subject hash, not an email, Google profile, or client-supplied userId.
Per-session CSRF, fixed ownership, revisions, and retained reservations for unknown costs in credential APIs are preserved.
Because no external accounts or real data have been created, migration from the old `google:<sub>` or custom sessions is not implemented.
Account deletion/recreation and cost-reconciliation operations are not considered complete through this replacement.

## Local verification and execution

```bash
npm ci
npm run dev
npm run workers:local
npm run test:workers
```

workers:local serves through Miniflare with external fetches and authentication-setting reads disabled.
It does not enable real keys or Google connections. Stop it with Ctrl+C.
Tests use only temporary D1/DO instances, signing keys/dummy secrets that cannot authenticate with Google, and mock token/JWKS endpoints.
Temporary databases are removed after tests; real Cloudflare accounts and existing secrets are not searched.

migrations/auth/0001_better_auth.sql was generated locally from the pinned version; 0002_app_guard.sql defines application safety boundaries.
To reproduce generation, use `node scripts/auth-schema.mjs` (temporary Miniflare D1 only).
Production requests do not run migrations automatically. AUTH_DB in wrangler.jsonc has no real database_id configured.
The old LoginState DO/AUTH_SESSIONS/AUTH_STATE_KEYRING are no longer needed.

Verification succeeded for mise run lint, typecheck, frontend/Workers builds, 33 frontend tests, 32 server tests, and 24 Workers tests.
All 82 Chromium tests and 82 installed-Chrome tests also passed, including existing QA at 320px/390px/1440px.
Temporary Workers serving confirmed disabled real keys and auth/session 503 at 390px/1440px; screenshots were taken and the server stopped.
Production CPU, Google acceptance, cookie delivery, and charges remain unverified.

## Minimum steps toward a live environment

1. After the pending name/publication destination is finalized, confirm HTTPS APP_ORIGIN and owner-only Dev access protection.
2. The owner registers a Google Web client/test users. The redirect is APP_ORIGIN plus /api/auth/callback/google.
   Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET. Required scopes are openid email.
3. With owner approval, provision authentication D1 AUTH_DB/migrations and the AccountVault DO binding separately for each environment.
   Set BETTER_AUTH_SECRET and BYOK_ENCRYPTION_KEYRING securely and separately, and verify backups/rotation.
4. Verify real authentication, cookies, cancellation/logout/revocation, and storage/recovery in owner-only Dev before reviewing the real-key entry gate.
5. Confirm upper bounds on per-person database/infrastructure and AI costs within ¥500, plus sending conditions, before a separately approved small live API test.

Do not paste secrets into chat/repositories/logs. This work did not perform OAuth registration, real grants, real-secret configuration,
cloud resource creation, purchases, push/PR/deploy, or live Google/LLM requests.

## Remaining live-environment checks

Mac Studio Miniflare tests do not guarantee production CPU, latency, or costs.
Google signature verification, state encryption, D1/DO CPU usage, and cold starts need measurement in owner-only Dev.
The local bundle is approximately 2.48MB, or approximately 421KB gzipped.
Compliance with Workers Free CPU limits is not established; bundle-size checks do not replace CPU tests.
Include D1/DO costs in each person's fixed operating costs and confirm applicable prices, free allowances, and charge ceilings.
Production cookie delivery, D1 failures/backups/PITR, real billing, and physical Windows/Linux machines remain unverified.

Official references (checked 2026-10-11):

- [Better Auth Google](https://better-auth.com/docs/authentication/google)
- [Database and D1 migrations](https://better-auth.com/docs/concepts/database)
- [Session revocation and cookie caching](https://better-auth.com/docs/concepts/session-management)
- [Public plugin API](https://better-auth.com/docs/concepts/plugins)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
