import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { encode } from "../../workers/crypto.mjs";
async function bundle(entry) {
  return (
    await build({
      entryPoints: [entry],
      bundle: true,
      write: false,
      format: "esm",
      platform: "neutral",
      target: "es2022",
      external: ["cloudflare:workers"],
      logLevel: "silent",
    })
  ).outputFiles[0].text;
}
const origin = "http://app.test";
const ring = () =>
  JSON.stringify({
    active: "test-v1",
    keys: { "test-v1": encode(crypto.getRandomValues(new Uint8Array(32))) },
  });
async function fixture(
  t,
  entry = "tests/workers/fixture-entry.mjs",
  extra = {},
) {
  const dir = await mkdtemp(join(tmpdir(), "textbook-workers-test-"));
  const script = await bundle(entry);
  let outbound = 0;
  const config = {
    modules: true,
    script,
    compatibilityDate: "2026-10-11",
    durableObjects: {
      ACCOUNTS: { className: "AccountVault", useSQLite: true },
    },
    resourcePersistencePath: dir,
    bindings: { APP_ORIGIN: origin, BYOK_ENCRYPTION_KEYRING: ring() },
    outboundService: () => {
      outbound++;
      throw Error("external network forbidden in tests");
    },
    ...extra,
  };
  let mf = new Miniflare(convertV4MiniflareOptions(config));
  t.after(async () => {
    await mf.dispose();
    await rm(dir, { recursive: true, force: true });
  });
  const api = async (
    path,
    { user = "test-a", method = "GET", body, csrf, headers = {} } = {},
  ) => {
    const response = await mf.dispatchFetch(origin + path, {
      method,
      headers: {
        Origin: origin,
        "X-Test-Principal": user,
        ...(body ? { "Content-Type": "application/json" } : {}),
        ...(csrf ? { "X-CSRF-Token": csrf } : {}),
        ...headers,
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const value = await response.json();
    return { status: response.status, value, headers: response.headers };
  };
  return {
    api,
    script,
    outbound: () => outbound,
    restart: async () => {
      await mf.dispose();
      mf = new Miniflare(convertV4MiniflareOptions(config));
    },
  };
}
const command = (expectedRevision = 0) => ({
  requestId: randomUUID(),
  expectedRevision,
  key: `DUMMY-ONLY-${randomUUID()}`,
  model: "gpt-6-luna",
});
test("production bundle stays auth-unconfigured despite forged principal/session/key flags", async (t) => {
  const f = await fixture(t, "workers/index.mjs", {
    bindings: {
      APP_ORIGIN: origin,
      BYOK_ENCRYPTION_KEYRING: ring(),
      AUTH_MODE: "test",
      CREDENTIALS_ENABLED: "true",
    },
  });
  for (const method of ["GET", "POST", "PUT", "DELETE"]) {
    const result = await f.api("/api/credentials/openai", {
      method,
      body: method === "GET" ? undefined : command(),
      csrf: "forged",
    });
    assert.equal(result.status, 503);
    assert.deepEqual(result.value, {
      status: "auth-unconfigured",
      realKeyInputEnabled: false,
    });
    assert.equal(JSON.stringify(result).includes("DUMMY-ONLY"), false);
  }
  assert.equal(f.script.includes("X-Test-Principal"), false);
  assert.equal(f.script.includes("local-only:"), false);
  assert.equal(f.outbound(), 0);
});
test("actual local SQLite DO CRUD separates users/providers, rejects ownership injection, persists and deletes without secret responses", async (t) => {
  const f = await fixture(t);
  const session = await f.api("/api/session");
  const csrf = session.value.csrfToken;
  const bSession = await f.api("/api/session", { user: "test-b" });
  const data = command();
  const first = await f.api("/api/credentials/openai", {
    method: "POST",
    body: data,
    csrf,
  });
  assert.equal(first.status, 200);
  assert.equal(first.value.revision, 1);
  assert.equal(first.value.connection, "unconnected");
  assert.equal(JSON.stringify(first).includes(data.key), false);
  assert.equal(JSON.stringify(first).includes("ciphertext"), false);
  assert.equal(first.headers.get("cache-control"), "no-store");
  assert.equal(
    (await f.api("/api/credentials/openai", { user: "test-b" })).value.state,
    "deleted",
  );
  assert.equal(
    (await f.api("/api/credentials/anthropic")).value.state,
    "deleted",
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        user: "test-b",
        method: "PUT",
        body: command(1),
        csrf: bSession.value.csrfToken,
      })
    ).status,
    409,
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "PUT",
        body: { ...command(1), owner: "test-b" },
        csrf,
      })
    ).status,
    409,
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "PUT",
        body: command(1),
        csrf: bSession.value.csrfToken,
      })
    ).status,
    403,
  );
  await f.restart();
  assert.equal((await f.api("/api/credentials/openai")).value.revision, 1);
  const results = await Promise.all([
    f.api("/api/credentials/openai", { method: "PUT", body: command(1), csrf }),
    f.api("/api/credentials/openai", { method: "PUT", body: command(1), csrf }),
  ]);
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "DELETE",
        body: { requestId: randomUUID(), expectedRevision: 2 },
        csrf,
      })
    ).value.state,
    "deleted",
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "POST",
        body: data,
        csrf,
      })
    ).value.state,
    "deleted",
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "POST",
        body: command(3),
        csrf,
      })
    ).value.revision,
    4,
  );
  assert.equal((await f.api("/api/budget")).value.limitMilliYen, 500000);
  assert.equal(
    (await f.api("/api/budget", { user: "test-b" })).value.limitMilliYen,
    500000,
  );
  assert.equal(f.outbound(), 0);
});
test("missing encryption, unauthenticated, bad origin/CSRF/body size never saves a dummy credential", async (t) => {
  const f = await fixture(t, undefined, { bindings: { APP_ORIGIN: origin } });
  const csrf = (await f.api("/api/session")).value.csrfToken;
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "POST",
        body: command(),
        csrf,
      })
    ).value.status,
    "encryption-unconfigured",
  );
  assert.equal((await f.api("/api/credentials/openai")).value.state, "deleted");
  assert.equal(
    (await f.api("/api/credentials/openai", { user: "unknown" })).status,
    401,
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        headers: { Origin: "http://evil.test" },
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "POST",
        body: command(),
        csrf: "bad",
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await f.api("/api/credentials/openai", {
        method: "POST",
        body: { ...command(), key: "x".repeat(40000) },
        csrf,
      })
    ).status,
    503,
  );
  assert.equal(f.outbound(), 0);
});
const proposal = (modelId, question = "公開CAA質問") => ({
  requestId: randomUUID(),
  bookId: "caa",
  version: "1.8",
  blockId: "read",
  question,
  excerpt: "CAA",
  purpose: "book-addition",
  modelId,
  sourceIds: ["rfc8659"],
  approvedPublicText: true,
});
test("SQLite per-user budgets combine providers, preserve unknown reservations after deletion and restart, and do not cap all users together", async (t) => {
  const f = await fixture(t);
  const csrf = (await f.api("/api/session")).value.csrfToken;
  const bCsrf = (await f.api("/api/session", { user: "test-b" })).value
    .csrfToken;
  await f.api("/api/credentials/openai", {
    method: "POST",
    body: command(),
    csrf,
  });
  await f.api("/api/credentials/anthropic", {
    method: "POST",
    body: { ...command(), model: "claude-haiku-5-5" },
    csrf,
  });
  const first = await f.api("/api/proposals", {
    method: "POST",
    body: proposal("openai-luna-candidate"),
    csrf,
  });
  assert.equal(first.value.status, "complete");
  assert.equal(
    (
      await f.api("/api/proposals", {
        method: "POST",
        body: proposal("anthropic-haiku-candidate"),
        csrf,
      })
    ).value.status,
    "complete",
  );
  assert.equal(
    (
      await f.api("/api/proposals", {
        method: "POST",
        body: proposal("anthropic-haiku-candidate"),
        csrf,
      })
    ).value.status,
    "budget-exhausted",
  );
  assert.equal(
    (await f.api("/api/budget", { user: "test-b" })).value.spentMilliYen,
    0,
  );
  await f.api("/api/credentials/openai", {
    user: "test-b",
    method: "POST",
    body: command(),
    csrf: bCsrf,
  });
  assert.equal(
    (
      await f.api("/api/proposals", {
        user: "test-b",
        method: "POST",
        body: proposal("openai-luna-candidate"),
        csrf: bCsrf,
      })
    ).value.status,
    "complete",
  );
  const waiting = await f.api("/api/proposals", {
    user: "test-b",
    method: "POST",
    body: proposal("openai-luna-candidate", "WAIT-MOCK"),
    csrf: bCsrf,
  });
  assert.equal(waiting.value.status, "unknown");
  await f.api("/api/credentials/openai", {
    user: "test-b",
    method: "DELETE",
    body: { requestId: randomUUID(), expectedRevision: 1 },
    csrf: bCsrf,
  });
  await f.restart();
  const held = await f.api("/api/budget", { user: "test-b" });
  assert.ok(held.value.heldMilliYen > 0);
  await f.api("/api/credentials/openai", {
    user: "test-b",
    method: "POST",
    body: command(2),
    csrf: bCsrf,
  });
  assert.equal(
    (
      await f.api("/api/proposals", {
        user: "test-b",
        method: "POST",
        body: proposal("openai-luna-candidate"),
        csrf: bCsrf,
      })
    ).value.status,
    "busy",
  );
  assert.equal(f.outbound(), 0);
});
test("connection check consumes the same per-user budget and stale credential versions cannot be checked", async (t) => {
  const f = await fixture(t);
  const csrf = (await f.api("/api/session")).value.csrfToken;
  await f.api("/api/credentials/openai", {
    method: "POST",
    body: command(),
    csrf,
  });
  const body = {
    requestId: randomUUID(),
    expectedRevision: 1,
    approvedPublicText: true,
  };
  const result = await f.api("/api/credentials/openai/check", {
    method: "POST",
    body,
    csrf,
  });
  assert.equal(result.status, 200);
  assert.equal(result.value.checked, true);
  assert.equal(result.value.connection, "unconnected");
  assert.ok((await f.api("/api/budget")).value.spentMilliYen > 0);
  const spent = (await f.api("/api/budget")).value.spentMilliYen;
  await f.api("/api/credentials/openai/check", { method: "POST", body, csrf });
  assert.equal((await f.api("/api/budget")).value.spentMilliYen, spent);
  await f.api("/api/credentials/openai", {
    method: "PUT",
    body: command(1),
    csrf,
  });
  assert.equal(
    (
      await f.api("/api/credentials/openai/check", {
        method: "POST",
        body,
        csrf,
      })
    ).status,
    409,
  );
  assert.equal((await f.api("/api/credentials/openai")).value.checked, false);
  assert.equal(f.outbound(), 0);
});
test("same-origin browser GET without Origin works only with Fetch Metadata; cross-site reads are denied", async (t) => {
  const f = await fixture(t);
  assert.equal(
    (
      await f.api("/api/session", {
        headers: { Origin: "", "Sec-Fetch-Site": "cross-site" },
      })
    ).status,
    403,
  );
  const handler = await import("../../workers/http.mjs");
  let delegated = 0;
  const env = {
    APP_ORIGIN: origin,
    ACCOUNTS: {
      idFromName: () => "owner",
      get: () => ({
        fetch: async () => {
          delegated++;
          return new Response("{}");
        },
      }),
    },
  };
  const fetch = handler.createHandler({
    authenticate: async () => ({
      subject: "verified-test",
      sessionId: "test-session",
    }),
  });
  assert.equal(
    (
      await fetch(
        new Request(origin + "/api/session", {
          headers: { "Sec-Fetch-Site": "same-origin" },
        }),
        env,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await fetch(
        new Request(origin + "/api/session", {
          headers: { "Sec-Fetch-Site": "cross-site" },
        }),
        env,
      )
    ).status,
    403,
  );
  assert.equal(delegated, 1);
});
