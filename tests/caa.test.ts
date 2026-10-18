import { termExplanation } from "../src/term-dictionary";
import { questionSupport } from "../src/question-support";
import { learningPlan } from "../src/learning-plan";
import { describe, it, expect } from "vitest";
import {
  evaluate,
  grade,
  scenarios,
  evaluateName,
  childOnlyTree,
  denyRecords,
  allowRecords,
  lookupStages,
} from "../src/caa";
import { book } from "../src/book";
import { version15Book } from "../src/books/caa-v1-5";
import { legacyBook } from "../src/books/caa-v1";
import {
  historySchema,
  emptyHistory,
  readHistory,
  writeHistory,
} from "../src/history";
describe("RFC 8659 closed subset", () => {
  it("child iodef stops search, without parent merge", () => {
    const r = evaluate("report");
    expect(r.allowed).toBe(true);
    expect(r.owner).toBe("api.example.com");
    expect(r.selected.map((x) => x.tag)).toEqual(["iodef"]);
    expect(r.trace).toHaveLength(2);
  });
  it("absent child adopts parent deny; child deny and allow behave independently", () => {
    expect(evaluate("absent").owner).toBe("example.com");
    expect(evaluate("absent").allowed).toBe(false);
    expect(evaluate("deny").allowed).toBe(false);
    expect(evaluate("allow").allowed).toBe(true);
  });
  it("all diagram cases and question grading share semantics", () => {
    for (const s of scenarios) {
      expect(grade(s.id, "allow")).toBe(evaluate(s.id).allowed);
      expect(grade(s.id, "deny")).toBe(!evaluate(s.id).allowed);
    }
    const q = book.blocks.find((b) => b.kind === "question");
    expect(q?.kind === "question" && grade(q.scenario, "allow")).toBe(true);
  });
});
describe("versioned local history", () => {
  it("handles read failure, malformed data, and write failure", () => {
    expect(
      readHistory({
        getItem: () => {
          throw Error();
        },
      }).error,
    ).toBe(true);
    expect(readHistory({ getItem: () => "{bad" }).error).toBe(true);
    expect(
      writeHistory(
        {
          setItem: () => {
            throw Error();
          },
        },
        emptyHistory(),
      ),
    ).toBe(false);
  });
  it("keeps old attempts when resume changes version", () => {
    const h = emptyHistory();
    h.attempts.push({
      bookId: book.bookId,
      version: "0.9",
      blockId: "predict",
      userId: h.userId,
      attemptId: "old",
      time: new Date().toISOString(),
      answer: "deny",
      correct: false,
    });
    h.resume = {
      bookId: book.bookId,
      version: book.version,
      blockId: "takeaway",
      userId: h.userId,
      time: new Date().toISOString(),
      minutes: 5,
      difficulty: "standard",
    };
    expect(historySchema.parse(h).attempts[0].version).toBe("0.9");
    let raw = "";
    expect(
      writeHistory(
        {
          setItem: (_k, v) => {
            raw = v;
          },
        },
        h,
      ),
    ).toBe(true);
    expect(readHistory({ getItem: () => raw }).history).toEqual(h);
  });
});

