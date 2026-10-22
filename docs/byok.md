# Bring your own API key (BYOK)

[English](byok.md) | [日本語](byok.ja.md)

Each service user supplies their own OpenAI / Anthropic LLM keys.
The design does not assume a shared operator-owned LLM key stored as a Worker Secret.
Even with BYOK, the owner's AI costs count toward the ¥500 monthly personal operating budget; only hands-on exercise costs are separate.

## Locally implemented settings screen

Open the simulated settings screen from "My API key settings" in the header.
Live authentication/encrypted storage are unconfigured, and live API communication is disconnected, so the password field is disabled and empty.
There is no pasting, real-key registration, or display of successful live connections.
Registration is a fixed dummy operation; it does not require creating or retaining a key string.
Only the registration number, candidate model, and simulated verification status are shown.

- OpenAI / Anthropic support separate simulated registration, verification, replacement, deletion, and re-registration.
- Each has one candidate: gpt-6-luna / claude-haiku-5-5. Account availability is unverified.
- Simulated users A/B have separate state. This selector is not authentication.
- Select success/failure/waiting to try repeated-click prevention, cancellation, deletion during processing, and switching users.
- Failure preserves the original registration; replacement or model selection resets simulated verification.
- An old operation finishing after deletion/re-registration cannot overwrite the new state.
- Returning to the lesson, Escape, or browser Back/Forward closes the open screen and cancels processing.

Settings exist only in memory within the same tab. Reloading or opening another tab returns to an unregistered state.
Settings are not mixed into localStorage learning history, lesson versions, proposals, exports, or shared data.
API keys are never redisplayed, logged, or placed in URLs. Simulated operations make no external requests and incur no charges.
The existing server remains disconnected. Simulated verification does not mean a successful live API connection.

## Preparation required before accepting real keys

User-supplied LLM keys and the system's encryption secrets are separate.
BYOK makes the user the owner of the LLM key; it does not remove the need for encryption keys, authentication, or storage infrastructure.
The storage design follows the steps below. Workers encryption, user APIs, and budgets have been implemented locally.
See the [implementation and live-environment preparation](workers-byok.md).
Google login/session/logout and the live-API metadata screen are also implemented; production authentication and secret management remain unconfigured.

1. Identify the user from the server-authenticated subject; do not trust a client-supplied userId as ownership.
2. Check ownership on every registration/replacement/verification/deletion/model-selection API, with CSRF, size, and rate limits.
3. Encrypt LLM keys received over HTTPS on the server using authenticated encryption, binding user/provider/credential revision through AAD.
4. Design random nonces, encryption-key versions, rotation, and recovery. Keep encryption secrets separate from the database, repository, and browser.
5. Return only the credential reference, provider, status, and model to the browser; never return the full key, its suffix, or decrypted values.
6. Decrypt the same user's secret only immediately before a necessary request and pass it to the existing transport's secret argument. Do not retain it in module-wide variables.
7. Finalize replacement only after securely saving a new credential revision. Preserve the old revision on failure and invalidate old verification results.
8. Deletion invalidates active references, ciphertext, and per-user caches, checking revisions to avoid races with re-registration.

If encryption secrets are kept in Worker Secrets or another key-management system, they are distinct from users' LLM keys.
This work did not configure secrets, real permissions, or storage infrastructure.
Even ciphertext is not promised immediate erasure from backups/PITR; retention periods and deletion state after recovery need design.
Deleting a key inside the service does not revoke it at the provider. Users must also revoke it with the provider if needed.
Deletion/cancellation cannot guarantee cancellation of an already sent operation; reservations for unknown usage are retained.

## User isolation and existing boundaries

src/byok.ts is the simulated metadata state machine; src/byok-settings.ts handles display, disabled inputs, and simulated operations.
Testing simulated user isolation does not prove production authentication, authorization, or secret isolation.
The existing GenerationService ledger is a single local ledger shared by all providers.
It must not be exposed to multiple users unchanged. Workers adds a per-user DO, budget owner, and credential resolution.
Both providers' costs are combined within each person's budget, and unknown reservations are not automatically released across month boundaries.
Fixed operating costs such as Cloudflare are also included; choosing BYOK does not exclude AI costs.

transport({send, secret}) is already separate from credential storage; Workers implements per-user resolution after reservation.
Arbitrary destination URLs are not allowed. Existing fixed endpoints, no-retry behavior, usage checks, and source/schema validation are preserved.
Connection checks may also send data externally and incur charges; the method/provider/model/reservation must be shown for explicit selection.
Before enabling real-key handling, verify authentication, encryption, ownership checks, deletion/rotation, and secret-free audit logging.
A real path for token-counting charges/estimated upper bounds, yen-denominated cost ceilings, request-body previews,
source retrieval, and owner-controlled application of changes is also required.
Google authentication registration, live requests, initial deposits, and deploys require separate decisions;
they are not covered by permission to implement this simulated screen.
