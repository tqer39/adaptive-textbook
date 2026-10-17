import { build } from "esbuild";
await build({
  entryPoints: ["workers/index.mjs"],
  outfile: ".local-state/worker-build/index.mjs",
  bundle: true,
  format: "esm",
  platform: "neutral",
  target: "es2022",
  external: ["cloudflare:workers"],
  logLevel: "silent",
});
