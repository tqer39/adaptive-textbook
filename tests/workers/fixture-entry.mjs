// Local Miniflare ONLY; never imported by workers/index.mjs or wrangler.jsonc.
import { AccountVault as ProductionVault } from "../../workers/index.mjs";
import { createHandler } from "../../workers/http.mjs";
import { registry } from "../../server/registry.mjs";
const date = "2026-10-11T00:00:00.000Z";
const source = {
  id: "rfc8659",
  url: "https://www.rfc-editor.org/rfc/rfc8659.html",
  checkedAt: date,
  body: "The first CAA RRset is selected.",
};
export class AccountVault extends ProductionVault {
  constructor(ctx, env) {
    super(ctx, env);
    this.core.now = () => new Date(date);
    this.core.generation = {
      policy: {
        confirmedCostUpperBounds: true,
        checkedAt: date,
        fixedMilliYen: 496850,
        safetyMilliYen: 0,
        yenPerUsdMilli: 200000,
        taxFeePermille: 1200,
        providerCapsMilliYen: {},
      },
      registry: registry.map((m) => ({
        ...m,
        approval: "test-only",
        dataConditionsAccepted: true,
        tokenCountMargin: 256,
        tokenCountTermsConfirmed: true,
      })),
      selectionPolicy: {},
      sources: [source],
      timeoutMs: 20,
      makeAdapter: (_provider, secret) => ({
        generate: async (payload) => {
          if (!secret.startsWith("DUMMY-")) throw Error("dummy-only-fixture");
          if (payload.question === "WAIT-MOCK") await new Promise(() => {});
          return {
            json: JSON.stringify({
              gap: "test",
              block: {
                id: "test-block",
                title: "test",
                kind: "reading",
                markdown: "最初のRRset",
              },
              references: [{ sourceId: "rfc8659", quote: source.body }],
            }),
            usage: { inputTokens: 100, outputTokens: 50 },
          };
        },
      }),
    };
  }
}
export default {
  fetch: createHandler({
    credentialsEnabled: true,
    authenticate: async (request) => {
      const value = request.headers.get("X-Test-Principal");
      if (!["test-a", "test-b"].includes(value)) return null;
      return {
        subject: `local-only:${value}`,
        sessionId: `local-session:${value}`,
      };
    },
  }),
};
