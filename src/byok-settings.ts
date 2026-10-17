import {
  MockByok,
  models,
  providers,
  type MockUser,
  type Operation,
  type Provider,
} from "./byok";
import { button, el } from "./ui";

export function byokSettings() {
  let owner: MockUser = "demo-a";
  let mode: "ok" | "fail" | "wait" = "ok";
  const dialog = el("dialog", undefined, "byok-settings");
  dialog.setAttribute("aria-labelledby", "byok-title");
  const heading = el("h2", "自分のAPIキー設定（模擬）");
  heading.id = "byok-title";
  const notice = el(
    "p",
    "OpenAI / Anthropicは利用者自身のキーを使う設計です。現在は実環境の認証・暗号化保存が未設定のため実キー入力と実接続は無効です。模擬設定はこのタブのメモリのみで、再読み込みで消えます。",
  );
  const label = el("label", "模擬利用者（認証ではありません）");
  const user = el("select");
  for (const [value, text] of [
    ["demo-a", "模擬利用者A"],
    ["demo-b", "模擬利用者B"],
  ]) {
    const option = el("option", text);
    option.value = value;
    user.append(option);
  }
  label.append(user);
  const modeLabel = el("label", "模擬応答");
  const modeSelect = el("select");
  for (const [value, text] of [
    ["ok", "正常"],
    ["fail", "失敗"],
    ["wait", "待機（中断を試す）"],
  ]) {
    const option = el("option", text);
    option.value = value;
    modeSelect.append(option);
  }
  modeLabel.append(modeSelect);
  const cards = el("div", undefined, "byok-cards");
  const store = new MockByok(renderCards);
  function close() {
    store.cancelOwner(owner);
    dialog.close();
  }
  const closeButton = button("教材へ戻る", close);
  dialog.append(
    heading,
    notice,
    label,
    modeLabel,
    el(
      "p",
      "BYOKでも本人のAI料金は月500円の運用予算に含めます。模擬操作では送信・課金しません。",
    ),
    cards,
    closeButton,
  );
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    close();
  });
  window.addEventListener("popstate", () => {
    if (dialog.open) close();
  });
  user.addEventListener("change", () => {
    store.cancelOwner(owner);
    owner = user.value as MockUser;
    renderCards();
  });
  modeSelect.addEventListener("change", () => {
    mode = modeSelect.value as typeof mode;
  });
  function run(provider: Provider, operation: Operation) {
    const response = mode;
    void store.run(
      owner,
      provider,
      operation,
      (signal) =>
        new Promise((resolve, reject) => {
          // Fixed dummy simulation, never a provider request or a supplied key.
          const timer =
            response === "wait"
              ? undefined
              : setTimeout(() => resolve(response), 100);
          signal.addEventListener(
            "abort",
            () => {
              clearTimeout(timer);
              reject(Error("mock-cancelled"));
            },
            { once: true },
          );
        }),
    );
  }
  function renderCards() {
    const active = document.activeElement;
    const focusedCard =
      active instanceof Element
        ? active.closest<HTMLElement>(".byok-card")?.dataset.provider
        : undefined;
    cards.replaceChildren();
    for (const provider of providers) {
      const state = store.view(owner, provider);
      const card = el("section", undefined, "byok-card");
      card.dataset.provider = provider;
      card.setAttribute(
        "aria-label",
        provider === "openai" ? "OpenAI設定" : "Anthropic設定",
      );
      card.append(el("h3", provider === "openai" ? "OpenAI" : "Anthropic"));
      const keyLabel = el("label", "APIキー（実キー入力は準備中）");
      const input = el("input");
      input.type = "password";
      input.disabled = true;
      input.autocomplete = "off";
      input.placeholder = "実キーを入力しないでください";
      keyLabel.append(input);
      card.append(keyLabel);
      const status = el("p", state.message);
      status.setAttribute("role", "status");
      status.tabIndex = -1;
      card.append(status);
      if (state.setting)
        card.append(
          el(
            "p",
            `模擬登録 #${state.setting.revision} · キー値は保持・表示しません`,
          ),
        );
      const modelLabel = el("label", "モデル候補（実利用可否未確認）");
      const model = el("select");
      for (const id of models[provider]) {
        const option = el("option", id);
        option.value = id;
        model.append(option);
      }
      model.disabled = !state.setting || !!state.pending;
      if (state.setting) model.value = state.setting.model;
      model.addEventListener("change", () => {
        store.selectModel(owner, provider, model.value);
      });
      modelLabel.append(model);
      card.append(modelLabel);
      const actions = el("div", undefined, "byok-actions");
      const register = button("ダミーで模擬登録", () =>
        run(provider, "register"),
      );
      register.disabled = !!state.setting || !!state.pending;
      const check = button("模擬接続確認", () => run(provider, "verify"));
      check.disabled = !state.setting || !!state.pending;
      const replace = button("ダミーで模擬差し替え", () =>
        run(provider, "replace"),
      );
      replace.disabled = !state.setting || !!state.pending;
      const remove = button("模擬設定を削除", () =>
        store.remove(owner, provider),
      );
      remove.disabled = !state.setting && !state.pending;
      actions.append(register, check, replace, remove);
      if (state.pending)
        actions.append(
          button("模擬処理を中断", () => store.cancel(owner, provider)),
        );
      card.append(actions);
      cards.append(card);
      if (focusedCard === provider) status.focus({ preventScroll: true });
    }
  }
  renderCards();
  return {
    dialog,
    open: () => {
      if (!dialog.open) dialog.showModal();
    },
  };
}
