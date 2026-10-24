import type { Feed, FeedArticle } from "./feed-parser";
import { articleURL } from "./feed-parser";
export const feedDatabase = "tsumiki.rss.v1";
export function openFeedLibrary(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(feedDatabase, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("feeds", { keyPath: "url" });
      request.result.createObjectStore("articles", { keyPath: "id" });
    };
    request.onerror = () =>
      reject(
        Error(
          "記事の保存領域を開けませんでした。既存データは削除していません。",
        ),
      );
    request.onblocked = () =>
      reject(Error("別タブを閉じて保存領域の再接続を試してください。"));
    request.onsuccess = () => {
      request.result.onversionchange = () => request.result.close();
      resolve(request.result);
    };
  });
}
export function readFeedLibrary(
  db: IDBDatabase,
): Promise<{ feeds: Feed[]; articles: FeedArticle[] }> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["feeds", "articles"], "readonly");
    const feeds = tx.objectStore("feeds").getAll();
    const articles = tx.objectStore("articles").getAll();
    tx.oncomplete = () => {
      const text = (value: unknown) =>
        typeof value === "string" && value.length <= 40000;
      const timestamp = (value: unknown) =>
        text(value) && Number.isFinite(Date.parse(value as string));
      const validFeeds = feeds.result.every(
        (f) => f && text(f.url) && text(f.title) && timestamp(f.fetchedAt),
      );
      const validArticles = articles.result.every(
        (a) =>
          a &&
          [a.id, a.feedUrl, a.title, a.url, a.body, a.fetchedAt].every(text) &&
          timestamp(a.fetchedAt) &&
          (a.published === null || timestamp(a.published)) &&
          typeof a.read === "boolean" &&
          typeof a.saved === "boolean" &&
          (!a.url || articleURL(a.url, a.feedUrl) === a.url),
      );
      if (!validFeeds || !validArticles) {
        reject(
          Error(
            "保存データの形式を確認できませんでした。データは削除していません。",
          ),
        );
        return;
      }
      resolve({ feeds: feeds.result, articles: articles.result });
    };
    tx.onabort = tx.onerror = () =>
      reject(Error("保存した記事を読み込めませんでした。"));
  });
}
export function mergeFeed(
  db: IDBDatabase,
  feed: Feed,
  articles: FeedArticle[],
): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["feeds", "articles"], "readwrite");
    const feedStore = tx.objectStore("feeds");
    const existing = feedStore.get(feed.url);
    existing.onsuccess = () => {
      const count = feedStore.count();
      count.onsuccess = () => {
        if (!existing.result && count.result >= 50) {
          reject(Error("この試作では購読50件まで登録できます。"));
          tx.abort();
          return;
        }
        feedStore.put(feed);
      };
    };
    const store = tx.objectStore("articles");
    for (const article of articles) {
      const request = store.get(article.id);
      request.onsuccess = () => {
        const old = request.result as FeedArticle | undefined;
        // A saved article is a stable local copy, even when its feed changes.
        store.put(old?.saved ? old : { ...article, read: old?.read ?? false });
      };
    }
    tx.oncomplete = () => resolve();
    tx.onabort = tx.onerror = () =>
      reject(
        Error("記事を保存できませんでした。以前の保存内容は保持しています。"),
      );
  });
}
export function flagArticle(
  db: IDBDatabase,
  id: string,
  field: "saved" | "read",
  value: boolean,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction("articles", "readwrite");
    const store = tx.objectStore("articles");
    const request = store.get(id);
    request.onsuccess = () => {
      if (request.result) store.put({ ...request.result, [field]: value });
      else tx.abort();
    };
    tx.oncomplete = () => resolve();
    tx.onabort = tx.onerror = () =>
      reject(Error("変更を保存できませんでした。再試行してください。"));
  });
}
