import { test, expect, type Page } from "@playwright/test";
const address = "https://zenn.dev/feed";
const account = "cloud-account-fixture-000000000000";
const csrf = "cloud-csrf-fixture-000000000000";
const time = Date.parse("2026-10-24T00:00:00Z");
const snapshotId = "f85a0f14-caff-4cc6-81f8-d4d00ca919ee";
const xml =
  "<rss><channel><title>Cloud source</title><item><guid>one</guid><title>Older remote copy</title><description>Older body</description></item><item><guid>two</guid><title>While PC was off</title><description>New body</description></item></channel></rss>";
const initial = () => ({
  available: true,
  account,
  revision: 0,
  interval: 0,
  hosts: ["zenn.dev"],
  feeds: [] as {
    url: string;
    nextAt: number;
    lastSuccess: number | null;
    failures: number;
    error: string;
  }[],
  pending: [] as {
    id: string;
    feedUrl: string;
    url: string;
    fetchedAt: number;
    parts: number;
    size: number;
  }[],
  bytes: 0,
  blocked: false,
});
async function seed(page: Page) {
  await page.goto("/?view=feeds");
  await page.evaluate(
    async ({ address, time }) => {
      const path = "/src/feed-store.ts";
      const { openFeedLibrary } = await import(path);
      const db = await openFeedLibrary();
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction(["feeds", "articles"], "readwrite");
        const fetchedAt = new Date(time + 60_000).toISOString();
        tx.objectStore("feeds").put({
          url: address,
          title: "Current source",
          fetchedAt,
        });
        tx.objectStore("articles").put({
          id: JSON.stringify([address, "one"]),
          feedUrl: address,
          title: "Newer local article",
          url: "",
          body: "Keep newer local body",
          published: null,
          fetchedAt,
          saved: false,
          read: true,
        });
        tx.oncomplete = () => resolve();
        tx.onabort = () => reject(tx.error);
      });
      db.close();
    },
    { address, time },
  );
}
test("cloud results import after reopening, preserve newer local content and tolerate a lost acknowledgement", async ({
  page,
}) => {
  const state = initial();
  let loseAck = true,
    acknowledgements = 0;
  let foregroundRequests = 0;
  await page.route("**/api/feeds/fetch", (route) => {
    foregroundRequests++;
    return route.fulfill({
      status: 502,
      json: { error: "unexpected-foreground-request" },
    });
  });
  await page.route("**/api/session", (route) =>
    route.fulfill({ json: { csrfToken: csrf } }),
  );
  await page.route("**/api/collection**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/ack")) {
      acknowledgements++;
      expect(route.request().headers()["x-collection-account"]).toBe(account);
      expect(route.request().headers()["x-csrf-token"]).toBe(csrf);
      if (loseAck)
        return route.fulfill({
          status: 503,
          json: { status: "lost-response" },
        });
      state.pending = [];
    }
    if (path.includes("/snapshots/"))
      return route.fulfill({ json: { ...state.pending[0], account, xml } });
    return route.fulfill({ json: state });
  });
  await seed(page);
  state.interval = 15;
  state.pending = [
    {
      id: snapshotId,
      feedUrl: address,
      url: address,
      fetchedAt: time,
      parts: 1,
      size: xml.length,
    },
  ];
  await page.reload();
  await expect(
    page.getByRole("button", { name: "While PC was off", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Newer local article", exact: true }),
  ).toBeVisible();
  expect(acknowledgements).toBe(1);
  await page.getByRole("button", { name: "設定", exact: true }).click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "接続できません",
  );
  loseAck = false;
  await page
    .getByRole("button", {
      name: "クラウドの状態確認・記事を取り込む",
      exact: true,
    })
    .click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "未取り込みの取得結果：0件",
  );
  await page.getByRole("button", { name: "閉じる", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "すべての記事 · 2", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "未読 · 1", exact: true }),
  ).toBeVisible();
  expect(acknowledgements).toBe(2);
  expect(foregroundRequests).toBe(0);
});

test("cloud settings start and stop explicitly; stale revisions show a recoverable conflict", async ({
  page,
}) => {
  const state = initial();
  let conflict = false;
  await page.route("**/api/session", (route) =>
    route.fulfill({ json: { csrfToken: csrf } }),
  );
  await page.route("**/api/collection", (route) => {
    if (route.request().method() === "PUT") {
      if (conflict)
        return route.fulfill({
          status: 409,
          json: { status: "collection-conflict" },
        });
      const body = route.request().postDataJSON();
      expect(body.expectedRevision).toBe(state.revision);
      expect(body.urls).toEqual([address]);
      state.revision++;
      state.interval = body.interval;
      state.feeds = [
        {
          url: address,
          nextAt: time,
          lastSuccess: null,
          failures: 0,
          error: "",
        },
      ];
    }
    return route.fulfill({ json: state });
  });
  await seed(page);
  await page.reload();
  await page.getByRole("button", { name: "設定", exact: true }).click();
  await page
    .getByLabel("クラウドの収集間隔", { exact: true })
    .selectOption("30");
  await page
    .getByRole("button", {
      name: "クラウド収集を開始・設定を更新",
      exact: true,
    })
    .click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "クラウドで30分ごと",
  );
  conflict = true;
  await page
    .getByRole("button", { name: "クラウド収集を停止", exact: true })
    .click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "別の画面で設定が変わりました",
  );
  expect(state.interval).toBe(30);
  conflict = false;
  await page
    .getByRole("button", { name: "クラウド収集を停止", exact: true })
    .click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "クラウド収集は停止中",
  );
});

test("a local-only environment clearly reports unavailable cloud collection", async ({
  page,
}) => {
  await page.route("**/api/collection", (route) =>
    route.fulfill({ status: 404, json: { status: "auth-unconfigured" } }),
  );
  await page.goto("/?view=feeds");
  await page.getByRole("button", { name: "設定", exact: true }).click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "画面表示中の更新のみ",
  );
  await expect(
    page.getByRole("button", {
      name: "クラウド収集を開始・設定を更新",
      exact: true,
    }),
  ).toBeDisabled();
});

test("a failed browser save never acknowledges the cloud result", async ({
  page,
}) => {
  const state = initial();
  let acknowledgements = 0;
  await page.route("**/api/session", (route) =>
    route.fulfill({ json: { csrfToken: csrf } }),
  );
  await page.route("**/api/collection**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/ack")) acknowledgements++;
    return route.fulfill({
      json: path.includes("/snapshots/")
        ? { ...state.pending[0], account, xml }
        : state,
    });
  });
  await seed(page);
  await page.addInitScript(() => {
    const original = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (
      ...args: Parameters<typeof original>
    ) {
      if (this.name === "articles")
        throw new DOMException("Fixture quota", "QuotaExceededError");
      return original.apply(this, args);
    };
  });
  state.pending = [
    {
      id: snapshotId,
      feedUrl: address,
      url: address,
      fetchedAt: time,
      parts: 1,
      size: xml.length,
    },
  ];
  await page.reload();
  await page.getByRole("button", { name: "設定", exact: true }).click();
  await expect(page.locator("#rss-cloud-status")).toContainText(
    "記事を保存できませんでした",
  );
  expect(acknowledgements).toBe(0);
  expect(state.pending).toHaveLength(1);
});
