import { button, el } from "./ui";
import { evaluate, grade, type QuestionScenario } from "./caa";
import { feedbackMessage } from "./feedback";
import { unresolvedQuestions, type Book } from "./improvements";
import type { History } from "./history";
import type { LearningStore } from "./diagram-exercise";
export function resumeReview(
  book: Book,
  store: LearningStore,
  finish: () => void,
  sourceResume?: History["resume"],
) {
  const root = el("section", undefined, "resume-review");
  root.tabIndex = -1;
  const { history } = store;
  const resume = sourceResume === undefined ? history.resume : sourceResume;
  const sameVersion =
    resume?.bookId === book.bookId && resume.version === book.version;
  const previous = sameVersion
    ? book.blocks.find((b) => b.id === resume.blockId)
    : undefined;
  const question = sameVersion
    ? [...history.attempts]
        .reverse()
        .map((a) =>
          a.version === book.version
            ? book.blocks.find(
                (b) => b.id === a.blockId && b.kind === "question",
              )
            : undefined,
        )
        .find(Boolean)
    : undefined;
  const scenario: QuestionScenario =
    question?.kind === "question" ? question.scenario : "report";
  const prompt =
    question?.kind === "question"
      ? question.prompt
      : '親は issue ";"、子は iodef だけ。Let’s Encrypt は api.example.com に対して CAA 上、許可されるでしょうか？';
  const stamp = () => ({
    bookId: book.bookId,
    version: book.version,
    blockId: previous?.id ?? "read",
    userId: history.userId,
    time: new Date().toISOString(),
  });
  root.append(
    el("h2", "続きの前に、任意の1問"),
    el(
      "p",
      sameVersion
        ? `前回触れた内容：${previous?.title ?? "このセクション"}`
        : "初回・新版の導入確認です。旧版の正誤や再開位置を現版へ引き継いで評価しません。",
    ),
    el(
      "p",
      "前回の要点は回答後に示します。覚えている範囲で答えるか、復習をスキップできます。",
    ),
  );
  const doubts = unresolvedQuestions(
    history.questions,
    history.questionEvents,
    book.bookId,
  );
  const pending = el("details");
  pending.append(el("summary", `未解決の疑問（${doubts.length}件）`));
  for (const q of doubts)
    pending.append(el("p", `${q.text}（${q.blockId} / v${q.version}）`));
  if (!doubts.length)
    pending.append(el("p", "保存された未解決の疑問はありません。"));
  root.append(pending, el("p", prompt));
  const answers = el("div", undefined, "answer-options");
  const result = el("div");
  result.setAttribute("aria-live", "polite");
  let answered = false;
  function record(answer: "allow" | "deny" | null) {
    if (answered) return;
    answered = true;
    const recallId = crypto.randomUUID();
    const correct = answer === null ? null : grade(scenario, answer);
    history.recalls.push({
      ...stamp(),
      recallId,
      sourceVersion: resume?.version ?? null,
      scenario,
      answer,
      correct,
    });
    store.save();
    if (answer === null) {
      finish();
      return;
    }
    answers.querySelectorAll("button").forEach((b) => (b.disabled = true));
    result.append(
      feedbackMessage(
        correct ? "success" : "error",
        correct ? "想起の回答は正解です" : "想起の回答を確認しましょう",
        evaluate(scenario).reason,
      ),
      el("h3", "前回の要点"),
      el(
        "p",
        "対象名から親へ探索し、最初の CAA RRset を採用します。親子は合算しません。CAA 上の許可と証明書の発行成功は別です。",
      ),
    );
    const label = el("label", "理解の自己申告（任意・想起の正誤とは別）");
    const select = el("select");
    for (const [value, text] of [
      ["", "選ばなくても進めます"],
      ["clearer", "前より説明できそう"],
      ["unchanged", "変わらない"],
      ["unsure", "まだ迷う"],
    ]) {
      const o = el("option", text);
      o.value = value;
      select.append(o);
    }
    label.append(select);
    const report = button("自己申告を保存", () => {
      if (!select.value || report.disabled) return;
      history.recallReports.push({
        ...stamp(),
        reportId: crypto.randomUUID(),
        recallId,
        understanding: select.value as "clearer" | "unchanged" | "unsure",
      });
      report.disabled = true;
      store.save();
    });
    result.append(label, report, button("続きへ進む", finish));
  }
  answers.append(
    button("想起：CAA 上、許可", () => record("allow")),
    button("想起：CAA 上、禁止", () => record("deny")),
  );
  root.append(
    answers,
    result,
    button("復習をスキップして続きへ", () =>
      answered ? finish() : record(null),
    ),
  );
  return root;
}
