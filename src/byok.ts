/** Mock metadata only. No credential input, persistence, network, or authenticated identity. */
export const providers = ["openai", "anthropic"] as const;
export type Provider = (typeof providers)[number];
export type MockUser = "demo-a" | "demo-b";
export const models: Record<Provider, readonly string[]> = {
  openai: ["gpt-6-luna"],
  anthropic: ["claude-haiku-5-5"],
};
export type Operation = "register" | "replace" | "verify";
export type MockResult = "ok" | "fail";
export type Setting = {
  revision: number;
  model: string;
  checked: boolean;
};
export type View = {
  setting: Setting | null;
  pending: Operation | null;
  message: string;
};
export type MockSender = (signal: AbortSignal) => Promise<MockResult>;
const valid = (owner: MockUser, provider: Provider) => {
  if (!["demo-a", "demo-b"].includes(owner) || !providers.includes(provider))
    throw Error("mock-identity-invalid");
};
export class MockByok {
  private states = new Map<string, View>();
  private operations = new Map<string, AbortController>();
  private serial = 0;
  constructor(private changed: () => void = () => {}) {}
  private key(owner: MockUser, provider: Provider) {
    valid(owner, provider);
    return `${owner}:${provider}`;
  }
  view(owner: MockUser, provider: Provider): View {
    const state = this.states.get(this.key(owner, provider));
    return state
      ? { ...state, setting: state.setting ? { ...state.setting } : null }
      : { setting: null, pending: null, message: "未登録 · 実API未接続" };
  }
  async run(
    owner: MockUser,
    provider: Provider,
    operation: Operation,
    send: MockSender,
  ) {
    const key = this.key(owner, provider);
    const previous = this.view(owner, provider);
    if (
      previous.pending ||
      !["register", "replace", "verify"].includes(operation)
    )
      return false;
    if (
      operation === "register"
        ? previous.setting !== null
        : previous.setting === null
    )
      return false;
    const controller = new AbortController();
    this.operations.set(key, controller);
    this.states.set(key, {
      ...previous,
      pending: operation,
      message: "模擬処理中 · 実API未接続",
    });
    this.changed();
    try {
      const result = await send(controller.signal);
      if (this.operations.get(key) !== controller || controller.signal.aborted)
        return false;
      if (result !== "ok") throw Error("mock-failure");
      const setting =
        operation === "verify"
          ? { ...previous.setting!, checked: true }
          : {
              revision: ++this.serial,
              model: previous.setting?.model ?? models[provider][0],
              checked: false,
            };
      this.states.set(key, {
        setting,
        pending: null,
        message:
          operation === "verify"
            ? "模擬確認済み · 実API未接続"
            : "模擬登録済み · 永続保存なし · 実API未接続",
      });
      return true;
    } catch {
      if (this.operations.get(key) !== controller || controller.signal.aborted)
        return false;
      this.states.set(key, {
        ...previous,
        pending: null,
        message: "模擬処理に失敗 · 元の設定を維持 · 実API未接続",
      });
      return false;
    } finally {
      if (this.operations.get(key) === controller) {
        this.operations.delete(key);
        this.changed();
      }
    }
  }
  cancel(owner: MockUser, provider: Provider) {
    const key = this.key(owner, provider);
    const controller = this.operations.get(key);
    if (!controller) return;
    controller.abort();
    this.operations.delete(key);
    this.states.set(key, {
      ...this.view(owner, provider),
      pending: null,
      message: "模擬処理を中断 · 元の設定を維持 · 実API未接続",
    });
    this.changed();
  }
  cancelOwner(owner: MockUser) {
    for (const provider of providers) this.cancel(owner, provider);
  }
  remove(owner: MockUser, provider: Provider) {
    this.cancel(owner, provider);
    this.states.delete(this.key(owner, provider));
    this.changed();
  }
  selectModel(owner: MockUser, provider: Provider, model: string) {
    const key = this.key(owner, provider);
    const previous = this.view(owner, provider);
    if (
      !models[provider].includes(model) ||
      !previous.setting ||
      previous.pending
    )
      return false;
    this.states.set(key, {
      ...previous,
      setting: { ...previous.setting, model, checked: false },
      message: "模擬モデル選択済み · 実API利用可否未確認",
    });
    this.changed();
    return true;
  }
}
