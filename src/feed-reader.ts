import { button, el } from "./ui";
import { parseFeed, type Feed, type FeedArticle } from "./feed-parser";
import {
  openFeedLibrary,
  readFeedLibrary,
  mergeFeed,
  flagArticle,
} from "./feed-store";

export async function feedReader(root: HTMLElement) {
  document.title = "情報収集 | Quilna";
  let db: IDBDatabase | null = null;
  let feeds: Feed[] = [],
    articles: FeedArticle[] = [];
  let selected: string | null = null,
    filter = "all",
    source = "",
    input = "";
  let problem = "",
    retry: (() => void) | null = null,
    connecting = true;
  let epoch = 0;
  const updating = new Set<string>(),
    changing = new Set<string>();
  const feedProblems = new Map<string, string>();
  const channel =
    typeof BroadcastChannel === "undefined"
      ? null
      : new BroadcastChannel("tsumiki.rss.v1");
  const rootHeader = el("header", undefined, "rss-header");
  const brand = el("a", "Quilna", "brand");
  brand.href = "/?view=feeds";
  const actions = el("div", undefined, "rss-header-actions");
  const lesson = el("a", "サンプル教材", "rss-text-link");
  lesson.href = "/?view=lesson#read";
  const settings = el("dialog", undefined, "rss-settings");
  settings.setAttribute("aria-labelledby", "rss-settings-title");
  const settingsTitle = el("h2", "設定・保存先");
  settingsTitle.id = "rss-settings-title";
  const settingsOpen = button("設定", () => settings.showModal());
  settings.append(
    settingsTitle,
    el(
      "p",
      "記事・購読・保存済みの印は、このブラウザ内に保存します。別の端末やブラウザとは同期しません。ブラウザのデータを消去すると失われます。",
    ),
    el(
      "p",
      "RSSの更新には、この端末で動く取得サーバーとインターネット接続を使います。取得済みの記事は、配信元が応答しなくても読めます。",
    ),
    el(
      "p",
      "記事の保存は、配信された本文・概要のローカルコピーです。元サイトの全文取得、翻訳、教材生成はまだ接続していません。",
    ),
    button("閉じる", () => settings.close()),
  );
  settings.addEventListener("close", () => settingsOpen.focus());
  actions.append(lesson, settingsOpen);
  rootHeader.append(brand, actions);
  const layout = el("div", undefined, "rss-shell");
  const navigation = el("section", undefined, "rss-navigation");
  navigation.setAttribute("aria-label", "収集メニュー");
  const main = el("main", undefined, "rss-main");
  const errors = el("div", undefined, "rss-error");
  errors.setAttribute("role", "alert");
  errors.hidden = true;
  layout.append(navigation, main);
  root.append(rootHeader, layout, errors, settings);

  function showError(message: string, action: () => void) {
    problem = message;
    retry = action;
    renderError();
  }
  function renderError() {
    errors.replaceChildren();
    errors.hidden = !problem;
    if (problem)
      errors.append(
        el("strong", problem),
        button("再試行", () => {
          problem = "";
          renderError();
          retry?.();
        }),
      );
  }
  async function load() {
    if (!db) return;
    const ticket = ++epoch;
    const loaded = await readFeedLibrary(db);
    if (ticket !== epoch) return;
    feeds = loaded.feeds;
    articles = loaded.articles;
  }
  function announceChange() {
    channel?.postMessage("changed");
  }
  async function connect() {
    connecting = true;
    render();
    try {
      db?.close();
      db = await openFeedLibrary();
      await load();
      problem = "";
    } catch (error) {
      showError((error as Error).message, () => void connect());
    } finally {
      connecting = false;
      render();
    }
  }
  async function refresh(value: string, registering = false) {
    let url: URL;
    try {
      url = new URL(value.trim());
      if (url.protocol !== "https:" || url.username || url.password || url.port)
        throw Error();
      url.hash = "";
    } catch {
      showError(
        "HTTPSのRSS / Atom URLを入力してください。",
        () => void refresh(input, registering),
      );
      return;
    }
    const address = url.href;
    if (!db || updating.has(address)) return;
    if (
      registering &&
      feeds.length >= 50 &&
      !feeds.some((f) => f.url === address)
    ) {
      showError(
        "この試作では50件まで登録できます。",
        () => void refresh(address, true),
      );
      return;
    }
    updating.add(address);
    feedProblems.delete(address);
    render();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 16000);
    try {
      const response = await fetch("/api/feeds/fetch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: address }),
        signal: controller.signal,
      });
      if (!response.ok)
        throw Error(
          response.status === 404
            ? "この環境にはRSS取得サーバーがありません。ローカル起動を確認してください。"
            : "RSSを取得できませんでした。URLや通信状態を確認してください。",
        );
      const result = await response.json();
      if (typeof result.xml !== "string" || typeof result.url !== "string")
        throw Error("RSS取得サーバーの応答を確認してください。");
      const parsed = parseFeed(result.xml, address, result.url);
      await mergeFeed(db, parsed.feed, parsed.articles);
      await load();
      announceChange();
      problem = "";
      if (registering) {
        input = "";
        source = address;
        filter = "all";
        selected = null;
      }
    } catch (error) {
      const message = controller.signal.aborted
        ? "更新が時間内に終わりませんでした。保存した記事は引き続き読めます。"
        : (error as Error).message;
      feedProblems.set(address, message);
      if (registering) showError(message, () => void refresh(address, true));
    } finally {
      clearTimeout(timeout);
      updating.delete(address);
      render();
    }
  }
  async function refreshAll() {
    const queue = feeds.map((f) => f.url).filter((url) => !updating.has(url));
    await Promise.all(
      [0, 1].map(async () => {
        while (queue.length) await refresh(queue.shift()!);
      }),
    );
  }
  async function change(
    article: FeedArticle,
    field: "saved" | "read",
    value: boolean,
  ) {
    if (!db || changing.has(article.id)) return;
    changing.add(article.id);
    render();
    try {
      await flagArticle(db, article.id, field, value);
      await load();
      announceChange();
      problem = "";
    } catch (error) {
      showError(
        (error as Error).message,
        () => void change(article, field, value),
      );
    } finally {
      changing.delete(article.id);
      render();
    }
  }
  function openArticle(article: FeedArticle) {
    selected = article.id;
    render();
    if (!article.read) void change(article, "read", true);
    main.querySelector<HTMLElement>("h1")?.focus();
    main.scrollIntoView({ block: "start" });
  }
  const date = (value: string | null) =>
    value
      ? new Date(value).toLocaleString("ja-JP", {
          dateStyle: "medium",
          timeStyle: "short",
        })
      : "公開日時なし";
  function render() {
    const activeId = document.activeElement?.id;
    renderError();
    navigation.replaceChildren();
    main.replaceChildren();
    navigation.append(
      el("p", "COLLECT → READ → LEARN", "eyebrow"),
      el("h2", "情報収集"),
    );
    const menus = el("nav", undefined, "rss-filters");
    menus.setAttribute("aria-label", "記事の絞り込み");
    for (const [value, label] of [
      ["all", "すべての記事"],
      ["unread", "未読"],
      ["saved", "保存した記事"],
    ]) {
      const count = articles
        .filter((a) => !source || a.feedUrl === source)
        .filter(
          (a) => value === "all" || (value === "unread" ? !a.read : a.saved),
        ).length;
      const menu = button(`${label} · ${count}`, () => {
        filter = value;
        selected = null;
        render();
      });
      if (filter === value) menu.setAttribute("aria-current", "page");
      menus.append(menu);
    }
    navigation.append(menus);
    const form = el("form", undefined, "rss-add");
    const label = el("label", "RSS / Atom URL");
    label.htmlFor = "feed-url";
    const field = el("input");
    field.id = "feed-url";
    field.type = "url";
    field.required = true;
    field.placeholder = "https://example.com/feed.xml";
    field.value = input;
    field.addEventListener("input", () => {
      input = field.value;
    });
    const submit = el("button", "登録して取得");
    submit.type = "submit";
    submit.disabled = !db || connecting;
    form.append(label, field, submit);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      void refresh(field.value, true);
    });
    navigation.append(form);
    if (!feeds.length) {
      const presets = el("div", undefined, "rss-presets");
      presets.append(el("p", "公開フィードから試す", "muted"));
      for (const [name, url] of [
        ["Zenn", "https://zenn.dev/feed"],
        ["Cloudflare Blog", "https://blog.cloudflare.com/rss/"],
      ]) {
        const add = button(`${name}を追加`, () => void refresh(url, true));
        add.disabled = !db || updating.has(url);
        presets.append(add);
      }
      navigation.append(presets);
    }
    const sourceLabel = el("label", "配信元");
    sourceLabel.htmlFor = "feed-source";
    const select = el("select");
    select.id = "feed-source";
    const all = el("option", "すべての配信元");
    all.value = "";
    select.append(all);
    for (const feed of feeds) {
      const option = el("option", feed.title);
      option.value = feed.url;
      select.append(option);
    }
    select.value = source;
    select.addEventListener("change", () => {
      source = select.value;
      selected = null;
      render();
    });
    navigation.append(sourceLabel, select);
    const refreshButton = button("すべて更新", () => void refreshAll());
    refreshButton.disabled = !feeds.length || !!updating.size;
    navigation.append(refreshButton);
    const progress = el(
      "p",
      updating.size
        ? `更新中：${updating.size}件。取得済みの記事は読めます。`
        : "",
      "rss-progress",
    );
    progress.setAttribute("role", "status");
    navigation.append(progress);
    for (const feed of feeds) {
      const line = el("div", undefined, "rss-feed-state");
      line.append(
        el("strong", feed.title),
        el("span", `最終取得 ${date(feed.fetchedAt)}`, "muted"),
      );
      if (feedProblems.has(feed.url)) {
        const error = el("p", feedProblems.get(feed.url), "rss-feed-error");
        error.setAttribute("role", "alert");
        line.append(error);
      }
      const update = button(
        feedProblems.has(feed.url)
          ? `${feed.title}を再試行`
          : `${feed.title}を更新`,
        () => void refresh(feed.url),
      );
      update.disabled = updating.has(feed.url);
      line.append(update);
      navigation.append(line);
    }
    const article = articles.find((a) => a.id === selected);
    if (article) {
      main.classList.add("rss-reading");
      main.append(
        button("← 記事一覧へ", () => {
          selected = null;
          render();
          main.querySelector<HTMLElement>("h1")?.focus();
        }),
      );
      const articleNode = el("article", undefined, "rss-article");
      const title = el("h1", article.title);
      title.id = "rss-current-title";
      title.tabIndex = -1;
      articleNode.append(
        el(
          "p",
          feeds.find((f) => f.url === article.feedUrl)?.title ?? "配信元",
          "eyebrow",
        ),
        title,
        el("p", date(article.published), "muted"),
      );
      const save = button(
        article.saved ? "保存済み · 保存を解除" : "この記事を保存",
        () => void change(article, "saved", !article.saved),
      );
      save.id = "rss-save-article";
      save.setAttribute("aria-pressed", String(article.saved));
      save.disabled = changing.has(article.id);
      articleNode.append(save);
      if (article.url) {
        const original = el("a", "元の記事を開く", "rss-text-link");
        original.href = article.url;
        original.target = "_blank";
        original.rel = "noopener noreferrer";
        articleNode.append(original);
      }
      articleNode.append(
        el(
          "p",
          "配信された本文・概要を表示しています。全文が含まれない記事は、元の記事で続きを読めます。",
          "rss-content-note",
        ),
      );
      const body = el("div", undefined, "rss-article-body");
      if (article.body)
        for (const paragraph of article.body.split(/\n\s*\n/))
          body.append(el("p", paragraph));
      else
        body.append(
          el(
            "p",
            "このフィードには本文・概要がありません。元の記事を開いてください。",
          ),
        );
      articleNode.append(body);
      main.append(articleNode);
    } else {
      main.classList.remove("rss-reading");
      const heading = el(
        "h1",
        filter === "saved"
          ? "保存した記事"
          : filter === "unread"
            ? "未読の記事"
            : "すべての記事",
      );
      heading.tabIndex = -1;
      main.append(
        heading,
        el(
          "p",
          "気になる情報を集めて、読む。学びたい記事を保存しておきましょう。",
          "rss-lede",
        ),
      );
      const visible = articles
        .filter(
          (a) =>
            (!source || a.feedUrl === source) &&
            (filter === "all" || (filter === "saved" ? a.saved : !a.read)),
        )
        .sort((a, b) =>
          (b.published ?? b.fetchedAt).localeCompare(
            a.published ?? a.fetchedAt,
          ),
        );
      const list = el("ul", undefined, "rss-article-list");
      list.setAttribute("aria-label", "記事一覧");
      for (const item of visible) {
        const row = el("li");
        row.append(
          el(
            "p",
            `${feeds.find((f) => f.url === item.feedUrl)?.title ?? "配信元"} · ${date(item.published)}${item.saved ? " · 保存済み" : ""}${item.read ? " · 既読" : " · 未読"}`,
            "rss-article-meta",
          ),
        );
        const open = button(
          item.title,
          () => openArticle(item),
          "rss-article-title",
        );
        row.append(open, el("p", item.body.slice(0, 160), "rss-excerpt"));
        list.append(row);
      }
      main.append(list);
      if (!visible.length)
        main.append(
          el(
            "div",
            connecting
              ? "保存した記事を読み込んでいます…"
              : !feeds.length
                ? "RSSを登録すると、ここに記事が届きます。URL欄から登録するか、公開フィードから試してください。"
                : filter === "saved"
                  ? "まだ保存した記事はありません。記事を開いて「この記事を保存」を押してください。"
                  : filter === "unread"
                    ? "未読の記事はありません。"
                    : "まだ記事がありません。配信元を更新してください。",
            "rss-empty",
          ),
        );
    }
    if (activeId)
      document.getElementById(activeId)?.focus({ preventScroll: true });
  }
  channel?.addEventListener("message", () => {
    void load()
      .then(render)
      .catch(() =>
        showError(
          "保存領域を再読み込みできませんでした。",
          () => void connect(),
        ),
      );
  });
  await connect();
}
