import { test, expect } from "@playwright/test";
async function seed(page: import("@playwright/test").Page, count = 125) {
  await page.goto("/?view=feeds");
  await expect(
    page.getByRole("button", { name: "フィードを探す", exact: true }),
  ).toBeEnabled();
  await page.evaluate(async (count) => {
    await new Promise<void>((resolve, reject) => {
      const r = indexedDB.open("tsumiki.rss.v1");
      r.onsuccess = () => {
        const db = r.result;
        const tx = db.transaction("articles", "readwrite");
        const store = tx.objectStore("articles");
        for (let i = 0; i < count; i++) {
          const body = `original ${i} SQLite 分散 ${i === 99 ? "特別な原文" : "普通の本文"}`;
          store.put({
            id: `id-${i.toString().padStart(6, "0")}`,
            title: `記事 ${i}`,
            body,
            url: "",
            feedUrl: "",
            read: i % 2 === 0,
            saved: i % 5 === 0,
            published: null,
            fetchedAt: "2026-10-24T00:00:00Z",
            translation: {
              text: `訳文 ${i === 99 ? "固有の翻訳" : "普通の訳"}`,
              sourceText: body,
              sourceLanguage: "en",
              targetLanguage: "ja",
            },
          });
        }
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
      };
    });
  }, count);
  await page.reload();
  await expect(page.locator("#rss-search-status")).toContainText(`${count}件`);
}
test("originals and translations are searchable; clear, saved and unread filters work", async ({
  page,
}) => {
  await seed(page);
  await page.getByLabel("保存領域の記事を検索").fill("ＳＱＬｉｔｅ　特別");
  await expect(page.locator(".rss-article-list li")).toHaveCount(1);
  await expect(page.locator(".rss-article-list")).toContainText("記事 99");
  await page.getByLabel("保存領域の記事を検索").fill("固有の翻訳");
  await expect(page.locator(".rss-article-list li")).toHaveCount(1);
  await page.getByRole("button", { name: /保存した記事 ·/ }).click();
  await expect(page.locator(".rss-empty")).toContainText(
    "一致する記事はありません",
  );
  await page.getByRole("button", { name: /未読 ·/ }).click();
  await expect(page.locator(".rss-article-list")).toContainText("記事 99");
  await page.getByRole("button", { name: "検索を解除", exact: true }).click();
  await expect(page.getByLabel("保存領域の記事を検索")).toHaveValue("");
  await expect(page.locator("#rss-search-status")).toContainText("62件");
});
test("pagination exposes every result once and resets after query changes", async ({
  page,
}, info) => {
  await seed(page);
  const titles: string[] = [];
  for (let i = 0; i < 3; i++) {
    titles.push(
      ...(await page.locator(".rss-article-title").allTextContents()),
    );
    if (i < 2)
      await page.getByRole("button", { name: "次の50件", exact: true }).click();
  }
  expect(titles.length).toBe(125);
  expect(new Set(titles).size).toBe(125);
  await expect(
    page.getByRole("button", { name: "次の50件", exact: true }),
  ).toBeDisabled();
  await page.getByLabel("保存領域の記事を検索").fill("特別");
  await expect(page.locator("#rss-search-status")).toContainText("1件 · 1–1件");
  await page.screenshot({
    path: info.outputPath("search.png"),
    fullPage: true,
  });
});
test("IME composition does not replace the input before conversion completes", async ({
  page,
}) => {
  await seed(page);
  const input = page.getByLabel("保存領域の記事を検索");
  await input.dispatchEvent("compositionstart");
  await input.fill("特別");
  await expect(page.locator(".rss-article-list li")).toHaveCount(50);
  await expect(input).toHaveValue("特別");
  await input.dispatchEvent("compositionend");
  await expect(page.locator(".rss-article-list li")).toHaveCount(1);
});