describe("child-only policy scope and practical value", () => {
  it("does not apply upward or sideways, but does apply to descendants without a RRset", () => {
    const expected = {
      "child-parent": true,
      "child-self": false,
      "child-descendant": false,
      "child-sibling": true,
      "child-independent": true,
    } as const;
    for (const [scenario, allowed] of Object.entries(expected)) {
      expect(evaluate(scenario as keyof typeof expected).allowed).toBe(allowed);
      expect(
        grade(scenario as keyof typeof expected, allowed ? "allow" : "deny"),
      ).toBe(true);
    }
    expect(evaluate("child-parent").owner).toBeNull();
    expect(
      evaluate("child-sibling").trace.some((t) =>
        t.startsWith("api.example.com:"),
      ),
    ).toBe(false);
    expect(evaluate("child-descendant").owner).toBe("api.example.com");
    expect(evaluate("child-independent").owner).toBe("special.api.example.com");
  });
  it("all independent RRset modes use first-set semantics", () => {
    expect(
      evaluateName(childOnlyTree("none"), "special.api.example.com").allowed,
    ).toBe(false);
    const report = evaluateName(
      childOnlyTree("report"),
      "special.api.example.com",
    );
    expect(report.allowed).toBe(true);
    expect(report.selected.map((r) => r.tag)).toEqual(["iodef"]);
    expect(report.trace.some((t) => t.startsWith("api.example.com:"))).toBe(
      false,
    );
    expect(
      evaluateName(
        childOnlyTree("allow"),
        "special.api.example.com",
        "other-ca.example",
      ).allowed,
    ).toBe(false);
  });
  it("CA restriction is distinct from a full ban, including additive authorizations", () => {
    expect(evaluate("limited-expected").allowed).toBe(true);
    expect(evaluate("limited-other").allowed).toBe(false);
    expect(
      evaluateName(
        { "example.com": [...denyRecords, ...allowRecords] },
        "example.com",
      ).allowed,
    ).toBe(true);
    expect(
      evaluateName(childOnlyTree("none", "allow"), "v1.api.example.com")
        .allowed,
    ).toBe(true);
    expect(
      evaluateName(
        childOnlyTree("none", "allow"),
        "v1.api.example.com",
        "other-ca.example",
      ).allowed,
    ).toBe(false);
  });
  it("new question and application cases are validated and graded with the same evaluator", () => {
    for (const b of book.blocks) {
      if (b.kind === "question") {
        expect(grade(b.scenario, "allow")).toBe(evaluate(b.scenario).allowed);
        expect(grade(b.scenario, "deny")).toBe(!evaluate(b.scenario).allowed);
      }
      if (b.kind === "applications")
        for (const c of b.cases)
          expect(evaluate(c.scenario).allowed).toBe(false);
    }
    expect(book.version).toBe("1.8.0");
    expect(book.contentSchemaVersion).toBe(4);
    expect(legacyBook.version).toBe("1.0.0");
    expect(legacyBook.contentSchemaVersion).toBe(1);
    expect(new Set(book.blocks.map((b) => b.id)).size).toBe(book.blocks.length);
  });
});

describe("lookup flow stages share the verified CAA evaluation", () => {
  it("places candidate, query, selected RRset and judgment in order for every case", () => {
    for (const scenario of scenarios) {
      const result = evaluate(scenario.id);
      const stages = lookupStages(scenario.id);
      expect(stages.filter((s) => s.kind === "query").length).toBe(
        result.lookups.length,
      );
      expect(stages.at(-2)?.kind).toBe("selected");
      expect(stages.at(-1)?.kind).toBe("decision");
      expect(stages.at(-2)?.title).toContain(result.owner!);
      expect(stages.at(-1)?.detail).toBe(result.reason);
      expect(stages.at(-1)?.title.includes("許可")).toBe(result.allowed);
    }
  });
  it("stops at child iodef and only moves to parent when child RRset is absent", () => {
    expect(
      lookupStages("report")
        .filter((s) => s.kind === "candidate")
        .map((s) => s.title),
    ).toEqual(["候補: api.example.com"]);
    expect(
      lookupStages("absent")
        .filter((s) => s.kind === "candidate")
        .map((s) => s.title),
    ).toEqual(["候補: api.example.com", "候補: example.com"]);
  });
});

describe("reading budget boundaries", () => {
  it("chooses whole blocks without hiding the remaining content", () => {
    expect([5, 10, 15, 30].map((m) => learningPlan(0, m).end)).toEqual([
      1, 3, 5, 12,
    ]);
    expect(learningPlan(6, 5)).toEqual({ start: 6, end: 8, estimate: 3 });
    expect(learningPlan(12, 30)).toEqual({ start: 12, end: 12, estimate: 3 });
  });
});

