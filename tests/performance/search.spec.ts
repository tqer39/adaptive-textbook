import { test, expect } from "@playwright/test";
import { writeFile } from "node:fs/promises";
// Separate origin/profile: never seed or mutate the user's preview database.
test("100k originals and translations: input to painted results, correctness and contention", async ({
  page,
  context,
  browser,
}, info) => {
  const report: Record<string, unknown> = {
    browser: browser.version(),
    os: await page.evaluate(() => navigator.userAgent),
    corpus: 100000,
    originalBytes: 2048,
    translationBytes: 2048,
    samples: [],
  };
  const samples: { group: string; query: string; ms: number }[] = [];
  report.samples = samples;
  try {
    await page.goto("/?view=feeds");
    await expect(
      page.getByRole("button", { name: "フィードを探す", exact: true }),
    ).toBeEnabled();
    const seedStart = Date.now();
    await page.evaluate(async () => {
      const db = await new Promise<IDBDatabase>((resolve, reject) => {
        const r = indexedDB.open("tsumiki.rss.v1");
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
      });
      for (let start = 0; start < 100000; start += 500) {
        await new Promise<void>((resolve, reject) => {
          const tx = db.transaction("articles", "readwrite");
          const store = tx.objectStore("articles");
          for (let i = start; i < start + 500; i++) {
            const id = i.toString().padStart(6, "0");
            const header = `Article ${id} SQLite ${i % 100 === 0 ? "cohort" : "ordinary"} `;
            const body = header + "a".repeat(2048 - header.length);
            const lead = `日本語翻訳 ${id} ${i % 100 === 0 ? "対象集合" : "通常記事"} `;
            const bytes = new TextEncoder().encode(lead).length;
            const translated =
              lead +
              "文".repeat(Math.floor((2048 - bytes) / 3)) +
              "x".repeat((2048 - bytes) % 3);
            store.put({
              id,
              title: `Article ${id}`,
              body,
              url: "",
              feedUrl: "",
              published: null,
              fetchedAt: "2026-10-24T00:00:00Z",
              saved: i % 10 === 0,
              read: i % 2 === 0,
              translation: {
                text: translated,
                sourceText: body,
                sourceLanguage: "en",
                targetLanguage: "ja",
              },
            });
          }
          tx.oncomplete = () => resolve();
          tx.onerror = tx.onabort = () => reject(tx.error);
        });
      }
      db.close();
    });
    report.seedMs = Date.now() - seedStart;
    const readyStart = Date.now();
    await page.reload();
    await page.getByLabel("保存領域の記事を検索").fill("不存在");
    await expect(page.locator("#rss-search-status")).toHaveText(
      "0件 · 0–0件を表示",
      { timeout: 120000 },
    );
    report.loadAndPrepareMs = Date.now() - readyStart;
    const writer = await context.newPage();
    // Same origin, no app: the writer owns one explicit transaction at a time.
    await writer.goto("/favicon.ico");
    const cases = [
      { query: "ＳＱＬｉｔｅ 099999", expected: ["Article 099999"], total: 1 },
      {
        query: "対象集合",
        expected: Array.from(
          { length: 50 },
          (_, i) => `Article ${(i * 100).toString().padStart(6, "0")}`,
        ),
        total: 1000,
      },
      { query: "does-not-exist", expected: [], total: 0 },
    ];
    for (const group of ["idle", "held-write", "continuous-write"]) {
      await writer.evaluate(async (group) => {
        const w = window as unknown as {
          stop: boolean;
          commits: number[];
          held: boolean;
        };
        w.stop = false;
        w.commits = [];
        w.held = false;
        if (group === "idle") return;
        const db = await new Promise<IDBDatabase>((resolve) => {
          const r = indexedDB.open("tsumiki.rss.v1");
          r.onsuccess = () => resolve(r.result);
        });
        if (group === "held-write") {
          const tx = db.transaction("articles", "readwrite");
          const store = tx.objectStore("articles");
          store.put({ id: "held-probe" });
          const keep = () => {
            if (w.stop) {
              tx.abort();
              db.close();
              return;
            }
            const r = store.get("000001");
            r.onsuccess = keep;
          };
          w.held = true;
          tx.onabort = () => {
            w.held = false;
          };
          keep();
        } else {
          const write = () => {
            if (w.stop) {
              db.close();
              return;
            }
            const tx = db.transaction("articles", "readwrite");
            const store = tx.objectStore("articles");
            const r = store.get("000001");
            r.onsuccess = () => {
              const body =
                r.result.body.slice(0, 2000) +
                " writer-generation-" +
                w.commits.length;
              store.put({
                ...r.result,
                body,
                translation: {
                  ...r.result.translation,
                  sourceText: body,
                  text:
                    r.result.translation.text.slice(0, 600) +
                    " 書込世代" +
                    w.commits.length,
                },
              });
            };
            tx.oncomplete = () => {
              w.commits.push(Date.now());
              const channel = new BroadcastChannel("tsumiki.rss.v1");
              channel.postMessage({ articleId: "000001" });
              channel.close();
              setTimeout(write, 20);
            };
          };
          write();
        }
      }, group);
      for (const c of cases) {
        const start = Date.now();
        for (let i = 0; i < 30; i++) {
          const ms = await page.evaluate(async ({ query, expected, total }) => {
            const input =
              document.querySelector<HTMLInputElement>("#rss-search")!;
            const start = performance.now();
            input.value = query;
            input.dispatchEvent(new Event("input", { bubbles: true }));
            await new Promise<void>((resolve) =>
              requestAnimationFrame(() =>
                requestAnimationFrame(() => resolve()),
              ),
            );
            const actual = Array.from(
              document.querySelectorAll(".rss-article-title"),
              (n) => n.textContent,
            );
            if (JSON.stringify(actual) !== JSON.stringify(expected))
              throw Error("Incorrect result identities");
            if (
              !document
                .querySelector("#rss-search-status")
                ?.textContent?.startsWith(`${total}件 ·`)
            )
              throw Error("Incorrect total");
            return performance.now() - start;
          }, c);
          samples.push({ group, query: c.query, ms });
        }
        const end = Date.now();
        if (group === "continuous-write") {
          const commits = await writer.evaluate(
            () => (window as unknown as { commits: number[] }).commits,
          );
          expect(commits.some((t) => t > start && t < end)).toBe(true);
        }
      }
      await writer.evaluate(() => {
        (window as unknown as { stop: boolean }).stop = true;
      });
      if (group === "held-write")
        await expect
          .poll(() =>
            writer.evaluate(
              () => (window as unknown as { held: boolean }).held,
            ),
          )
          .toBe(false);
      if (group === "continuous-write") {
        const commits = await writer.evaluate(
          () => (window as unknown as { commits: number[] }).commits,
        );
        report.writerCommits = commits;
        // The changed original and translation must both become searchable in the reader.
        await page
          .getByLabel("保存領域の記事を検索")
          .fill("writer-generation-");
        await expect(page.locator(".rss-article-title")).toHaveText(
          "Article 000001",
        );
        await page.getByLabel("保存領域の記事を検索").fill("書込世代");
        await expect(page.locator(".rss-article-title")).toHaveText(
          "Article 000001",
        );
      }
    }
    // Full traversal of the 1,000 matches, independent of the page-size cap.
    await page.getByLabel("保存領域の記事を検索").fill("対象集合");
    const ids: string[] = [];
    for (let i = 0; i < 20; i++) {
      ids.push(...(await page.locator(".rss-article-title").allTextContents()));
      if (i < 19)
        await page
          .getByRole("button", { name: "次の50件", exact: true })
          .click();
    }
    expect(ids).toEqual(
      Array.from(
        { length: 1000 },
        (_, i) => `Article ${(i * 100).toString().padStart(6, "0")}`,
      ),
    );
    report.maxMs = Math.max(...samples.map((s) => s.ms));
    expect(
      samples.filter((s) => s.ms >= 200),
      "Every measured input-to-paint sample must be under 200 ms",
    ).toEqual([]);
    await writer.close();
  } finally {
    await writeFile(
      info.outputPath("measurements.json"),
      JSON.stringify(report, null, 2),
    );
  }
});
