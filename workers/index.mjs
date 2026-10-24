import { DurableObject } from "cloudflare:workers";
import { AccountVaultCore } from "./vault.mjs";
import { handleAccount } from "./http.mjs";
import { productionFetch } from "./better-auth.mjs";
import { FeedCollector } from "./feed-collector.mjs";
export class AccountVault extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.core = new AccountVaultCore(ctx.storage, {
      keyring: env.BYOK_ENCRYPTION_KEYRING,
    });
    this.collector = new FeedCollector(ctx.storage, {
      enabled: env.RSS_COLLECTION_ENABLED === "true",
    });
  }
  async fetch(request) {
    return handleAccount(this.core, request, this.collector);
  }
  async alarm() {
    await this.collector.alarm();
  }
}
// No test identity/provider may be supplied by env/header. Input remains disabled.
export default { fetch: productionFetch };
