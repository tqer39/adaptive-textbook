// Explicit publisher allowlist: this Worker does not have the Node adapter's
// DNS pinning. Do not silently turn arbitrary browser URLs into cloud fetches.
export const defaultFeedHosts = [
  "hnrss.org",
  "zenn.dev",
  "blog.cloudflare.com",
];
export function cloudFeedURL(value, hosts = defaultFeedHosts) {
  if (typeof value !== "string" || value.length > 2048) throw Error("feed-url");
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.port ||
    !hosts.includes(url.hostname) ||
    url.hash
  )
    throw Error("feed-host-unsupported");
  return url;
}

export async function fetchCloudFeed(
  value,
  {
    hosts = defaultFeedHosts,
    send = fetch,
    timeout = 12000,
    allowHTML = false,
  } = {},
) {
  const controller = new AbortController();
  let rejectDeadline;
  const deadline = new Promise((_, reject) => {
    rejectDeadline = reject;
  });
  const timer = setTimeout(() => {
    controller.abort();
    rejectDeadline(Error("feed-timeout"));
  }, timeout);
  try {
    return await Promise.race([
      deadline,
      (async () => {
        let url = cloudFeedURL(value, hosts);
        for (let redirects = 0; redirects <= 3; redirects++) {
          const response = await send(url.href, {
            redirect: "manual",
            signal: controller.signal,
            headers: {
              Accept:
                "application/atom+xml, application/rss+xml, application/xml, text/xml",
            },
          });
          if ([301, 302, 303, 307, 308].includes(response.status)) {
            await response.body?.cancel();
            const location = response.headers.get("Location");
            if (!location) throw Error("feed-redirect");
            url = cloudFeedURL(new URL(location, url).href, hosts);
            continue;
          }
          const html = /^(text\/html|application\/xhtml\+xml)(;|$)/i.test(
            response.headers.get("Content-Type") ?? "",
          );
          if (
            response.status !== 200 ||
            !response.body ||
            (!(allowHTML && html) &&
              !/^(application\/(rss\+xml|atom\+xml|xml)|text\/(xml|plain))(;|$)/i.test(
                response.headers.get("Content-Type") ?? "",
              ))
          ) {
            await response.body?.cancel();
            throw Error("feed-response");
          }
          const charset =
            /charset=["']?([^;\s"']+)/i.exec(
              response.headers.get("Content-Type") ?? "",
            )?.[1] ?? "utf-8";
          const reader = response.body.getReader();
          try {
            const decoder = new TextDecoder(charset, { fatal: true });
            let xml = "",
              size = 0;
            for (;;) {
              const { done, value: chunk } = await reader.read();
              if (done) break;
              size += chunk.byteLength;
              if (size > 2_000_000) throw Error("feed-size");
              xml += decoder.decode(chunk, { stream: true });
            }
            xml += decoder.decode();
            if (!xml.trim() || (!html && /<!\s*(DOCTYPE|ENTITY)/i.test(xml)))
              throw Error("feed-xml");
            return { url: url.href, [html ? "html" : "xml"]: xml };
          } finally {
            await reader.cancel().catch(() => {});
            reader.releaseLock();
          }
        }
        throw Error("feed-redirect");
      })(),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
