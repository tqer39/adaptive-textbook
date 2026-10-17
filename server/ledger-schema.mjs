import { z } from "zod";
import { draftSchema, usageSchema } from "./contracts.mjs";
const recordSchema = z
  .object({
    requestId: z.string().uuid(),
    digest: z.string().regex(/^[a-f0-9]{64}$/),
    month: z.string().regex(/^\d{4}-\d{2}$/),
    policyDigest: z.string(),
    modelId: z.string(),
    provider: z.string(),
    reservedMilliYen: z.number().int().positive().max(500000),
    spentMilliYen: z.number().int().min(0).max(500000),
    state: z.enum(["reserved", "unknown", "complete", "rejected"]),
    draft: draftSchema.nullable(),
    usage: usageSchema.optional(),
  })
  .strict();
export const ledgerSchema = z
  .object({ schema: z.literal(1), records: z.array(recordSchema).max(20000) })
  .strict();
