import test from "node:test";
import assert from "node:assert/strict";
import { FeedCollector } from "../../workers/feed-collector.mjs";
import { fetchCloudFeed } from "../../workers/feed-fetch.mjs";

class Storage {
  data = new Map();
  queue = Promise.resolve();
  fail = false;
  get(key) {
    return Promise.resolve(structuredClone(this.data.get(key)));
  }
  transaction(update) {
    const operation = this.queue.then(async () => {
      const next = structuredClone(this.data);
      const result = await update({
        get: async (key) => structuredClone(next.get(key)),
        put: async (key, value) => {
          if (this.fail) throw Error("disk-full");
          next.set(key, structuredClone(value));
        },
        delete: async (key) => {
          next.delete(key);
        },
        setAlarm: async (time) => {
          next.set("alarm", time);
        },
        deleteAlarm: async () => {
          next.delete("alarm");
        },
      });
      this.data = next;
      return result;
    });
    this.queue = operation.catch(() => {});
    return operation;
  }
}
const url = "https://zenn.dev/feed";
const xml = "<rss><channel><title>Example</title></channel></rss>";
function fixture(extra = {}) {
  const storage = new Storage();
  let time = 1_800_000_000_000,
    calls = 0;
  const options = {
    enabled: true,
    now: () => time,
    fetchFeed: async (address) => {
      calls++;
      return { url: address, xml };
    },
    ...extra,
  };
  const collector = new FeedCollector(storage, options);
  return {
    storage,
    collector,
    calls: () => calls,
    advance: (ms) => {
      time += ms;
    },
    restart: () => new FeedCollector(storage, options),
  };
}
const configure = (collector) =>
  collector.configure({ expectedRevision: 0, interval: 15, urls: [url] });

test("scheduled collection survives re-instantiation and keeps snapshots until durable client acknowledgement", async () => {
  const f = fixture();
  await configure(f.collector);
  await f.restart().alarm(); // No browser request runs the collection.
  const state = await f.restart().status();
  assert.equal(state.pending.length, 1);
  const id = state.pending[0].id;
  assert.equal((await f.restart().snapshot(id)).xml, xml);
  assert.equal((await f.restart().snapshot(id)).xml, xml); // Lost response is redelivered.
  f.advance(15 * 60_000);
  await f.restart().alarm();
  assert.equal(f.calls(), 2);
  assert.equal((await f.collector.status()).pending.length, 1); // Same document is not queued twice.
  await f.collector.acknowledge({ ids: [id] });
  await f.collector.acknowledge({ ids: [id] }); // Lost ACK response is safe to retry.
  assert.equal((await f.restart().status()).bytes, 0);
  await assert.rejects(f.restart().snapshot(id), /snapshot-missing/);
});

test("pause during a fetch discards its late result; configuration uses optimistic concurrency", async () => {
  let release;
  const f = fixture({
    fetchFeed: async () =>
      new Promise((resolve) => {
        release = resolve;
      }),
  });
  await configure(f.collector);
  const running = f.collector.alarm();
  while (!release) await new Promise((resolve) => setTimeout(resolve, 0));
  await f.collector.configure({
    expectedRevision: 1,
    interval: 0,
    urls: [url],
  });
  release({ url, xml });
  await running;
  assert.equal((await f.collector.status()).pending.length, 0);
  assert.equal(await f.storage.get("alarm"), undefined);
  await assert.rejects(
    f.collector.configure({ expectedRevision: 1, interval: 15, urls: [url] }),
    /collection-conflict/,
  );
});

test("failures back off across restart, keep earlier snapshots and recover", async () => {
  let fail = false;
  const f = fixture({
    fetchFeed: async () => {
      if (fail) throw Error("private error");
      return { url, xml };
    },
  });
  await configure(f.collector);
  await f.collector.alarm();
  f.advance(15 * 60_000);
  fail = true;
  await f.restart().alarm();
  const first = await f.collector.status();
  assert.equal(first.feeds[0].failures, 1);
  assert.equal(first.pending.length, 1);
  f.advance(5 * 60_000);
  await f.restart().alarm();
  const second = await f.collector.status();
  assert.equal(second.feeds[0].failures, 2);
  assert.equal(second.feeds[0].nextAt - first.feeds[0].nextAt, 10 * 60_000);
  fail = false;
  f.advance(10 * 60_000);
  await f.restart().alarm();
  assert.equal((await f.collector.status()).feeds[0].error, "");
});

