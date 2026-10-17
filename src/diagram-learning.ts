import { z } from "zod";
import { denyRecords, evaluateName, scenarios, type Scenario } from "./caa";
export const learningIdentity = {
  bookId: z.string(),
  version: z.string(),
  blockId: z.string(),
  userId: z.string(),
  time: z.string().datetime(),
};
const record = z.object({
  flags: z.literal(0),
  tag: z.enum(["issue", "iodef"]),
  value: z.string(),
});
export const snapshotSchema = z.object({
  scenario: z.enum(["absent", "report", "deny", "allow"]),
  target: z.literal("api.example.com"),
  issuer: z.literal("letsencrypt.org"),
  tree: z.object({
    "api.example.com": z.array(record),
    "example.com": z.array(record),
  }),
});
export const predictionSchema = z.object({
  ...learningIdentity,
  attemptId: z.string(),
  snapshot: snapshotSchema,
  prediction: z.enum(["allow", "deny"]).nullable(),
  reason: z.string().max(1000),
});
export const revealSchema = z.object({
  ...learningIdentity,
  revealId: z.string(),
  attemptId: z.string(),
  allowed: z.boolean(),
  correct: z.boolean().nullable(),
});
export const reflectionSchema = z.object({
  ...learningIdentity,
  reflectionId: z.string(),
  attemptId: z.string(),
  difference: z.string().max(1000),
  changed: z.string().max(1000),
  helpful: z.string().max(1000),
  understanding: z.enum(["clearer", "unchanged", "unsure"]).nullable(),
});
export type Prediction = z.infer<typeof predictionSchema>;
export type Reveal = z.infer<typeof revealSchema>;
export type Reflection = z.infer<typeof reflectionSchema>;
export function scenarioSnapshot(scenario: Scenario) {
  return snapshotSchema.parse({
    scenario,
    target: "api.example.com",
    issuer: "letsencrypt.org",
    tree: {
      "api.example.com": scenarios.find((s) => s.id === scenario)!.records,
      "example.com": denyRecords,
    },
  });
}
export function comparePrediction(prediction: Prediction) {
  const result = evaluateName(
    prediction.snapshot.tree,
    prediction.snapshot.target,
    prediction.snapshot.issuer,
  );
  return {
    result,
    correct:
      prediction.prediction === null
        ? null
        : (prediction.prediction === "allow") === result.allowed,
  };
}
