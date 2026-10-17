import { z } from "zod";
import {
  predictionSchema,
  revealSchema,
  reflectionSchema,
} from "./diagram-learning";
import {
  questionSchema,
  proposalSchema,
  proposalEventSchema,
  questionEventSchema,
  revisionSchema,
  recallSchema,
  recallReportSchema,
} from "./improvements";
const identity = {
  bookId: z.string(),
  version: z.string(),
  blockId: z.string(),
  userId: z.string(),
  time: z.string().datetime(),
};
export const historySchema = z.object({
  schemaVersion: z.literal(1),
  userId: z.string(),
  attempts: z.array(
    z.object({
      ...identity,
      attemptId: z.string(),
      answer: z.enum(["allow", "deny"]),
      correct: z.boolean(),
    }),
  ),
  diagramPredictions: z.array(predictionSchema).default([]),
  diagramReveals: z.array(revealSchema).default([]),
  diagramReflections: z.array(reflectionSchema).default([]),
  questions: z.array(questionSchema).default([]),
  proposals: z.array(proposalSchema).default([]),
  proposalEvents: z.array(proposalEventSchema).default([]),
  questionEvents: z.array(questionEventSchema).default([]),
  bookRevisions: z.array(revisionSchema).default([]),
  recalls: z.array(recallSchema).default([]),
  recallReports: z.array(recallReportSchema).default([]),
  resume: z
    .object({
      ...identity,
      minutes: z.union([
        z.literal(5),
        z.literal(10),
        z.literal(15),
        z.literal(30),
      ]),
      planStart: z.number().int().min(0).optional(),
      // Legacy display preference; new resume entries omit it.
      difficulty: z.enum(["standard", "operations"]).optional(),
    })
    .nullable(),
});
export type History = z.infer<typeof historySchema>;
export const storageKey = "fieldnotes.history.v1";
export function emptyHistory(): History {
  return {
    schemaVersion: 1,
    userId: crypto.randomUUID(),
    attempts: [],
    diagramPredictions: [],
    diagramReveals: [],
    diagramReflections: [],
    questions: [],
    proposals: [],
    proposalEvents: [],
    questionEvents: [],
    bookRevisions: [],
    recalls: [],
    recallReports: [],
    resume: null,
  };
}
export function readHistory(storage: Pick<Storage, "getItem">): {
  history: History;
  error: boolean;
} {
  try {
    const raw = storage.getItem(storageKey);
    return {
      history: raw ? historySchema.parse(JSON.parse(raw)) : emptyHistory(),
      error: false,
    };
  } catch {
    return { history: emptyHistory(), error: true };
  }
}
export function writeHistory(
  storage: Pick<Storage, "setItem">,
  history: History,
): boolean {
  try {
    storage.setItem(storageKey, JSON.stringify(historySchema.parse(history)));
    return true;
  } catch {
    return false;
  }
}

// IDs, rather than JSON key order, identify append-only records across parsed snapshots.
export function mergeHistoryRecords(target: History, incoming: History) {
  const keys = {
    attempts: "attemptId",
    diagramPredictions: "attemptId",
    diagramReveals: "revealId",
    diagramReflections: "reflectionId",
    questions: "questionId",
    proposals: "proposalId",
    proposalEvents: "eventId",
    questionEvents: "eventId",
    bookRevisions: "revisionId",
    recalls: "recallId",
    recallReports: "reportId",
  } as const;
  for (const key of Object.keys(keys) as (keyof typeof keys)[]) {
    const id = keys[key];
    const rows = target[key] as { time: string }[];
    const ids = new Set(
      rows.map((row) => (row as unknown as Record<string, string>)[id]),
    );
    rows.unshift(
      ...incoming[key].filter(
        (row) => !ids.has((row as unknown as Record<string, string>)[id]),
      ),
    );
    rows.sort((a, b) => a.time.localeCompare(b.time));
  }
}
