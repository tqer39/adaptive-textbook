import { z } from "zod";
import { hash, bytes } from "./crypto.mjs";
const principal = z
  .object({
    subject: z.string().min(1).max(300),
    sessionId: z.string().min(1).max(300),
  })
  .strict();
export function json(status, value) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
export async function readBody(request) {
  if (
    request.headers.get("Content-Type") !== "application/json" ||
    !request.body
  )
    throw Error("invalid-body");
  const reader = request.body.getReader();
  let size = 0;
  let text = "";
  const decoder = new TextDecoder("utf-8", { fatal: true });
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 32768) throw Error("body-limit");
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return JSON.parse(text);
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
/** Production entry supplies no authenticator; only a separately bundled test entry injects a principal. */
export function createHandler({
  authenticate = null,
  credentialsEnabled = false,
} = {}) {
  return async (request, env) => {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/"))
      return env.ASSETS
        ? env.ASSETS.fetch(request)
        : json(404, { status: "not-found" });
    if (!authenticate)
      return json(503, {
        status: "auth-unconfigured",
        realKeyInputEnabled: false,
      });
    try {
      const origin = request.headers.get("Origin");
      const browserRead =
        request.method === "GET" &&
        origin === null &&
        request.headers.get("Sec-Fetch-Site") === "same-origin";
      if (
        url.origin !== env.APP_ORIGIN ||
        (origin !== env.APP_ORIGIN && !browserRead) ||
        url.search
      )
        return json(403, { status: "forbidden" });
      const verified = principal.safeParse(await authenticate(request));
      if (!verified.success) return json(401, { status: "unauthenticated" });
      const owner = await hash(verified.data.subject);
      const stub = env.ACCOUNTS.get(env.ACCOUNTS.idFromName(owner));
      let action;
      let provider;
      const match = /^\/api\/credentials\/(openai|anthropic)$/.exec(
        url.pathname,
      );
      const check = /^\/api\/credentials\/(openai|anthropic)\/check$/.exec(
        url.pathname,
      );
      if (request.method === "GET" && url.pathname === "/api/session")
        action = "session";
      else if (request.method === "GET" && url.pathname === "/api/budget")
        action = "budget";
      else if (check && request.method === "POST") {
        provider = check[1];
        action = "check";
      } else if (match) {
        provider = match[1];
        action = {
          GET: "status",
          POST: "register",
          PUT: "replace",
          DELETE: "delete",
          PATCH: "model",
        }[request.method];
      } else if (request.method === "POST" && url.pathname === "/api/proposals")
        action = "propose";
      if (!action) return json(404, { status: "not-found" });
      const mutating = !["session", "budget", "status"].includes(action);
      if (mutating && !credentialsEnabled)
        return json(503, {
          status: "credentials-unconfigured",
          realKeyInputEnabled: false,
        });
      const data = mutating ? await readBody(request) : null;
      return stub.fetch(
        new Request("https://account.internal/command", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action,
            provider,
            principal: verified.data,
            csrf: request.headers.get("X-CSRF-Token"),
            data,
          }),
        }),
      );
    } catch {
      return json(503, { status: "held" });
    }
  };
}
export async function handleAccount(core, request) {
  try {
    const command = await readBody(request);
    // Internal binding only. No browser-selected owner or credential handles.
    const owner = await core.authorize(
      command.principal,
      command.csrf,
      !["session", "budget", "status"].includes(command.action),
    );
    let value;
    if (command.action === "session")
      value = await core.session(command.principal);
    else if (command.action === "status")
      value = await core.status(owner, command.provider);
    else if (command.action === "budget") value = await core.budget(owner);
    else if (command.action === "check")
      value = await core.check(owner, command.provider, command.data);
    else if (command.action === "propose")
      value = await core.propose(owner, command.data);
    else
      value = await core.mutate(
        owner,
        command.provider,
        command.action,
        command.data,
      );
    // Bound responses contain metadata/validated proposal only; never plaintext or ciphertext.
    if (bytes(JSON.stringify(value)).byteLength > 20000)
      throw Error("response-limit");
    return json(200, value);
  } catch (error) {
    const known = [
      "csrf-invalid",
      "owner-mismatch",
      "rate-limit",
      "revision-conflict",
      "id-conflict",
      "state-conflict",
      "model-unapproved",
      "encryption-unconfigured",
      "credential-unavailable",
      "mutation-limit",
    ];
    return json(
      error.message === "csrf-invalid" || error.message === "owner-mismatch"
        ? 403
        : error.message === "rate-limit"
          ? 429
          : 409,
      { status: known.includes(error.message) ? error.message : "held" },
    );
  }
}
