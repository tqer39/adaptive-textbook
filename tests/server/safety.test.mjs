import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { FileLedger } from "../../server/ledger.mjs";
import {
  GenerationService,
  reservationMilliYen,
} from "../../server/service.mjs";
import { localServer } from "../../server/http.mjs";
import { validateDraft, requestSchema } from "../../server/contracts.mjs";

const date = "2026-10-11T00:00:00.000Z";
const now = () => new Date(date);
const policy = {
  confirmedCostUpperBounds: true,
  checkedAt: date,
  fixedMilliYen: 0,
  safetyMilliYen: 0,
  yenPerUsdMilli: 200000,
  taxFeePermille: 1200,
  providerCapsMilliYen: {},
};
const model = (id = "test-a", provider = "fixture-a") => ({
  id,
  provider,
  model: id,
  purposes: ["term-explanation", "book-addition", "evidence-check"],
  structuredOutput: true,
  dataConditions: "TEST ONLY: no external request",
  dataConditionsAccepted: true,
  approval: "test-only",
  priceCheckedAt: date,
  inputUsdMicrosPerMillion: 250000,
  outputUsdMicrosPerMillion: 750000,
  inputTokens: 8000,
  outputTokens: 2000,
});
const sources = [
  {
    id: "rfc8659",
    url: "https://www.rfc-editor.org/rfc/rfc8659.html",
    checkedAt: date,
    body: "The first CAA RRset is selected. Parent and child are not combined.",
  },
];
const draft = {
  gap: "探索停止点の説明",
  block: {
    id: "trace-extra",
    title: "探索停止",
    kind: "reading",
    markdown: "最初の CAA RRset を採用します。",
    visual: "lookup-flow",
  },
  references: [
    { sourceId: "rfc8659", quote: "The first CAA RRset is selected." },
  ],
};
const request = (extra = {}) => ({
  requestId: randomUUID(),
  bookId: "caa",
  version: "1.8.0",
  blockId: "read",
  question: "最初の集合で止まる理由は？",
  excerpt: "CAA の探索",
  purpose: "book-addition",
  sourceIds: ["rfc8659"],
  approvedPublicText: true,
  ...extra,
});
const stub = (
  generate = async () => ({
    json: JSON.stringify(draft),
    costUpperMilliYen: 800,
    outputTokens: 100,
  }),
) => ({ kind: "test-only", generate });
async function fixture(t, extra = {}) {
  const dir = await mkdtemp(join(tmpdir(), "textbook-off-budget-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const ledger = new FileLedger(dir);
  const config = {
    ledger,
    policy,
    registry: [model()],
    selectionPolicy: { "book-addition": "test-a" },
    adapters: { "fixture-a": stub() },
    sources,
    now,
    ...extra,
  };
  return { dir, ledger, config, service: new GenerationService(config) };
}

test("default service is unconnected and never reads secrets or reserves", async (t) => {
  const { ledger, dir } = await fixture(t);
  assert.deepEqual(await new GenerationService({ ledger }).propose(request()), {
    status: "unconnected",
  });
  await assert.rejects(readFile(join(dir, "budget.json")));
});
test("fail closed on cost, price, conditions, capability and approval", async (t) => {
  let calls = 0;
  const adapters = {
    "fixture-a": stub(async () => {
      calls++;
      throw Error("not called");
    }),
  };
  for (const extra of [
    { policy: null },
    { policy: { ...policy, confirmedCostUpperBounds: false } },
    { policy: { ...policy, checkedAt: "2026-01-01T00:00:00.000Z" } },
    { registry: [{ ...model(), inputUsdMicrosPerMillion: null }] },
    { registry: [{ ...model(), priceCheckedAt: "2026-01-01T00:00:00.000Z" }] },
    { registry: [{ ...model(), dataConditionsAccepted: false }] },
    { registry: [{ ...model(), structuredOutput: false }] },
    { registry: [{ ...model(), approval: "disabled" }] },
  ]) {
    const { service } = await fixture(t, { adapters, ...extra });
    assert.notEqual((await service.propose(request())).status, "complete");
  }
  assert.equal(calls, 0);
});
test("integer reservation includes output and tax/FX bound", () => {
  assert.equal(reservationMilliYen(policy, model()), 840);
});
test("durable reservation precedes single dispatch; replay, conflicts and restart do not dispatch twice", async (t) => {
  let calls = 0;
  const f = await fixture(t);
  f.config.adapters["fixture-a"] = stub(async (payload, options) => {
    calls++;
    const h = JSON.parse(await readFile(join(f.dir, "budget.json"), "utf8"));
    assert.equal(h.records[0].state, "reserved");
    assert.equal(options.retries, 0);
    assert.equal(options.store, false);
    assert.deepEqual(options.tools, []);
    assert.deepEqual(Object.keys(payload).sort(), [
      "excerpt",
      "question",
      "sources",
    ]);
    return {
      json: JSON.stringify(draft),
      costUpperMilliYen: 800,
      outputTokens: 100,
    };
  });
  const input = request();
  assert.equal((await f.service.propose(input)).status, "complete");
  const restarted = new GenerationService(f.config);
  assert.equal((await restarted.propose(input)).status, "complete");
  assert.equal(
    (await restarted.propose({ ...input, question: "変更" })).status,
    "id-conflict",
  );
  assert.equal(calls, 1);
  assert.equal((await stat(join(f.dir, "budget.json"))).mode & 0o777, 0o600);
});
test("cross-instance exclusive lock and one in-flight request across providers", async (t) => {
  let release;
  let entered;
  const started = new Promise((r) => {
    entered = r;
  });
  const { service, config, ledger } = await fixture(t, {
    adapters: {
      "fixture-a": stub(async () => {
        entered();
        await new Promise((r) => {
          release = r;
        });
        return {
          json: JSON.stringify(draft),
          costUpperMilliYen: 800,
          outputTokens: 100,
        };
      }),
    },
  });
  const pending = service.propose(request());
  await started;
  assert.equal(
    (await new GenerationService(config).propose(request())).status,
    "busy",
  );
  release();
  assert.equal((await pending).status, "complete");
  await mkdirLock(ledger.directory);
  await assert.rejects(service.propose(request()));
});
async function mkdirLock(dir) {
  const { mkdir } = await import("node:fs/promises");
  await mkdir(join(dir, "transaction.lock"));
}
test("timeout retains reservation through restart and month rollover, without retries or fallback", async (t) => {
  let calls = 0;
  const f = await fixture(t, {
    timeoutMs: 5,
    adapters: {
      "fixture-a": stub(() => {
        calls++;
        return new Promise(() => {});
      }),
    },
  });
  const input = request();
  assert.equal((await f.service.propose(input)).status, "unknown");
  assert.equal(
    (await new GenerationService(f.config).propose(input)).status,
    "unknown",
  );
  assert.equal((await f.service.propose(request())).status, "busy");
  const later = "2026-11-01T00:00:00.000Z";
  const nextMonth = new GenerationService({
    ...f.config,
    now: () => new Date(later),
    policy: { ...policy, checkedAt: later },
    registry: [{ ...model(), priceCheckedAt: later }],
    sources: [{ ...sources[0], checkedAt: later }],
  });
  assert.equal((await nextMonth.propose(request())).status, "busy");
  assert.equal(calls, 1);
  const h = JSON.parse(await readFile(join(f.dir, "budget.json"), "utf8"));
  assert.equal(h.records[0].reservedMilliYen, 840);
});
test("model selection uses a shared 500-yen ledger and optional provider cap", async (t) => {
  const seen = [];
  const adapters = Object.fromEntries(
    ["fixture-a", "fixture-b"].map((p) => [
      p,
      stub(async (_, opts) => {
        seen.push(opts.model);
        return {
          json: JSON.stringify(draft),
          costUpperMilliYen: 840,
          outputTokens: 100,
        };
      }),
    ]),
  );
  const f = await fixture(t, {
    registry: [model(), model("test-b", "fixture-b")],
    adapters,
    policy: { ...policy, fixedMilliYen: 497500 },
    selectionPolicy: {
      "book-addition": "test-a",
      "term-explanation": "test-b",
    },
  });
  assert.equal((await f.service.propose(request())).status, "complete");
  assert.equal(
    (await f.service.propose(request({ purpose: "term-explanation" }))).status,
    "complete",
  );
  assert.equal(
    (await f.service.propose(request({ modelId: "test-b" }))).status,
    "budget-exhausted",
  );
  assert.deepEqual(seen, ["test-a", "test-b"]);
  const capped = await fixture(t, {
    policy: { ...policy, providerCapsMilliYen: { "fixture-a": 839 } },
  });
  assert.equal(
    (await capped.service.propose(request())).status,
    "provider-budget-exhausted",
  );
});
test("unknown model does not fallback and unsupported purpose does not dispatch", async (t) => {
  const f = await fixture(t, {
    registry: [{ ...model(), purposes: ["book-addition"] }],
  });
  assert.equal(
    (await f.service.propose(request({ modelId: "missing" }))).status,
    "unconnected",
  );
  assert.equal(
    (
      await f.service.propose(
        request({ modelId: "test-a", purpose: "evidence-check" }),
      )
    ).status,
    "model-unapproved",
  );
});
test("provider errors do not fallback, retry or release unknown reservations", async (t) => {
  let first = 0,
    second = 0;
  const f = await fixture(t, {
    registry: [model(), model("test-b", "fixture-b")],
    adapters: {
      "fixture-a": stub(async () => {
        first++;
        throw Error("provider error: test-only private placeholder");
      }),
      "fixture-b": stub(async () => {
        second++;
        throw Error("must never fallback");
      }),
    },
  });
  const input = request();
  assert.deepEqual(await f.service.propose(input), {
    status: "unknown",
    draft: null,
  });
  assert.equal(
    (await f.service.propose(request({ modelId: "test-b" }))).status,
    "busy",
  );
  assert.equal((await f.service.propose(input)).status, "unknown");
  assert.equal(first, 1);
  assert.equal(second, 0);
  assert.equal(
    (await readFile(join(f.dir, "budget.json"), "utf8")).includes(
      "private placeholder",
    ),
    false,
  );
});
test("paid invalid output spends its confirmed amount; malformed/code/source mismatch cannot become a draft", async (t) => {
  for (const raw of [
    "broken",
    JSON.stringify({ ...draft, js: "alert(1)" }),
    JSON.stringify({
      ...draft,
      block: { ...draft.block, visual: "arbitrary-js" },
    }),
    JSON.stringify({
      ...draft,
      block: { ...draft.block, markdown: "<script>bad</script>" },
    }),
    JSON.stringify({
      ...draft,
      references: [{ sourceId: "rfc8659", quote: "unsupported claim" }],
    }),
  ]) {
    assert.throws(() => validateDraft(raw, sources));
    const f = await fixture(t, {
      adapters: {
        "fixture-a": stub(async () => ({
          json: raw,
          costUpperMilliYen: 800,
          outputTokens: 100,
        })),
      },
    });
    const result = await f.service.propose(request());
    assert.equal(result.status, "rejected");
    assert.equal(result.draft, null);
    const h = JSON.parse(await readFile(join(f.dir, "budget.json"), "utf8"));
    assert.equal(h.records[0].spentMilliYen, 800);
  }
});
test("invalid sources, privacy extra fields, size and unconfirmed usage fail closed", async (t) => {
  assert.throws(() =>
    requestSchema.parse(request({ history: [], apiKey: "test-placeholder" })),
  );
  for (const source of [
    { ...sources[0], url: "https://evil.example/" },
    { ...sources[0], checkedAt: "2026-01-01T00:00:00.000Z" },
  ]) {
    const f = await fixture(t, { sources: [source] });
    await assert.rejects(f.service.propose(request()));
  }
  const large = await fixture(t, {
    sources: [
      { ...sources[0], body: "a".repeat(17000) },
      {
        ...sources[0],
        id: "letsencrypt-caa",
        url: "https://letsencrypt.org/docs/caa/",
        body: "b".repeat(17000),
      },
    ],
  });
  assert.equal(
    (
      await large.service.propose(
        request({ sourceIds: ["rfc8659", "letsencrypt-caa"] }),
      )
    ).status,
    "input-limit",
  );
  const over = await fixture(t, {
    adapters: {
      "fixture-a": stub(async () => ({
        json: JSON.stringify(draft),
        costUpperMilliYen: 841,
        outputTokens: 2001,
      })),
    },
  });
  assert.equal((await over.service.propose(request())).status, "unknown");
});
test("corrupt ledger is retained and never dispatches or resets", async (t) => {
  const f = await fixture(t);
  await writeFile(join(f.dir, "budget.json"), "corrupt");
  await assert.rejects(f.service.propose(request()));
  assert.equal(await readFile(join(f.dir, "budget.json"), "utf8"), "corrupt");
});
test("localhost HTTP enforces exact Host/Origin/CSRF/JSON/size and returns honest unconnected", async (t) => {
  const { ledger } = await fixture(t);
  const { server, listen } = localServer({
    service: new GenerationService({ ledger }),
    port: 0,
  });
  await listen();
  t.after(
    () =>
      new Promise((r) => {
        server.closeAllConnections();
        server.close(r);
      }),
  );
  const url = `http://127.0.0.1:${server.address().port}`;
  const origin = "http://127.0.0.1:5173";
  assert.equal((await fetch(url + "/session")).status, 403);
  assert.equal(
    (
      await fetch(url + "/session", {
        headers: { Origin: "https://evil.example" },
      })
    ).status,
    403,
  );
  const badHost = await new Promise((resolve, reject) => {
    const req = httpRequest(
      url + "/session",
      { headers: { Origin: origin, Host: "evil.example" } },
      (res) => {
        res.resume();
        resolve(res.statusCode);
      },
    );
    req.on("error", reject);
    req.end();
  });
  assert.equal(badHost, 403);
  const session = await fetch(url + "/session", {
    headers: { Origin: origin },
  });
  assert.equal(session.headers.get("cache-control"), "no-store");
  const { csrfToken, status } = await session.json();
  assert.equal(status, "unconnected");
  const headers = {
    Origin: origin,
    "Content-Type": "application/json",
    "X-CSRF-Token": csrfToken,
  };
  assert.equal(
    (
      await fetch(url + "/proposals", {
        method: "POST",
        headers: { Origin: origin },
        body: "{}",
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await fetch(url + "/proposals", {
        method: "POST",
        headers: { ...headers, "Content-Type": "text/plain" },
        body: "{}",
      })
    ).status,
    415,
  );
  assert.equal(
    (
      await fetch(url + "/proposals", {
        method: "POST",
        headers,
        body: JSON.stringify({ ...request(), secret: "placeholder" }),
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await fetch(url + "/proposals", {
        method: "POST",
        headers,
        body: " ".repeat(33000),
      })
    ).status,
    413,
  );
  const off = await fetch(url + "/proposals", {
    method: "POST",
    headers,
    body: JSON.stringify(request()),
  });
  assert.equal(off.status, 503);
  assert.deepEqual(await off.json(), { status: "unconnected" });
});