describe("selection-specific question support", () => {
  it("matches grading and keeps targeted misconceptions separate", () => {
    for (const block of book.blocks)
      if (block.kind === "question")
        for (const answer of ["allow", "deny"] as const) {
          const support = questionSupport(block.scenario, answer);
          expect(support.correct).toBe(grade(block.scenario, answer));
          expect(support.result).toEqual(evaluate(block.scenario));
          expect(support.focus.length).toBeGreaterThan(0);
        }
    expect(questionSupport("report", "deny").id).toBe("merge-parent");
    expect(questionSupport("child-sibling", "deny").id).toBe("sideways");
    expect(questionSupport("child-descendant", "allow").id).toBe("descendants");
    expect(questionSupport("limited-other", "allow").id).toBe("any-ca");
  });
});

describe("contextual static term explanations", () => {
  it("distinguishes lookup, independent sets and additive CA authorization", () => {
    expect(termExplanation("rrset", "read").context).toContain(
      "親と子の集合は合算しません",
    );
    expect(termExplanation("rrset", "limits").context).toContain(
      "空の issue が他の許可を取り消す",
    );
    expect(termExplanation("rrset", "renewal-predict").context).toContain(
      "更新先の CA",
    );
    expect(termExplanation("iodef", "boundary").context).toContain(
      "子孫の独自 RRset",
    );
    expect(termExplanation("iodef", "read").example).toContain(
      "通知の送信・到達を保証しません",
    );
  });
});

describe("four additional terms use primary sources and separate roles", () => {
  it("distinguishes the CA, DNS roles, and DNSSEC from CAA", () => {
    const ca = termExplanation("lets-encrypt", "read");
    expect(ca.definition).toContain("認証局");
    expect(ca.example).toContain('issue "letsencrypt.org"');
    expect(ca.source.url).toBe("https://letsencrypt.org/about/");
    expect(termExplanation("resolver", "read").detail).toContain(
      "依頼者に代わって",
    );
    expect(termExplanation("authoritative-dns", "read").definition).toContain(
      "正式なレコード",
    );
    const dnssec = termExplanation("dnssec", "limits");
    expect(dnssec.detail).toContain("通信を暗号化");
    expect(dnssec.context).toContain("既存の証明書も失効させません");
    expect(dnssec.source.url).toContain("rfc4033");
  });
});

it("preserves v1.5 and shows four outcomes only at the book entry", () => {
  expect(version15Book.version).toBe("1.5.0");
  expect(
    book.blocks.filter((b) => b.kind === "reading" && b.outcomes),
  ).toHaveLength(1);
  const first = book.blocks[0];
  expect(first.kind === "reading" && first.outcomes?.length).toBe(4);
});

describe("immutable diagram prediction snapshots and additive history", () => {
  it("grades all snapshots with the shared semantics, skips are ungraded", async () => {
    const { scenarioSnapshot, comparePrediction } =
      await import("../src/diagram-learning");
    for (const scenario of scenarios)
      for (const choice of ["allow", "deny", null] as const) {
        const p = {
          bookId: book.bookId,
          version: book.version,
          blockId: "explore",
          userId: "test",
          attemptId: "test",
          time: new Date().toISOString(),
          snapshot: scenarioSnapshot(scenario.id),
          prediction: choice,
          reason: "",
        };
        const compared = comparePrediction(p);
        expect(compared.result.allowed).toBe(evaluate(scenario.id).allowed);
        expect(compared.correct).toBe(
          choice === null ? null : grade(scenario.id, choice),
        );
      }
    const snapshot = scenarioSnapshot("report");
    expect(snapshot.tree["api.example.com"]).not.toBe(scenarios[1].records);
    expect(snapshot.tree["api.example.com"][0]).not.toBe(
      scenarios[1].records[0],
    );
  });
  it("loads old history without losing answers and blocks malformed new records", () => {
    const old = emptyHistory();
    const legacy = {
      schemaVersion: old.schemaVersion,
      userId: old.userId,
      attempts: old.attempts,
      resume: old.resume,
    };
    const read = readHistory({ getItem: () => JSON.stringify(legacy) });
    expect(read.error).toBe(false);
    expect(read.history.diagramPredictions).toEqual([]);
    expect(read.history.diagramReflections).toEqual([]);
    expect(
      readHistory({
        getItem: () =>
          JSON.stringify({
            ...legacy,
            diagramPredictions: [{ attemptId: "bad" }],
          }),
      }).error,
    ).toBe(true);
  });
});

