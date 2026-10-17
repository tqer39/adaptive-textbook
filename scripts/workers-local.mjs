// Offline dev only: no Wrangler account/config lookup, .env loader, secrets or outbound fetch.
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { build } from "esbuild";
import { readFile } from "node:fs/promises";
import { resolve, sep, extname } from "node:path";
const root = resolve("dist");
const code = (
  await build({
    entryPoints: ["workers/index.mjs"],
    bundle: true,
    write: false,
    format: "esm",
    platform: "neutral",
    target: "es2022",
    external: ["cloudflare:workers"],
    logLevel: "silent",
  })
).outputFiles[0].text;
const mf = new Miniflare(
  convertV4MiniflareOptions({
    name: "adaptive-textbook-offline",
    modules: true,
    script: code,
    compatibilityDate: "2026-10-11",
    host: "127.0.0.1",
    port: 8787,
    resourcePersistencePath: resolve(".local-state/worker-dev"),
    durableObjects: {
      ACCOUNTS: { className: "AccountVault", useSQLite: true },
    },
    bindings: { APP_ORIGIN: "http://127.0.0.1:8787" },
    serviceBindings: {
      ASSETS: async (request) => {
        if (!["GET", "HEAD"].includes(request.method))
          return new Response("", { status: 405 });
        const path = resolve(root, "." + new URL(request.url).pathname);
        if (!path.startsWith(root + sep) && path !== root)
          return new Response("", { status: 404 });
        let body;
        let file = path === root ? resolve(root, "index.html") : path;
        try {
          body = await readFile(file);
        } catch {
          return new Response("", { status: 404 });
        }
        const type =
          {
            ".html": "text/html",
            ".css": "text/css",
            ".js": "text/javascript",
          }[extname(file)] ?? "application/octet-stream";
        return new Response(request.method === "HEAD" ? null : body, {
          headers: {
            "Content-Type": type,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
          },
        });
      },
    },
    outboundService: () => {
      throw Error("offline-dev-outbound-disabled");
    },
    logRequests: false,
  }),
);
await mf.ready;
console.info(
  "Offline Workers preview: http://127.0.0.1:8787 — auth/key input/API send disabled.",
);
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  await mf.dispose();
}
process.once("SIGINT", () => {
  void close();
});
process.once("SIGTERM", () => {
  void close();
});