test("an acknowledgement write failure retains the snapshot and all chunks", async () => {
  const text = "😀".repeat(40_000);
  const f = fixture({ fetchFeed: async () => ({ url, xml: text }) });
  await configure(f.collector);
  await f.collector.alarm();
  const before = await f.collector.status();
  const id = before.pending[0].id;
  f.storage.fail = true;
  await assert.rejects(f.collector.acknowledge({ ids: [id] }), /disk-full/);
  assert.deepEqual(await f.collector.status(), before);
  assert.equal((await f.collector.snapshot(id)).xml, text);
  f.storage.fail = false;
  await f.collector.acknowledge({ ids: [id] });
  assert.equal(
    [...f.storage.data.keys()].some((key) => key.startsWith("rss:snapshot:")),
    false,
  );
});

test("full queue pauses without evicting articles, then ACK resumes collection", async () => {
  let version = 0;
  const f = fixture({ fetchFeed: async () => ({ url, xml: xml + version++ }) });
  await configure(f.collector);
  for (let i = 0; i < 101; i++) {
    await f.collector.alarm();
    f.advance(15 * 60_000);
  }
  const state = await f.collector.status();
  assert.equal(state.pending.length, 100);
  assert.equal(state.blocked, true);
  assert.equal(await f.storage.get("alarm"), undefined);
  const first = state.pending[0].id;
  assert.equal((await f.collector.snapshot(first)).xml, xml + "0");
  await f.collector.acknowledge({ ids: [first] });
  assert.equal((await f.collector.status()).blocked, false);
  assert.ok(await f.storage.get("alarm"));
  await f.collector.alarm();
  assert.equal((await f.collector.status()).pending.length, 100);
});

test("disabled runtime makes no requests and repeated alarms respect the persisted lease", async () => {
  const f = fixture();
  await configure(f.collector);
  const disabled = new FeedCollector(f.storage);
  await disabled.alarm();
  assert.equal(f.calls(), 0);
  assert.equal((await disabled.status()).available, false);
  await assert.rejects(configure(disabled), /collection-unconfigured/);
  await Promise.all([f.collector.alarm(), f.restart().alarm()]);
  assert.equal(f.calls(), 1);
  assert.equal((await f.collector.status()).pending.length, 1);
});

test("cloud fetch restricts initial URLs and every redirect, and never forwards user cookies", async () => {
  let calls = 0;
  const send = async (_url, init) => {
    calls++;
    assert.equal(init.redirect, "manual");
    assert.deepEqual(Object.keys(init.headers), ["Accept"]);
    return new Response(null, {
      status: 302,
      headers: { Location: "https://127.0.0.1/private" },
    });
  };
  for (const value of [
    "http://zenn.dev/feed",
    "https://zenn.dev.evil.org/feed",
    "https://user:pass@zenn.dev/feed",
    "https://zenn.dev:444/feed",
  ])
    await assert.rejects(
      fetchCloudFeed(value, { send }),
      /feed-host-unsupported/,
    );
  assert.equal(calls, 0);
  await assert.rejects(fetchCloudFeed(url, { send }), /feed-host-unsupported/);
  assert.equal(calls, 1);
});

test("cloud fetch bounds responses and deadlines and rejects HTML and XML entities", async () => {
  for (const [body, type] of [
    ["a".repeat(2_000_001), "text/xml"],
    ["<!DOCTYPE rss>", "text/xml"],
    [xml, "text/html"],
  ])
    await assert.rejects(
      fetchCloudFeed(url, {
        send: async () =>
          new Response(body, { headers: { "Content-Type": type } }),
      }),
    );
  await assert.rejects(
    fetchCloudFeed(url, {
      send: async () => new Promise(() => {}),
      timeout: 5,
    }),
    /feed-timeout/,
  );
  await assert.rejects(
    fetchCloudFeed(url, {
      send: async () =>
        new Response(xml, {
          status: 206,
          headers: { "Content-Type": "application/rss+xml" },
        }),
    }),
    /feed-response/,
  );
  assert.deepEqual(
    await fetchCloudFeed(url, {
      send: async () =>
        new Response(xml, {
          headers: { "Content-Type": "application/rss+xml" },
        }),
    }),
    { url, xml },
  );
});
