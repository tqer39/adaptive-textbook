import { z } from "zod";
import { questionScenarios } from "./caa";
const base = { id: z.string().regex(/^[a-z-]+$/), title: z.string() };
export const blockSchema = z.discriminatedUnion("kind", [
  z.object({
    ...base,
    kind: z.literal("reading"),
    markdown: z.string(),
    advanced: z.string().optional(),
    outcomes: z.array(z.string().min(1)).min(3).max(4).optional(),
    visual: z.enum(["issuance-sequence", "lookup-flow"]).optional(),
  }),
  z.object({ ...base, kind: z.literal("diagram") }),
  z.object({ ...base, kind: z.literal("scope-diagram") }),
  z.object({
    ...base,
    kind: z.literal("applications"),
    cases: z
      .array(
        z.object({
          title: z.string(),
          scenario: z.enum(questionScenarios),
          prediction: z.string(),
          benefit: z.string(),
        }),
      )
      .min(1),
  }),
  z.object({
    ...base,
    kind: z.literal("question"),
    scenario: z.enum(questionScenarios),
    prompt: z.string(),
  }),
  z.object({ ...base, kind: z.literal("summary"), markdown: z.string() }),
]);
export const bookSchema = z.object({
  bookId: z.string(),
  contentSchemaVersion: z
    .union([z.literal(1), z.literal(2), z.literal(3), z.literal(4)])
    .default(1),
  version: z.string(),
  title: z.string(),
  blocks: z.array(blockSchema).min(1),
});
export type Block = z.infer<typeof blockSchema>;
