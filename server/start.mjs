import { FileLedger } from "./ledger.mjs";
import { GenerationService } from "./service.mjs";
import { localServer } from "./http.mjs";
import { registry, selectionPolicy } from "./registry.mjs";

// No env lookup, API key, live transport, or automatic provider selection.
// Future credentials come from an authenticated per-user BYOK resolver, never a shared LLM key.
const service = new GenerationService({
  ledger: new FileLedger(".local-state/generation"),
  registry,
  selectionPolicy,
});
await localServer({ service }).listen();
// Only a constant status is logged; requests, token and provider errors are never logged.
console.info(
  "Local generation adapter: UNCONNECTED. Listening on 127.0.0.1:5274.",
);
