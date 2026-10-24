import { expect, test } from "vitest";
import { ArticleSearch } from "../src/article-search";
import type { FeedArticle } from "../src/feed-parser";
const article = (id: string, body: string): FeedArticle => ({
  id,
  body,
  title: "題名",
  feedUrl: "https://example.org/rss",
  url: "https://example.org/a",
  published: null,
  fetchedAt: "2026-10-24T00:00:00Z",
  read: false,
  saved: false,
});
test("search normalizes width and case, uses AND terms and only current translations", async () => {
  const index = new ArticleSearch();
  const a = article("one", "SQLite 分散データベース");
  await index.prepare([
    a,
    {
      ...article("two", "other"),
      translation: {
        text: "日本語の訳",
        sourceText: "other",
        sourceLanguage: "en",
        targetLanguage: "ja",
      },
    },
    {
      ...article("three", "changed"),
      translation: {
        text: "古い翻訳",
        sourceText: "old",
        sourceLanguage: "en",
        targetLanguage: "ja",
      },
    },
  ]);
  expect([...index.search("ＳＱＬｉｔｅ　データ")]).toEqual(["one"]);
  expect([...index.search("日本語")]).toEqual(["two"]);
  expect([...index.search("古い翻訳")]).toEqual([]);
  expect([...index.search("sqlite 不存在")]).toEqual([]);
});
test("a superseded preparation cannot publish stale documents", async () => {
  const index = new ArticleSearch();
  let release!: () => void;
  const pending = index.prepare(
    [article("old", "old")],
    () =>
      new Promise<void>((r) => {
        release = r;
      }),
  );
  expect(() => index.search("old")).toThrow();
  await index.prepare([article("new", "new")]);
  release();
  expect(await pending).toBe(false);
  expect([...index.search("old")]).toEqual([]);
  expect([...index.search("new")]).toEqual(["new"]);
});
test("reindex reflects edited originals and removals", async () => {
  const index = new ArticleSearch();
  await index.prepare([article("one", "old"), article("removed", "old")]);
  await index.prepare([article("one", "new")]);
  expect([...index.search("old")]).toEqual([]);
  expect([...index.search("new")]).toEqual(["one"]);
});

test("incremental updates replace original and translated search terms", async () => {
  const index = new ArticleSearch();
  const a = article("one", "before");
  await index.prepare([a, article("two", "unchanged")]);
  index.update({
    ...a,
    body: "after",
    translation: {
      text: "更新された訳",
      sourceText: "after",
      sourceLanguage: "en",
      targetLanguage: "ja",
    },
  });
  expect([...index.search("before")]).toEqual([]);
  expect([...index.search("after")]).toEqual(["one"]);
  expect([...index.search("更新された訳")]).toEqual(["one"]);
  expect([...index.search("unchanged")]).toEqual(["two"]);
  index.invalidate();
  expect(() => index.search("after")).toThrow();
});