describe("local question proposals and version safety", () => {
  it("applies a typed addition and keeps the base immutable", async () => {
    const { proposalSchema, applyProposal, activeLocalBook, proposalProblem } =
      await import("../src/improvements");
    const now = new Date("2026-10-11T12:00:00Z");
    const p = proposalSchema.parse({
      bookId: book.bookId,
      version: book.version,
      blockId: "read",
      userId: "test",
      time: now.toISOString(),
      proposalId: "proposal",
      questionId: "question",
      originVersion: "1.7.0",
      mode: "manual",
      gap: "CAA と DNSSEC の違い",
      sourceUrl: "https://www.rfc-editor.org/rfc/rfc4033.html",
      checkedOn: "2026-10-11",
      evidence: "§3–4 の役割と限界",
      block: {
        id: "local-dns-proof",
        title: "DNSSEC の役割",
        kind: "reading",
        markdown: "DNSSEC は通信を暗号化しません。",
      },
    });
    const next = applyProposal(book, p, [], "one", now);
    expect(next.blocks).toHaveLength(book.blocks.length + 1);
    expect(book.blocks).toHaveLength(13);
    expect(next.version).not.toBe(book.version);
    expect(next.blocks[1].id).toBe(p.block.id);
    const revision = {
      bookId: book.bookId,
      version: next.version,
      blockId: "read",
      userId: "test",
      time: now.toISOString(),
      revisionId: "one",
      proposalId: p.proposalId,
      baseVersion: book.version,
      book: next,
    };
    expect(activeLocalBook(book, [revision]).version).toBe(next.version);
    expect(proposalProblem(p, next, [], now)).toContain("教材版");
    expect(
      proposalProblem({ ...p, checkedOn: "2025-01-01" }, book, [], now),
    ).toContain("30日超");
    expect(
      proposalProblem({ ...p, checkedOn: "2026-02-30" }, book, [], now),
    ).toContain("出典確認日");
    expect(
      proposalProblem(
        { ...p, sourceUrl: "javascript:alert(1)" },
        book,
        [],
        now,
      ),
    ).toContain("HTTPS");
    expect(
      proposalProblem({ ...p, block: book.blocks[0] }, book, [], now),
    ).toContain("重複");
    const cancel = {
      bookId: book.bookId,
      version: book.version,
      blockId: "read",
      userId: "test",
      time: now.toISOString(),
      eventId: "cancel",
      proposalId: p.proposalId,
      action: "cancel" as const,
    };
    expect(() => applyProposal(book, p, [cancel], "two", now)).toThrow(/取消/);
  });
  it("defaults all new history fields and preserves old answers", () => {
    const h = emptyHistory();
    const old = {
      schemaVersion: 1,
      userId: h.userId,
      attempts: [
        {
          bookId: book.bookId,
          version: "1.7.0",
          blockId: "predict",
          userId: h.userId,
          time: new Date().toISOString(),
          attemptId: "old",
          answer: "deny",
          correct: false,
        },
      ],
      resume: null,
    };
    const migrated = historySchema.parse(old);
    expect(migrated.attempts).toEqual(old.attempts);
    expect(migrated.questions).toEqual([]);
    expect(migrated.recalls).toEqual([]);
    expect(migrated.bookRevisions).toEqual([]);
  });
});

it("merges parsed history by IDs without duplicating or reordering old answers", async () => {
  const { mergeHistoryRecords } = await import("../src/history");
  const h = emptyHistory();
  h.attempts.push({
    bookId: book.bookId,
    version: book.version,
    blockId: "predict",
    userId: h.userId,
    time: new Date().toISOString(),
    attemptId: "one",
    answer: "allow",
    correct: true,
  });
  mergeHistoryRecords(h, historySchema.parse(h));
  expect(h.attempts).toHaveLength(1);
});
