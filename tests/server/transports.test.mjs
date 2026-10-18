import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { openaiTransport } from "../../server/openai-transport.mjs";
import { anthropicTransport } from "../../server/anthropic-transport.mjs";
import { GenerationService, usageCostMilliYen } from "../../server/service.mjs";
import { FileLedger } from "../../server/ledger.mjs";
import { registry } from "../../server/registry.mjs";
import {
  minimalPayload,
  normalizeOutput,
  outputSchema,
} from "../../server/provider-format.mjs";
const date = "2026-10-11T00:00:00.000Z";
const secret = "TEST-ONLY-NOT-A-REAL-SECRET";
const source = {
  id: "rfc8659",
  url: "https://www.rfc-editor.org/rfc/rfc8659.html",
  checkedAt: date,
  body: "The first CAA RRset is selected.",
};
const payload = {
  question: "どこで探索を止める？",
  excerpt: "CAA の探索",
  sources: [{ id: source.id, body: source.body }],
};
const wire = {
  gap: "探索の理解",
  block: {
    id: "extra",
    title: "探索",
    kind: "reading",
    markdown: "最初の CAA RRset を採用します。",
    visual: "lookup-flow",
    prompt: null,
    scenario: null,
  },
  references: [{ sourceId: "rfc8659", quote: source.body }],
};
const request = () => ({
  requestId: randomUUID(),
  bookId: "PRIVATE-BOOK-ID",
  version: "PRIVATE-VERSION",
  blockId: "PRIVATE-BLOCK-ID",
  purpose: "book-addition",
  question: payload.question,
  excerpt: payload.excerpt,
  sourceIds: ["rfc8659"],
  approvedPublicText: true,
});
const policy = {
  confirmedCostUpperBounds: true,
  checkedAt: date,
  fixedMilliYen: 0,
  safetyMilliYen: 0,
  yenPerUsdMilli: 200000,
  taxFeePermille: 1200,
  providerCapsMilliYen: {},
};
const providers = [
  {
    name: "openai",
    make: openaiTransport,
    candidate: registry[0],
    response: () => ({
      model: "gpt-6-luna",
      status: "completed",
      service_tier: "default",
      output: [
        {
          type: "message",
          content: [{ type: "output_text", text: JSON.stringify(wire) }],
        },
      ],
      usage: {
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_tokens_details: { cached_tokens: 20 },
        output_tokens_details: { reasoning_tokens: 10 },
      },
    }),
  },
  {
    name: "anthropic",
    make: anthropicTransport,
    candidate: registry[1],
    response: () => ({
      model: "claude-haiku-5-5",
      type: "message",
      stop_reason: "end_turn",
      content: [{ type: "text", text: JSON.stringify(wire) }],
      usage: {
        input_tokens: 70,
        cache_creation_input_tokens: 20,
        cache_read_input_tokens: 10,
        output_tokens: 50,
        service_tier: "standard",
        inference_geo: "global",
      },
    }),
  },
];
function mock(values) {
  const calls = [];
  const send = async (url, options) => {
    calls.push({ url, options, body: JSON.parse(options.body) });
    const value = values.shift();
    if (typeof value === "function") return value(url, options);
    if (value instanceof Error) throw value;
    return new Response(JSON.stringify(value), { status: 200 });
  };
  return { send, calls };
}
const options = (p, extra = {}) => ({
  model: p.candidate.model,
  inputTokens: 8000,
  outputTokens: 2000,
  retries: 0,
  store: false,
  tools: [],
  tokenCountMargin: 256,
  tokenCountTermsConfirmed: true,
  signal: new AbortController().signal,
  ...extra,
});
async function fixture(t, p, network, extra = {}) {
  const dir = await mkdtemp(join(tmpdir(), "caa-provider-mock-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const model = {
    ...p.candidate,
    approval: "test-only",
    dataConditionsAccepted: true,
    tokenCountMargin: 256,
    tokenCountTermsConfirmed: true,
  };
  const config = {
    ledger: new FileLedger(dir),
    policy,
    registry: [model],
    selectionPolicy: { "book-addition": model.id },
    adapters: {
      [p.name]: p.make({ send: network.send, secret, mockOnly: true }),
    },
    sources: [source],
    now: () => new Date(date),
    ...extra,
  };
  return {
    dir,
    config,
    service: new GenerationService(config),
    record: async () =>
      JSON.parse(await readFile(join(dir, "budget.json"), "utf8")).records[0],
  };
}
for (const p of providers) {
  test(`${p.name}: same full schema/prompt counted, minimal payload sent once, usage normalized`, async () => {
    const n = mock([{ input_tokens: 100 }, p.response()]);
    const result = await p
      .make({ send: n.send, secret, mockOnly: true })
      .generate(payload, options(p));
    assert.equal(result.outcome, "complete");
    assert.deepEqual(result.usage, { inputTokens: 100, outputTokens: 50 });
    assert.equal(JSON.parse(result.json).block.markdown, wire.block.markdown);
    assert.equal(n.calls.length, 2);
    const [count, generate] = n.calls;
    for (const key of Object.keys(count.body))
      assert.deepEqual(generate.body[key], count.body[key]);
    assert.deepEqual(
      JSON.parse((count.body.input ?? count.body.messages)[0].content),
      payload,
    );
    assert.equal(generate.options.redirect, "error");
    assert.equal(
      generate.body.max_output_tokens ?? generate.body.max_tokens,
      2000,
    );
    assert.equal(
      generate.options.headers.Authorization ??
        generate.options.headers["x-api-key"],
      p.name === "openai" ? `Bearer ${secret}` : secret,
    );
    assert.equal(JSON.stringify(generate.body).includes(secret), false);
    assert.equal(JSON.stringify(generate.body).includes("user_id"), false);
    assert.deepEqual(
      count.body.text?.format.schema ?? count.body.output_config.format.schema,
      outputSchema,
    );
    if (p.name === "openai") {
      assert.equal(generate.body.store, false);
      assert.deepEqual(generate.body.tools, []);
    } else {
      assert.equal(generate.body.inference_geo, "global");
      assert.equal(generate.body.cache_control, undefined);
    }
  });
  test(`${p.name}: actual prepared transport/default candidates never dispatch`, async (t) => {
    const n = mock([]);
    const f = await fixture(t, p, n);
    f.config.adapters[p.name] = p.make({ send: n.send, secret });
    assert.equal(
      (await new GenerationService(f.config).propose(request())).status,
      "unconnected",
    );
    assert.equal(
      (
        await new GenerationService({ ...f.config, registry }).propose(
          request(),
        )
      ).status,
      "unconnected",
    );
    assert.equal(n.calls.length, 0);
    await assert.rejects(readFile(join(f.dir, "budget.json")));
  });
  test(`${p.name}: count bound, missing approval/margin and credential never start generation`, async (t) => {
    const n = mock([{ input_tokens: 7999 }]);
    const result = await p
      .make({ send: n.send, secret, mockOnly: true })
      .generate(payload, options(p));
    assert.equal(result.outcome, "input-limit");
    assert.equal(n.calls.length, 1);
    const blocked = mock([]);
    const f = await fixture(t, p, blocked);
    f.config.registry[0].tokenCountMargin = null;
    assert.equal(
      (await f.service.propose(request())).status,
      "count-unconfigured",
    );
    const adapter = p.make({ send: blocked.send, secret, mockOnly: true });
    await assert.rejects(
      adapter.generate(
        payload,
        options(p, { tokenCountTermsConfirmed: false }),
      ),
    );
    await assert.rejects(
      p
        .make({ send: blocked.send, mockOnly: true })
        .generate(payload, options(p)),
    );
    assert.equal(blocked.calls.length, 0);
  });
  test(`${p.name}: reservation persisted before count; replay skips network and records usage without identity/secret`, async (t) => {
    let f;
    const n = mock([
      async () => {
        assert.equal((await f.record()).state, "reserved");
        return new Response('{"input_tokens":100}');
      },
      p.response(),
    ]);
    f = await fixture(t, p, n);
    const input = request();
    assert.equal((await f.service.propose(input)).status, "complete");
    assert.equal(
      (await new GenerationService(f.config).propose(input)).status,
      "complete",
    );
    const r = await f.record();
    assert.deepEqual(r.usage, { inputTokens: 100, outputTokens: 50 });
    assert.equal(
      r.spentMilliYen,
      usageCostMilliYen(policy, p.candidate, r.usage),
    );
    const text = JSON.stringify(n.calls);
    for (const privateValue of [
      input.requestId,
      input.bookId,
      input.version,
      input.blockId,
      date,
    ])
      assert.equal(text.includes(privateValue), false);
    assert.equal(JSON.stringify(r).includes(secret), false);
    assert.equal(n.calls.length, 2);
  });
  test(`${p.name}: missing usage, count failure, HTTP errors and oversized response retain reservation with no retry`, async (t) => {
    const invalid = p.response();
    delete invalid.usage;
    for (const values of [
      [{ input_tokens: 100 }, invalid],
      [new Error(secret)],
      [{ input_tokens: "100" }],
      [() => new Response(secret, { status: 500 })],
      [() => new Response("x".repeat(65537))],
    ]) {
      const n = mock(values);
      const f = await fixture(t, p, n);
      assert.equal((await f.service.propose(request())).status, "unknown");
      assert.equal((await f.service.propose(request())).status, "busy");
      assert.equal((await f.record()).spentMilliYen, 0);
      assert.ok(n.calls.length <= 2);
      assert.equal(JSON.stringify(await f.record()).includes(secret), false);
    }
  });
  test(`${p.name}: paid refusal, cutoff, invalid JSON/code/source are rejected and usage still counted`, async (t) => {
    const refusal = p.response();
    const cutoff = p.response();
    if (p.name === "openai") {
      refusal.output[0].content = [{ type: "refusal", refusal: "refused" }];
      cutoff.status = "incomplete";
    } else {
      refusal.stop_details = { type: "refusal" };
      cutoff.stop_reason = "max_tokens";
    }
    const bad = (text) => {
      const r = p.response();
      (r.output?.[0].content[0] ?? r.content[0]).text = text;
      return r;
    };
    for (const response of [
      refusal,
      cutoff,
      bad("invalid"),
      bad(
        JSON.stringify({
          ...wire,
          block: { ...wire.block, markdown: "<script>alert(1)</script>" },
        }),
      ),
      bad(
        JSON.stringify({
          ...wire,
          references: [{ sourceId: "rfc8659", quote: "unverified" }],
        }),
      ),
    ]) {
      const n = mock([{ input_tokens: 100 }, response]);
      const f = await fixture(t, p, n);
      assert.equal((await f.service.propose(request())).status, "rejected");
      assert.ok((await f.record()).spentMilliYen > 0);
      assert.equal(n.calls.length, 2);
    }
  });
  test(`${p.name}: abort during delayed count never dispatches generation later`, async (t) => {
    let resolve;
    let entered;
    const counted = new Promise((r) => {
      entered = r;
    });
    const n = mock([
      () => {
        entered();
        return new Promise((r) => {
          resolve = r;
        });
      },
    ]);
    const f = await fixture(t, p, n, { timeoutMs: 20 });
    const pending = f.service.propose(request());
    await counted;
    assert.equal((await pending).status, "unknown");
    resolve(new Response('{"input_tokens":100}'));
    // Await promise/microtask drain, not an arbitrary network timeout.
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(n.calls.length, 1);
    assert.equal(
      (await new GenerationService(f.config).propose(request())).status,
      "busy",
    );
  });
  test(`${p.name}: usage beyond reservation or wrong model/tier is never settled as safe`, async (t) => {
    for (const mutate of [
      (r) => {
        r.model = "unapproved";
      },
      (r) => {
        r.usage.input_tokens = 9000;
        if (p.name === "openai") r.usage.total_tokens = 9050;
      },
      (r) => {
        if (p.name === "openai") r.service_tier = "priority";
        else r.usage.server_tool_use = { web_search_requests: 1 };
      },
    ]) {
      const response = p.response();
      mutate(response);
      const n = mock([{ input_tokens: 100 }, response]);
      const f = await fixture(t, p, n);
      assert.equal((await f.service.propose(request())).status, "unknown");
      assert.equal((await f.record()).state, "unknown");
    }
  });
}
test("wire schema rejects cross-field ambiguity and privacy extras; zero output is counted", () => {
  assert.throws(() =>
    normalizeOutput(
      JSON.stringify({ ...wire, block: { ...wire.block, prompt: "question" } }),
    ),
  );
  assert.throws(() =>
    minimalPayload({ ...payload, history: [], userId: "private" }),
  );
  assert.equal(
    usageCostMilliYen(policy, registry[0], {
      inputTokens: 100,
      outputTokens: 0,
    }),
    6,
  );
});
test("both provider protocols share one budget, without fallback when insufficient", async (t) => {
  const n1 = mock([{ input_tokens: 100 }, providers[0].response()]);
  const n2 = mock([]);
  const f = await fixture(t, providers[0], n1, {
    policy: { ...policy, fixedMilliYen: 499100 },
  });
  const second = {
    ...registry[1],
    approval: "test-only",
    dataConditionsAccepted: true,
    tokenCountMargin: 256,
    tokenCountTermsConfirmed: true,
  };
  f.config.registry.push(second);
  f.config.adapters.anthropic = anthropicTransport({
    send: n2.send,
    secret,
    mockOnly: true,
  });
  assert.equal((await f.service.propose(request())).status, "complete");
  assert.equal(
    (await f.service.propose({ ...request(), modelId: second.id })).status,
    "budget-exhausted",
  );
  assert.equal(n2.calls.length, 0);
});

test("fixed endpoints reject redirects even when a mock sender follows them", async () => {
  for (const p of providers) {
    const n = mock([
      () => {
        const response = new Response('{"input_tokens":100}');
        Object.defineProperty(response, "redirected", { value: true });
        Object.defineProperty(response, "url", {
          value: "https://unapproved.example/",
        });
        return response;
      },
    ]);
    await assert.rejects(
      p
        .make({ send: n.send, secret, mockOnly: true })
        .generate(payload, options(p)),
      /provider-unknown/,
    );
    assert.equal(n.calls.length, 1);
  }
});
