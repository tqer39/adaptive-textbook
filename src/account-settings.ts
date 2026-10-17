import { AuthClient } from "./auth-client";
import { CredentialClient } from "./credential-client";
import { providers } from "./byok";
import { el, button } from "./ui";
/** Real session/API panel, separate from mock users. Current server never grants key input. */
export function accountSettings() {
  const privateDev =
    document.querySelector<HTMLMetaElement>('meta[name="private-dev"]')
      ?.content === "true";
  const auth = new AuthClient(),
    credentials = new CredentialClient();
  const panel = el("details", undefined, "account-settings");
  panel.append(el("summary", "Googleログイン・保存設定"));
  const body = el("div");
  panel.append(body);
  let epoch = 0,
    busy = false;
  let outcome = "";
  const status = el("p", "実環境の認証設定は未接続です。");
  status.setAttribute("role", "status");
  const controls = el("div");
  const cards = el("div");
  const login = button("Googleでログイン", () => {
    void begin();
  });
  const cancel = button("ログインを中断", () => {
    void stop(false);
  });
  const logout = button("ログアウト", () => {
    void stop(true);
  });
  controls.append(login, cancel, logout);
  body.append(
    status,
    el(
      "p",
      "ログインしても読書履歴はこのブラウザ内のみで、Googleアカウントへ同期しません。",
    ),
    controls,
    cards,
  );
  login.disabled = cancel.disabled = logout.disabled = true;
  function lock() {
    credentials.lock();
    cards.replaceChildren();
  }
  async function refresh() {
    const current = ++epoch;
    lock();
    login.disabled = cancel.disabled = logout.disabled = true;
    const s = await auth.status();
    if (current !== epoch) return;
    if (privateDev && !s.authenticated) {
      window.location.replace("/");
      return;
    }
    login.disabled = !s.available || s.authenticated;
    cancel.disabled = !s.available;
    logout.disabled = !s.authenticated;
    status.textContent =
      outcome +
      (s.authenticated
        ? "Google認証済み。実キー入力・実API送信は準備中です。"
        : s.available
          ? "未ログインです。"
          : "実環境の認証設定は未接続です。");
    if (!s.authenticated) return;
    await credentials.session();
    if (current !== epoch) return;
    for (const provider of providers) {
      const value = await credentials.status(provider);
      if (current !== epoch) return;
      const card = el("section");
      card.setAttribute(
        "aria-label",
        provider === "openai" ? "保存済みOpenAI設定" : "保存済みAnthropic設定",
      );
      card.append(el("h3", provider === "openai" ? "OpenAI" : "Anthropic"));
      const label = el("label", "APIキー（実環境の安全確認待ち）"),
        input = el("input");
      input.type = "password";
      input.disabled = true;
      input.autocomplete = "off";
      label.append(input);
      card.append(label);
      card.append(
        el(
          "p",
          value.status === "metadata"
            ? `保存版 #${value.setting.revision} · ${value.setting.state === "registered" ? "登録済み" : "未登録"} · 実API未接続`
            : "保存状態を確認できません。",
        ),
      );
      cards.append(card);
    }
  }
  async function begin() {
    if (busy) return;
    outcome = "";
    busy = true;
    login.disabled = true;
    const current = epoch;
    status.textContent = "ログイン開始を確認しています。";
    const url = await auth.start();
    busy = false;
    if (current !== epoch) return;
    if (url) window.location.assign(url);
    else {
      status.textContent =
        "ログインを開始できません。設定と接続状態を確認してください。";
      login.disabled = false;
    }
  }
  async function stop(signOut: boolean) {
    outcome = "";
    ++epoch;
    lock();
    login.disabled = cancel.disabled = logout.disabled = true;
    const ok = signOut ? await auth.logout() : await auth.cancel();
    status.textContent = ok
      ? signOut
        ? "ログアウトしました。"
        : "ログインを中断しました。"
      : "操作を確認できません。再読み込みで状態を確認してください。";
    if (privateDev) {
      window.location.replace("/");
      return;
    }
    if (ok) await refresh();
  }
  panel.addEventListener("toggle", () => {
    if (panel.open && !busy) void refresh();
  });
  window.addEventListener("pageshow", () => {
    if (privateDev || panel.open) void refresh();
  });
  window.addEventListener("popstate", () => {
    if (privateDev || panel.open) void refresh();
  });
  // Callback carries no codes into the app; erase its fixed status query after announcing it.
  const url = new URL(window.location.href),
    result = url.searchParams.get("auth");
  if (["success", "failed", "cancelled"].includes(result ?? "")) {
    outcome =
      result === "failed"
        ? "ログインを完了できませんでした。 "
        : result === "cancelled"
          ? "ログインが中断されました。 "
          : "";
    url.searchParams.delete("auth");
    history.replaceState(history.state, "", url);
    panel.open = true;
    void refresh();
  }
  if (privateDev) {
    setInterval(() => {
      void refresh();
    }, 60000);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") void refresh();
    });
  }
  return panel;
}
