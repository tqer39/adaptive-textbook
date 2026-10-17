import { z } from "zod";
import type { Provider } from "./byok";
const settingSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    model: z.string().nullable(),
    state: z.enum(["registered", "deleted"]),
    checked: z.boolean(),
    connection: z.literal("unconnected"),
  })
  .strict();
const sessionSchema = z
  .object({
    csrfToken: z.string().min(20).max(100),
    connection: z.literal("unconnected"),
    realKeyInputEnabled: z.boolean(),
  })
  .strict();
type Reply =
  | { status: "metadata"; setting: z.infer<typeof settingSchema> }
  | { status: "unconnected" | "held" };
/** Prepared same-origin client. Current server never enables real input; no key persistence/retry/logging. */
export class CredentialClient {
  private csrf: string | null = null;
  private enabled = false;
  constructor(
    private send: typeof fetch = (input, init) => fetch(input, init),
  ) {}
  async session() {
    this.csrf = null;
    this.enabled = false;
    try {
      const response = await this.send("/api/session", {
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
      });
      if (!response.ok) return { realKeyInputEnabled: false };
      const result = sessionSchema.safeParse(await response.json());
      if (!result.success) return { realKeyInputEnabled: false };
      this.csrf = result.data.csrfToken;
      this.enabled = result.data.realKeyInputEnabled;
      return { realKeyInputEnabled: this.enabled };
    } catch {
      return { realKeyInputEnabled: false };
    }
  }
  lock() {
    this.enabled = false;
    this.csrf = null;
  }
  private async call(
    provider: Provider,
    method: string,
    body?: unknown,
  ): Promise<Reply> {
    if (!["openai", "anthropic"].includes(provider)) return { status: "held" };
    if (method !== "GET" && (!this.enabled || !this.csrf))
      return { status: "unconnected" };
    try {
      const response = await this.send(`/api/credentials/${provider}`, {
        method,
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: body
          ? { "Content-Type": "application/json", "X-CSRF-Token": this.csrf! }
          : undefined,
        body: body ? JSON.stringify(body) : undefined,
      });
      if (!response.ok) {
        if (response.status === 401 || response.status === 403) this.lock();
        return { status: "held" };
      }
      const setting = settingSchema.safeParse(await response.json());
      return setting.success
        ? { status: "metadata", setting: setting.data }
        : { status: "held" };
    } catch {
      return { status: "held" };
    }
  }
  status(provider: Provider) {
    return this.call(provider, "GET");
  }
  register(
    provider: Provider,
    data: {
      requestId: string;
      expectedRevision: number;
      model: string;
      key: string;
    },
  ) {
    return this.call(provider, "POST", data);
  }
  replace(
    provider: Provider,
    data: {
      requestId: string;
      expectedRevision: number;
      model: string;
      key: string;
    },
  ) {
    return this.call(provider, "PUT", data);
  }
  remove(
    provider: Provider,
    data: { requestId: string; expectedRevision: number },
  ) {
    return this.call(provider, "DELETE", data);
  }
  selectModel(
    provider: Provider,
    data: { requestId: string; expectedRevision: number; model: string },
  ) {
    return this.call(provider, "PATCH", data);
  }
}
