import { describe, it, expect } from "vitest";
import { MockByok, type MockResult } from "../src/byok";
const ok = async () => "ok" as const;
describe("BYOK dummy metadata only", () => {
  it("isolates owners/providers and uses copies without accepting key input", async () => {
    const store = new MockByok();
    await store.run("demo-a", "openai", "register", ok);
    expect(store.view("demo-b", "openai").setting).toBeNull();
    expect(store.view("demo-a", "anthropic").setting).toBeNull();
    const copy = store.view("demo-a", "openai");
    copy.setting!.model = "changed";
    expect(store.view("demo-a", "openai").setting!.model).toBe("gpt-6-luna");
    expect(store.selectModel("demo-a", "openai", "unknown")).toBe(false);
    expect(JSON.stringify(copy)).not.toContain("secret");
  });
  it("registers/checks/replaces/deletes/re-registers while preserving the other owner", async () => {
    const store = new MockByok();
    expect(await store.run("demo-a", "openai", "verify", ok)).toBe(false);
    await store.run("demo-a", "openai", "register", ok);
    const first = store.view("demo-a", "openai").setting!.revision;
    await store.run("demo-b", "openai", "register", ok);
    await store.run("demo-a", "openai", "verify", ok);
    expect(store.view("demo-a", "openai").setting!.checked).toBe(true);
    store.selectModel("demo-a", "openai", "gpt-6-luna");
    expect(store.view("demo-a", "openai").setting!.checked).toBe(false);
    await store.run("demo-a", "openai", "replace", ok);
    expect(store.view("demo-a", "openai").setting!.revision).toBeGreaterThan(
      first,
    );
    store.remove("demo-a", "openai");
    expect(store.view("demo-a", "openai").setting).toBeNull();
    expect(store.view("demo-b", "openai").setting).not.toBeNull();
    await store.run("demo-a", "openai", "register", ok);
    expect(store.view("demo-a", "openai").setting!.revision).toBeGreaterThan(
      first,
    );
    expect(new MockByok().view("demo-a", "openai").setting).toBeNull();
  });
  it("failure preserves the original metadata and never echoes sender errors", async () => {
    const store = new MockByok();
    await store.run("demo-a", "anthropic", "register", ok);
    await store.run("demo-a", "anthropic", "verify", ok);
    const original = store.view("demo-a", "anthropic").setting;
    await store.run("demo-a", "anthropic", "replace", async () => {
      throw Error("PRIVATE-DUMMY-VALUE");
    });
    expect(store.view("demo-a", "anthropic").setting).toEqual(original);
    expect(JSON.stringify(store.view("demo-a", "anthropic"))).not.toContain(
      "PRIVATE-DUMMY-VALUE",
    );
  });
  it("deduplicates, aborts, and ignores late completion after deletion/new registration", async () => {
    let resolve!: (result: MockResult) => void;
    let calls = 0;
    let aborted = false;
    const store = new MockByok();
    const pending = store.run("demo-a", "openai", "register", (signal) => {
      calls++;
      signal.addEventListener("abort", () => {
        aborted = true;
      });
      return new Promise((r) => {
        resolve = r;
      });
    });
    expect(await store.run("demo-a", "openai", "register", ok)).toBe(false);
    expect(calls).toBe(1);
    store.remove("demo-a", "openai");
    await store.run("demo-a", "openai", "register", ok);
    const current = store.view("demo-a", "openai").setting;
    resolve("ok");
    await pending;
    expect(aborted).toBe(true);
    expect(store.view("demo-a", "openai").setting).toEqual(current);
  });
  it("owner cancellation stops only its pending operations, preserving existing checked settings", async () => {
    const store = new MockByok();
    await store.run("demo-a", "openai", "register", ok);
    await store.run("demo-a", "openai", "verify", ok);
    const waiting = (signal: AbortSignal) =>
      new Promise<MockResult>((_, reject) =>
        signal.addEventListener("abort", () => reject(Error("cancelled"))),
      );
    const a = store.run("demo-a", "openai", "replace", waiting);
    const b = store.run("demo-b", "anthropic", "register", waiting);
    store.cancelOwner("demo-a");
    await a;
    expect(store.view("demo-a", "openai").setting!.checked).toBe(true);
    expect(store.view("demo-b", "anthropic").pending).toBe("register");
    store.cancelOwner("demo-b");
    await b;
    expect(store.view("demo-b", "anthropic").setting).toBeNull();
  });
});
