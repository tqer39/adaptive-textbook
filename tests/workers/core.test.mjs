import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { AccountVaultCore } from "../../workers/vault.mjs";
import { encrypt, decrypt, hash, encode } from "../../workers/crypto.mjs";
import { registry } from "../../server/registry.mjs";
const date = "2026-10-11T00:00:00.000Z";
// Ephemeral random test data, not credentials for any service.
const keyring = () =>
  JSON.stringify({
    active: "test-v1",
    keys: { "test-v1": encode(crypto.getRandomValues(new Uint8Array(32))) },
  });
const dummy = () => `DUMMY-NOT-A-CREDENTIAL-${randomUUID()}`;
class MemoryStorage {
  data = new Map();
  queue = Promise.resolve();
  failWrite = false;
  failSync = false;
  async transaction(update) {
    const job = this.queue.then(async () => {
      const copy = new Map(
        [...this.data].map(([k, v]) => [k, structuredClone(v)]),
      );
      const result = await update({
        get: async (k) => structuredClone(copy.get(k)),
        put: async (k, v) => {
          if (this.failWrite) throw Error("test storage failure");
          copy.set(k, structuredClone(v));
        },
      });
      this.data = copy;
      return result;
    });
    this.queue = job.catch(() => {});
    return job;
  }
  async sync() {
    if (this.failSync) throw Error("test durability unknown");
  }
}
const mutation = (expectedRevision = 0, extra = {}) => ({
  requestId: randomUUID(),
  expectedRevision,
  key: dummy(),
  model: "gpt-6-luna",
  ...extra,
});
async function fixture(extra = {}) {
  const storage = new MemoryStorage();
  const config = { keyring: keyring(), now: () => new Date(date), ...extra };
  const core = new AccountVaultCore(storage, config);
  const owner = await hash("verified-test-owner-a");
  return { storage, config, core, owner };
}
test("AES-GCM randomized ciphertext is bound to owner/provider/revision/version and fails closed", async () => {
  const ring = keyring();
  const key = dummy();
  const one = await encrypt(key, "a", "openai", 1, ring);
  const two = await encrypt(key, "a", "openai", 1, ring);
  assert.notEqual(one.nonce, two.nonce);
  assert.notEqual(one.ciphertext, two.ciphertext);
  assert.equal(JSON.stringify(one).includes(key), false);
  assert.equal(await decrypt(one, "a", "openai", 1, ring), key);
  for (const context of [
    ["b", "openai", 1],
    ["a", "anthropic", 1],
    ["a", "openai", 2],
  ])
    await assert.rejects(
      decrypt(one, ...context, ring),
      /credential-unavailable/,
    );
  await assert.rejects(
    decrypt(
      { ...one, ciphertext: one.ciphertext.slice(0, -4) + "AAAA" },
      "a",
      "openai",
      1,
      ring,
    ),
  );
  await assert.rejects(
    encrypt(key, "a", "openai", 1, undefined),
    /encryption-unconfigured/,
  );
});
test("registration/replacement/model change encrypt only; failed writes roll back; deletion removes active ciphertext", async () => {
  const f = await fixture();
  const data = mutation();
  const initial = await f.core.mutate(f.owner, "openai", "register", data);
  assert.equal(initial.revision, 1);
  assert.equal(initial.connection, "unconnected");
  assert.equal(JSON.stringify([...f.storage.data]).includes(data.key), false);
  assert.equal(JSON.stringify(initial).includes("ciphertext"), false);
  f.storage.failWrite = true;
  await assert.rejects(
    f.core.mutate(f.owner, "openai", "replace", mutation(1)),
  );
  f.storage.failWrite = false;
  assert.equal((await f.core.status(f.owner, "openai")).revision, 1);
  await f.core.mutate(f.owner, "openai", "model", {
    requestId: randomUUID(),
    expectedRevision: 1,
    model: "gpt-6-luna",
  });
  const record = f.storage.data.get("credential:openai");
  assert.equal(
    await decrypt(record.blob, f.owner, "openai", 2, f.config.keyring),
    data.key,
  );
  await f.core.mutate(f.owner, "openai", "delete", {
    requestId: randomUUID(),
    expectedRevision: 2,
  });
  assert.equal(f.storage.data.get("credential:openai").blob, null);
  assert.equal((await f.core.status(f.owner, "openai")).state, "deleted");
  await f.core.mutate(f.owner, "openai", "register", mutation(3));
  assert.equal((await f.core.status(f.owner, "openai")).revision, 4);
});
test("owner pinning, extra client owner fields, duplicate IDs, stale versions and replay after deletion cannot change another owner", async () => {
  const f = await fixture();
  const data = mutation();
  await f.core.mutate(f.owner, "openai", "register", data);
  assert.equal(
    (await f.core.mutate(f.owner, "openai", "register", data)).revision,
    1,
  );
  await assert.rejects(
    f.core.mutate(f.owner, "openai", "register", { ...data, key: dummy() }),
    /id-conflict/,
  );
  await assert.rejects(
    f.core.status(await hash("other-owner"), "openai"),
    /owner-mismatch/,
  );
  await assert.rejects(
    f.core.mutate(f.owner, "openai", "replace", {
      ...mutation(1),
      owner: "other",
    }),
  );
  await assert.rejects(
    f.core.mutate(f.owner, "openai", "replace", mutation(0)),
    /revision-conflict/,
  );
  await f.core.mutate(f.owner, "openai", "delete", {
    requestId: randomUUID(),
    expectedRevision: 1,
  });
  assert.equal(
    (await f.core.mutate(f.owner, "openai", "register", data)).state,
    "deleted",
  );
  assert.equal((await f.core.status(f.owner, "anthropic")).revision, 0);
});
test("encryption rotation reads old versions, re-encrypts on replacement, and fails when an old key is missing", async () => {
  const f = await fixture();
  const data = mutation();
  await f.core.mutate(f.owner, "openai", "register", data);
  const old = JSON.parse(f.config.keyring);
  const rotated = {
    active: "test-v2",
    keys: {
      ...old.keys,
      "test-v2": encode(crypto.getRandomValues(new Uint8Array(32))),
    },
  };
  f.core.keyring = JSON.stringify(rotated);
  assert.equal(
    (await f.core.mutate(f.owner, "openai", "register", data)).revision,
    1,
  );
  await f.core.mutate(f.owner, "openai", "replace", mutation(1));
  assert.equal(
    f.storage.data.get("credential:openai").blob.keyVersion,
    "test-v2",
  );
  const latest = f.storage.data.get("credential:openai");
  await assert.rejects(
    decrypt(latest.blob, f.owner, "openai", 2, f.config.keyring),
  );
});
test("CSRF is session/owner-bound and credential mutations are limited to 20/minute", async () => {
  const f = await fixture();
  const principal = {
    subject: "verified-test-owner-a",
    sessionId: "session-a",
  };
  const session = await f.core.session(principal);
  await assert.rejects(
    f.core.authorize({ ...principal, sessionId: "b" }, session.csrfToken, true),
    /csrf-invalid/,
  );
  await assert.rejects(
    f.core.authorize(
      { ...principal, subject: "other" },
      session.csrfToken,
      true,
    ),
    /owner-mismatch/,
  );
  for (let i = 0; i < 20; i++)
    await f.core.authorize(principal, session.csrfToken, true);
  await assert.rejects(
    f.core.authorize(principal, session.csrfToken, true),
    /rate-limit/,
  );
});
const source = {
  id: "rfc8659",
  url: "https://www.rfc-editor.org/rfc/rfc8659.html",
  checkedAt: date,
  body: "The first CAA RRset is selected.",
};
const draft = {
  gap: "test",
  block: {
    id: "test-block",
    title: "test",
    kind: "reading",
    markdown: "最初のRRset",
    visual: "lookup-flow",
  },
  references: [{ sourceId: "rfc8659", quote: source.body }],
};
const proposal = (modelId) => ({
  requestId: randomUUID(),
  bookId: "caa",
  version: "1.8",
  blockId: "read",
  question: "公開のCAA質問",
  excerpt: "CAA",
  purpose: "book-addition",
  modelId,
  sourceIds: ["rfc8659"],
  approvedPublicText: true,
});
const generation = (makeAdapter, extra = {}) => ({
  policy: {
    confirmedCostUpperBounds: true,
    checkedAt: date,
    fixedMilliYen: 496850,
    safetyMilliYen: 0,
    yenPerUsdMilli: 200000,
    taxFeePermille: 1200,
    providerCapsMilliYen: {},
  },
  registry: registry.map((m) => ({
    ...m,
    approval: "test-only",
    dataConditionsAccepted: true,
    tokenCountMargin: 256,
    tokenCountTermsConfirmed: true,
  })),
  selectionPolicy: {},
  sources: [source],
  makeAdapter,
  ...extra,
});
test("each owner gets 500 yen; that owner's providers share budget; reservations precede key resolution/dispatch", async () => {
  let f;
  let calls = 0;
  const gen = generation((provider, secret) => ({
    generate: async () => {
      calls++;
      assert.ok(secret.startsWith("DUMMY-"));
      assert.equal(
        f.storage.data.get("budget").records.at(-1).state,
        "reserved",
      );
      return {
        json: JSON.stringify(draft),
        usage: { inputTokens: 100, outputTokens: 50 },
      };
    },
  }));
  f = await fixture({ generation: gen });
  await f.core.mutate(f.owner, "openai", "register", mutation());
  await f.core.mutate(
    f.owner,
    "anthropic",
    "register",
    mutation(0, { model: "claude-haiku-5-5" }),
  );
  assert.equal(
    (await f.core.propose(f.owner, proposal(registry[0].id))).status,
    "complete",
  );
  assert.equal(
    (await f.core.propose(f.owner, proposal(registry[1].id))).status,
    "complete",
  );
  assert.equal(
    (await f.core.propose(f.owner, proposal(registry[1].id))).status,
    "budget-exhausted",
  );
  const another = await fixture({ generation: gen });
  assert.equal((await another.core.budget(another.owner)).spentMilliYen, 0);
  assert.equal(
    (await another.core.budget(another.owner)).limitMilliYen,
    500000,
  );
  assert.equal(calls, 2);
});
test("uncertain dispatch survives restart/month/key deletion; late results after replacement are suppressed", async () => {
  let release;
  const f = await fixture({
    generation: generation(
      () => ({
        generate: () =>
          new Promise((r) => {
            release = r;
          }),
      }),
      { timeoutMs: 15 },
    ),
  });
  await f.core.mutate(f.owner, "openai", "register", mutation());
  assert.equal(
    (await f.core.propose(f.owner, proposal(registry[0].id))).status,
    "unknown",
  );
  await f.core.mutate(f.owner, "openai", "delete", {
    requestId: randomUUID(),
    expectedRevision: 1,
  });
  await f.core.mutate(f.owner, "openai", "register", mutation(2));
  const restarted = new AccountVaultCore(f.storage, f.config);
  assert.equal(
    (await restarted.propose(f.owner, proposal(registry[0].id))).status,
    "busy",
  );
  assert.ok((await restarted.budget(f.owner)).heldMilliYen > 0);
  release({
    json: JSON.stringify(draft),
    usage: { inputTokens: 100, outputTokens: 50 },
  });
});
test("durability acknowledgement failure never dispatches and retains the committed reservation", async () => {
  let calls = 0;
  const f = await fixture({
    generation: generation(() => {
      calls++;
      throw Error("must not send");
    }),
  });
  await f.core.mutate(f.owner, "openai", "register", mutation());
  // First reads succeed; sync failure specifically on reservation write.
  const sync = f.storage.sync.bind(f.storage);
  f.storage.sync = async () => {
    if (f.storage.data.has("budget")) throw Error("unknown durability");
    return sync();
  };
  await assert.rejects(f.core.propose(f.owner, proposal(registry[0].id)));
  assert.equal(calls, 0);
  assert.equal(f.storage.data.get("budget").records[0].state, "reserved");
});
test("deletion while generation is in flight suppresses late output but retains confirmed cost", async () => {
  let resolve;
  let entered;
  const started = new Promise((r) => {
    entered = r;
  });
  const f = await fixture({
    generation: generation(
      () => ({
        generate: () => {
          entered();
          return new Promise((r) => {
            resolve = r;
          });
        },
      }),
      { timeoutMs: 1000 },
    ),
  });
  await f.core.mutate(f.owner, "openai", "register", mutation());
  const pending = f.core.propose(f.owner, proposal(registry[0].id));
  await started;
  await f.core.mutate(f.owner, "openai", "delete", {
    requestId: randomUUID(),
    expectedRevision: 1,
  });
  resolve({
    json: JSON.stringify(draft),
    usage: { inputTokens: 100, outputTokens: 50 },
  });
  assert.deepEqual(await pending, {
    status: "credential-changed",
    draft: null,
  });
  assert.ok((await f.core.budget(f.owner)).spentMilliYen > 0);
  assert.equal((await f.core.status(f.owner, "openai")).state, "deleted");
});
