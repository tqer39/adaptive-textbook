import { z } from "zod";
import { bookSchema, blockSchema } from "./schema";
import { learningIdentity } from "./diagram-learning";
import { termIds } from "./term-dictionary";
import { questionScenarios } from "./caa";
export const questionSchema = z.object({
  ...learningIdentity,
  questionId: z.string(),
  termId: z.enum(termIds).nullable(),
  text: z.string().trim().min(1).max(1000),
  context: z.string().max(3000),
});
export const proposalSchema = z.object({
  ...learningIdentity,
  proposalId: z.string(),
  questionId: z.string(),
  originVersion: z.string(),
  mode: z.literal("manual"),
  gap: z.string().trim().min(1).max(1000),
  sourceUrl: z.string().url(),
  checkedOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  evidence: z.string().trim().min(1).max(2000),
  block: blockSchema,
});
export const proposalEventSchema = z.object({
  ...learningIdentity,
  eventId: z.string(),
  proposalId: z.string(),
  action: z.enum(["cancel", "apply"]),
});
export const questionEventSchema = z.object({
  ...learningIdentity,
  eventId: z.string(),
  questionId: z.string(),
  action: z.enum(["resolved", "open"]),
});
export const revisionSchema = z.object({
  ...learningIdentity,
  revisionId: z.string(),
  proposalId: z.string(),
  baseVersion: z.string(),
  book: bookSchema,
});
export const recallSchema = z.object({
  ...learningIdentity,
  recallId: z.string(),
  sourceVersion: z.string().nullable(),
  scenario: z.enum(questionScenarios),
  answer: z.enum(["allow", "deny"]).nullable(),
  correct: z.boolean().nullable(),
});
export const recallReportSchema = z.object({
  ...learningIdentity,
  reportId: z.string(),
  recallId: z.string(),
  understanding: z.enum(["clearer", "unchanged", "unsure"]),
});
export type Book = z.infer<typeof bookSchema>;
export type Question = z.infer<typeof questionSchema>;
export type Proposal = z.infer<typeof proposalSchema>;
export type Revision = z.infer<typeof revisionSchema>;
export type ProposalEvent = z.infer<typeof proposalEventSchema>;
export type QuestionEvent = z.infer<typeof questionEventSchema>;
export function unresolvedQuestions(
  questions: Question[],
  events: QuestionEvent[],
  bookId: string,
) {
  return questions.filter(
    (q) =>
      q.bookId === bookId &&
      events.filter((e) => e.questionId === q.questionId).at(-1)?.action !==
        "resolved",
  );
}
export function activeLocalBook(base: Book, revisions: Revision[]): Book {
  let current = base;
  for (const revision of revisions)
    if (
      revision.bookId === base.bookId &&
      revision.baseVersion === current.version &&
      revision.book.bookId === base.bookId &&
      revision.book.version === revision.version
    )
      current = bookSchema.parse(revision.book);
  return current;
}
export function officialSourceUrl(value: string) {
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      ["www.rfc-editor.org", "letsencrypt.org"].includes(url.hostname) &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
}
export function proposalProblem(
  proposal: Proposal,
  current: Book,
  events: ProposalEvent[],
  now = new Date(),
): string | null {
  if (
    proposal.bookId !== current.bookId ||
    proposal.version !== current.version
  )
    return "教材版が変わりました。この提案は保留です。現版で新しい提案を作ってください。";
  if (events.some((e) => e.proposalId === proposal.proposalId))
    return "取消済み、または反映済みの提案です。";
  if (!current.blocks.some((b) => b.id === proposal.blockId))
    return "追加先の節が見つかりません。";
  if (!["reading", "question"].includes(proposal.block.kind))
    return "許可する追加は説明・固定図つき説明・既存意味論の問題だけです。";
  if (!officialSourceUrl(proposal.sourceUrl))
    return "出典は HTTPS の RFC Editor または Let’s Encrypt 公式資料を指定してください。";
  const date = Date.parse(`${proposal.checkedOn}T00:00:00Z`);
  const today = Date.parse(now.toISOString().slice(0, 10) + "T00:00:00Z");
  if (
    !Number.isFinite(date) ||
    new Date(date).toISOString().slice(0, 10) !== proposal.checkedOn ||
    date > today ||
    today - date > 30 * 86400000
  )
    return "出典確認日が未確認・未来・30日超です。根拠を再確認するまで保留します。";
  if (
    current.blocks.some(
      (b) =>
        b.id === proposal.block.id ||
        (b.kind === proposal.block.kind && b.title === proposal.block.title) ||
        (b.kind === "reading" &&
          proposal.block.kind === "reading" &&
          b.markdown.trim() === proposal.block.markdown.trim()),
    )
  )
    return "同じID・見出し・説明が既にあります。重複追加を保留します。";
  return null;
}
export function applyProposal(
  current: Book,
  proposal: Proposal,
  events: ProposalEvent[],
  revisionId: string,
  now = new Date(),
): Book {
  const problem = proposalProblem(proposal, current, events, now);
  if (problem) throw Error(problem);
  const blocks = [...current.blocks];
  blocks.splice(
    blocks.findIndex((b) => b.id === proposal.blockId) + 1,
    0,
    proposal.block,
  );
  return bookSchema.parse({
    ...current,
    version: `${current.version.split("+local.")[0]}+local.${revisionId}`,
    blocks,
  });
}
