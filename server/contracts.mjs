import { z } from "zod";

const text = (max) => z.string().trim().min(1).max(max);
export const sourceIds = ["rfc8659", "letsencrypt-caa"];
const officialUrls = {
  rfc8659: "https://www.rfc-editor.org/rfc/rfc8659.html",
  "letsencrypt-caa": "https://letsencrypt.org/docs/caa/",
};
export const requestSchema = z
  .object({
    requestId: z.string().uuid(),
    bookId: text(100),
    version: text(100),
    blockId: text(100),
    question: text(1000),
    excerpt: text(3000),
    purpose: z.enum(["term-explanation", "book-addition", "evidence-check"]),
    modelId: text(100).optional(),
    sourceIds: z.array(z.enum(sourceIds)).min(1).max(2),
    approvedPublicText: z.literal(true),
  })
  .strict();
const base = {
  id: z
    .string()
    .regex(/^[a-z-]+$/)
    .max(100),
  title: text(120),
};
export const draftSchema = z
  .object({
    gap: text(1000),
    block: z.discriminatedUnion("kind", [
      z
        .object({
          ...base,
          kind: z.literal("reading"),
          markdown: text(4000),
          visual: z.enum(["issuance-sequence", "lookup-flow"]).optional(),
        })
        .strict(),
      z
        .object({
          ...base,
          kind: z.literal("question"),
          prompt: text(1000),
          scenario: z.enum(["absent", "report", "allow", "deny"]),
        })
        .strict(),
    ]),
    references: z
      .array(
        z.object({ sourceId: z.enum(sourceIds), quote: text(500) }).strict(),
      )
      .min(1)
      .max(4),
  })
  .strict();
export const sourceSchema = z
  .object({
    id: z.enum(sourceIds),
    url: z.string().url(),
    checkedAt: z.string().datetime(),
    body: text(20000),
  })
  .strict();
export const policySchema = z
  .object({
    confirmedCostUpperBounds: z.literal(true),
    checkedAt: z.string().datetime(),
    fixedMilliYen: z.number().int().min(0).max(500000),
    safetyMilliYen: z.number().int().min(0).max(500000),
    yenPerUsdMilli: z.number().int().positive().max(1000000),
    taxFeePermille: z.number().int().min(1000).max(10000),
    providerCapsMilliYen: z
      .record(z.string(), z.number().int().min(0).max(500000))
      .default({}),
  })
  .strict();
export const modelSchema = z
  .object({
    id: text(100),
    provider: text(100),
    model: text(100),
    purposes: z
      .array(z.enum(["term-explanation", "book-addition", "evidence-check"]))
      .min(1),
    structuredOutput: z.boolean(),
    dataConditions: text(2000),
    dataConditionsAccepted: z.boolean(),
    approval: z.enum(["disabled", "test-only"]),
    priceCheckedAt: z.string().datetime(),
    inputUsdMicrosPerMillion: z
      .number()
      .int()
      .positive()
      .max(100000000)
      .nullable(),
    outputUsdMicrosPerMillion: z
      .number()
      .int()
      .positive()
      .max(100000000)
      .nullable(),
    inputTokens: z.number().int().positive().max(8000),
    outputTokens: z.number().int().positive().max(2000),
    providerChosen: z.boolean().default(false),
    tokenCountMargin: z
      .number()
      .int()
      .min(0)
      .max(2000)
      .nullable()
      .default(null),
    tokenCountTermsConfirmed: z.boolean().default(false),
  })
  .strict();
export const limits = Object.freeze({
  inputTokens: 8000,
  outputTokens: 2000,
  bodyBytes: 32768,
  responseBytes: 16384,
});
export const usageSchema = z
  .object({
    inputTokens: z.number().int().min(0).max(8000),
    outputTokens: z.number().int().min(0).max(2000),
  })
  .strict();
export function fresh(date, now) {
  const age = now.getTime() - Date.parse(date);
  return Number.isFinite(age) && age >= 0 && age <= 30 * 86400000;
}
export function validateSources(request, sources, now) {
  return request.sourceIds.map((id) => {
    const source = sourceSchema.parse(sources.find((s) => s.id === id));
    if (source.url !== officialUrls[id] || !fresh(source.checkedAt, now))
      throw Error("source-unverified");
    return source;
  });
}
export function validateDraft(raw, sources) {
  if (
    typeof raw !== "string" ||
    new TextEncoder().encode(raw).byteLength > limits.responseBytes
  )
    throw Error("output-limit");
  const draft = draftSchema.parse(JSON.parse(raw));
  for (const ref of draft.references) {
    if (!sources.find((s) => s.id === ref.sourceId)?.body.includes(ref.quote))
      throw Error("source-mismatch");
  }
  // Only fixed component names and plain restricted Markdown; never provider code.
  if (/<\/?[a-z!]|```|javascript:|data:/i.test(JSON.stringify(draft.block)))
    throw Error("unsafe-content");
  return draft;
}
