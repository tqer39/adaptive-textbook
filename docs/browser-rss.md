# Browser RSS collection and deployment choices

[English](browser-rss.md) | [日本語](browser-rss.ja.md)

## Run and try

Run `mise exec -- npm run dev` and open <http://127.0.0.1:5173/>.
The home screen collects information. In **サイトを追加**, enter a site, article or RSS/Atom URL and select **フィードを探す**.
Domains without a scheme use HTTPS. Choose a named feed with **登録して読む**; discovered feeds are not subscribed automatically.
Zenn and Cloudflare Blog remain one-click examples.
Open an article, select **この記事を保存**, return to the list and select **保存した記事**.
Reload to check the saved copy. **サンプル教材** opens the existing fixed CAA lesson separately; collection does not generate it.

Discovery reads the page's advertised RSS/Atom alternate links, including relative URLs and its HTML base URL.
If an article page has no advertised feeds, it also checks the final site's home page, within the same 16-second client deadline.
Up to 20 distinct candidates are shown. Changing the input cancels the search and discards stale results.
The discovery HTML remains in an inert template: scripts, images and embedded frames are never mounted or executed.
Chosen feeds and all redirects still pass the existing public-HTTPS and DNS checks.
Sites that do not advertise a feed show a clear message; name/topic search, arbitrary crawling, guessed feed paths and generating feeds from feedless sites are not implemented.
Previously collected articles remain readable and saveable during discovery or failure.

RSS acquisition and page discovery run inside the local Vite process through `/api/feeds/fetch`; only discovery requests allow HTML responses.
There is no new package, cloud deployment, login or paid model connection.
`npm run build` creates static assets but does not create or deploy the RSS acquisition service.
`vite preview` and the existing Workers deployment do not provide this new endpoint yet.

## What is saved

Subscriptions, collected article text, read flags and saved flags use IndexedDB database `tsumiki.rss.v1`.
The existing sample lesson's localStorage history is separate and preserved.
State is specific to the browser profile and origin, including the port. Another browser, port or device has separate data.
Clearing site data or browser eviction can remove it; this prototype has no export/backup or device synchronization.
See [browser storage behavior](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria).

A saved article keeps its collected title, date and text when a later feed refresh changes the same entry.
Refresh does not delete older articles, read flags or saved flags. Multi-tab changes use IndexedDB transactions and change notifications.
Failed writes do not claim success, and the error includes an explicit retry.
A slow or failed feed does not prevent reading previously collected articles.

Only the text supplied by the feed is collected; some feeds contain an excerpt rather than the full article.
Images, executable markup and embedded content are not rendered. The original article opens only when selected.
At most 50 subscriptions, 200 entries per feed response and 40,000 text characters per article are accepted in this first version.
There is no translation, full-page extraction, textbook generation, background polling or offline app installation in this slice.
Reading cached articles during a feed/API outage is supported while the local app server remains available;
reopening the app with that server stopped is not implemented.

## Where a backend is needed

| Interface / requirement | Acquisition and storage | Cloud backend required? |
| --- | --- | --- |
| Current browser on this PC | Local Node/Vite RSS acquisition; browser IndexedDB | No. The local process must be running; updating RSS needs internet access. |
| Browser on PC and smartphone, with separate histories | Static web UI plus a reachable RSS acquisition API; each browser stores its own history | A reachable acquisition service is generally needed for arbitrary feeds. It can be self-hosted or serverless. |
| PC and smartphone with the same subscriptions, saved articles and history | Acquisition plus authenticated synchronization and durable shared storage | A shared service or platform sync is needed; it does not have to be a dedicated rented server. Not implemented here. |
| Future native PC/smartphone apps used on one device | Native networking and an on-device database can fetch and store feeds directly | No cloud backend is inherently required. Shared state and background behavior are separate design decisions. |

Browser JavaScript cannot read arbitrary feed responses unless the publisher permits the web origin through CORS.
Feeds that permit it can be fetched directly, and importing a feed file can work locally, but those do not cover general URL subscriptions.
See [CORS](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS).
The proposed common boundary is an RSS acquisition API and an optional synchronization API, leaving the interface replaceable.

The current acquisition endpoint accepts only same-origin requests on loopback `127.0.0.1`; it is intentionally unavailable from a phone over the LAN.
Mobile viewport tests verify layout, not access from a physical phone or a deployed shared service.
A public deployment needs authentication, per-user limits, deployment-specific network controls and persistent storage design before exposure.
No Cloudflare/AWS service or LAN/public binding was enabled in this work.

## Acquisition boundary

Only public HTTPS destinations on the standard port are accepted; URL credentials and literal IP addresses are rejected.
DNS results must all be public addresses. The checked address is pinned to the TLS connection, while certificate validation uses the original hostname.
Redirects are checked again, with at most three followed redirects. Requests have a 12-second total deadline and a 2 MB response limit.
RSS/Atom XML rejects DOCTYPE/entity declarations; discovery HTML can contain a normal HTML doctype and stays inert.
The local endpoint limits concurrent requests and body size, and does not forward cookies, authorization or arbitrary proxy options.
These controls do not make the local development endpoint ready for public deployment.
