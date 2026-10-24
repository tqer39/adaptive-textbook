# Cloud feed collection

[English](cloud-feed-collection.md) | [日本語](cloud-feed-collection.ja.md)

## Required behavior and current scope

On 2026-10-24 the owner required collection while the PC sleeps or is powered off, not only while a browser page is open (Issue #61).
The implementation uses the existing authenticated Cloudflare Worker and one account's `AccountVault` Durable Object.
It is disabled by default and has been tested locally; this does not establish a deployed, continuously running service.
No cloud deployment, billing change or real provider key was performed for this addition.

In **設定 → PCを閉じている間の収集**, explicitly start/update cloud subscriptions at 15, 30 or 60 minutes.
The operation unions this browser's subscriptions with the existing cloud subscriptions, with at most 50 distinct feeds and 16 KB of URL data.
Adding another local subscription requires **設定を更新**; it does not silently upload the new subscription.
**クラウド収集を停止** preserves pending results. Logging out does not stop an already configured collection job.
Unavailable authentication, an unconfigured runtime, conflicting settings, fetch failures and full storage are reported instead of claiming successful collection.

Cloud requests currently support only the exact publisher hosts `hnrss.org`, `zenn.dev` and `blog.cloudflare.com`, including redirects.
This is an explicit network boundary: Workers does not reuse the Node adapter's DNS pinning. Other feeds remain unsupported by cloud collection and produce an error.
The existing local Node endpoint still supports its wider public-HTTPS boundary.
The authenticated cloud `/api/feeds/fetch` route also supports RSS discovery/article HTML for these hosts, bounded to 20 requests per account per minute.
It does not forward browser cookies or authorization. Responses are limited to 2 MB with a 12-second deadline and three redirects; XML entities/DOCTYPE are rejected, while discovery HTML remains inert in the browser.

## Persistence and delivery

The Durable Object stores the subscription schedule, last success, failure count, retry deadline and pending RSS response snapshots.
An [alarm](https://developers.cloudflare.com/durable-objects/api/alarms/) wakes the object without browser traffic.
Cloudflare documents at-least-once alarm execution, so the collector persists a 60-second acquisition lease before network I/O and only commits a response against the same configuration revision and lease.
Each alarm acquires at most two due feeds; a recovery alarm is written in the same transaction before fetching.
Failures retry after 5, 10, 20, 40 and then 60 minutes. Pausing or changing configuration invalidates in-flight responses.
Unchanged response hashes do not create another pending snapshot; successful acquisition still advances the schedule.
This is periodic collection, not a guarantee that every post is seen before a publisher removes it from its feed.

Pending snapshots use bounded chunks and metadata in durable storage transactions, separate from credential/budget keys.
Limits are 100 responses, 20 MB of UTF-8 response content and 110 KB of metadata per account; capacity can be reached by any limit.
Reaching capacity stops scheduling without deleting old results. A successful browser acknowledgement frees space and resumes scheduling.
Stored responses are untrusted source data; full RSS parsing and text extraction happen in the browser.
The next visible, online browser downloads at most five pending responses per pass, commits each to IndexedDB, then acknowledges their IDs.
Pending work is checked after 15 seconds; otherwise status is checked after 60 seconds while the page is visible.
Storage failures, navigation or lost responses retain unacknowledged server copies for retry. Acknowledgements are idempotent.
Malformed stored XML remains pending with an explicit browser error; an administrative deletion/recovery UI is not implemented.

Merging keeps read/saved flags, stable saved copies, imported originals, translations and manual tags.
Older cloud snapshots cannot replace more recently fetched local feed/article content.
The cloud is a delivery queue, not a complete backup or multi-device article/history sync: a result is removed after one browser acknowledges it.
Browser-local articles and marks remain local after logout; a shared browser profile is not an account-isolated local library.
The cloud queue contains RSS-provided content. Fetching the linked article's full text, translation and speech still happen when using the browser.

## Activation and validation

The existing Better Auth session verifies the account; callers cannot select a different owner.
Collection changes/acknowledgements require the account session's CSRF token. Snapshot reads are scoped to the verified owner.
Browser requests include the account identity observed in status so a login change cannot apply an in-flight operation to a different account.
`RSS_COLLECTION_ENABLED="true"` enables the collector in a configured Worker. It is absent/false in the default offline environment.
The existing `AccountVault` binding and migration are reused; no new D1 table, cron trigger or credential/provider connection is required.
Activation still requires a reviewed deployment target, authentication configuration, operating limits/cost review and deployment authorization.
Do not describe a local Miniflare result as PC-off production verification.

Run `npm run workers:build`, `npm run test:workers`, `npm run test:browser` and the browser checks documented in [browser validation](browser-validation.md).
The local runtime test uses real Durable Object storage/alarms and a synthetic outbound RSS response. It waits without browser requests, then checks collection, restart persistence, ownership and CSRF.
Core tests cover failed writes, duplicate alarm delivery, in-flight pause, durable backoff, capacity and acknowledgement recovery, redirects and response limits.
Browser tests cover importing after reopen, lost acknowledgement, newer local content, failed local saves, start/stop, stale revisions and an unavailable service.
Live cloud activation, long-running operation, arbitrary cloud feed hosts, complete backup/multi-device sync and owner usability acceptance remain outstanding.
