// Providers chosen by the user; sending, data conditions, credentials and billing remain unapproved.
export const registry = [
  {
    id: "openai-luna-candidate",
    provider: "openai",
    providerChosen: true,
    model: "gpt-6-luna",
    purposes: ["term-explanation", "book-addition", "evidence-check"],
    structuredOutput: true,
    dataConditions:
      "API normally excluded from training; abuse logs up to 30 days; store=false is not ZDR.",
    dataConditionsAccepted: false,
    approval: "disabled",
    priceCheckedAt: "2026-10-11T00:00:00.000Z",
    // Conservative reservation rates, including the higher long-context cache-write rate.
    inputUsdMicrosPerMillion: 250000,
    outputUsdMicrosPerMillion: 750000,
    inputTokens: 8000,
    outputTokens: 2000,
    tokenCountMargin: null,
    tokenCountTermsConfirmed: false,
  },
  {
    id: "anthropic-haiku-candidate",
    provider: "anthropic",
    providerChosen: true,
    model: "claude-haiku-5-5",
    purposes: ["term-explanation", "book-addition", "evidence-check"],
    structuredOutput: true,
    dataConditions:
      "Commercial API retention normally up to 30 days with exceptions; structured JSON has feature-specific ZDR/schema-cache conditions. Account terms unconfirmed.",
    dataConditionsAccepted: false,
    approval: "disabled",
    priceCheckedAt: "2026-10-11T00:00:00.000Z",
    // Full long-context 1-hour cache-write upper bound; no cache-control is requested.
    inputUsdMicrosPerMillion: 1000000,
    outputUsdMicrosPerMillion: 2500000,
    inputTokens: 8000,
    outputTokens: 2000,
    tokenCountMargin: null,
    tokenCountTermsConfirmed: false,
  },
];
// Assign only after choosing permitted models for each purpose; no implicit fallback.
export const selectionPolicy = Object.freeze({
  "term-explanation": null,
  "book-addition": null,
  "evidence-check": null,
});
