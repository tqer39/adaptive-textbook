import { feedbackMessage, policyFeedback } from "./feedback";
import type { Block } from "./schema";
import { diagramExercise, type LearningStore } from "./diagram-exercise";
import { issuanceSequence, lookupFlow } from "./process-diagrams";
import { scopeDiagram } from "./scope-diagram";
import { evaluate } from "./caa";
import { button, el, markdown } from "./ui";
import { addTermHelp, nearbyTermHelp, type TermContext } from "./terms";
import { openReaderDialog } from "./reader-dialog";
import { questionSupport } from "./question-support";
import { mobileDnsTree } from "./mobile-dns-tree";
import { formatRecord } from "./caa";
const questionStates = new Map<string, "allow" | "deny">();
export function renderBlock(
  block: Block,
  answer: (value: "allow" | "deny", correct: boolean) => void,
  identity: { bookId: string; version: string },
  learningStore: LearningStore,
) {
  const context: TermContext = { ...identity, blockId: block.id };
  const root = el("section");
  root.append(el("h2", block.title));
  if (block.kind === "reading" && block.outcomes) {
    const goals = el("div", undefined, "learning-outcomes");
    goals.append(el("h3", "この教科書で理解できること"));
    const list = el("ul");
    for (const outcome of block.outcomes) list.append(el("li", outcome));
    goals.append(
      list,
      el(
        "p",
        "固定の模擬 DNS で考える練習です。実クラウドの設定や本物の証明書発行は行いません。",
        "muted",
      ),
    );
    root.append(goals);
  }
  if (block.kind === "reading" || block.kind === "summary") {
    if (block.kind === "reading" && block.visual === "lookup-flow") {
      const [lead, ...rest] = block.markdown.split("\n\n");
      root.append(markdown(lead), lookupFlow(), markdown(rest.join("\n\n")));
    } else {
      root.append(markdown(block.markdown));
      if (block.kind === "reading" && block.advanced)
        root.append(markdown(block.advanced));
      if (block.kind === "reading" && block.visual === "issuance-sequence")
        root.append(issuanceSequence());
    }
  }
  if (block.kind === "diagram")
    root.append(
      el(
        "p",
        "親の禁止は固定です。子の設定を変えて、探索がどこで止まるかを追ってください。",
      ),
      diagramExercise(context, learningStore),
    );
  if (block.kind === "scope-diagram") root.append(scopeDiagram());
  if (block.kind === "applications") {
    for (const application of block.cases) {
      const card = el("div", undefined, "application");
      card.append(
        el("h3", application.title),
        el("p", `予測: ${application.prediction}`),
      );
      const details = el("details");
      details.append(el("summary", "予測して結果を見る"));
      const result = evaluate(application.scenario);
      details.append(
        policyFeedback(result.allowed, result.reason),
        el("p", `助かる場面: ${application.benefit}`),
      );
      card.append(details);
      root.append(card);
    }
    root.append(
      el(
        "p",
        "標準に準拠する CA が発行前に確認する制御です。所有確認など、実際の発行に必要な他条件は別です。",
        "muted",
      ),
    );
  }
  if (block.kind === "question") {
    root.append(el("p", block.prompt));
    const scenario = block.scenario;
    const key = `${identity.bookId}:${identity.version}:${block.id}`;
    const group = el("div", undefined, "answer-options");
    const feedback = el("div", undefined, "question-feedback");
    feedback.setAttribute("aria-live", "polite");
    function showFeedback(value: "allow" | "deny") {
      const support = questionSupport(scenario, value);
      group.querySelectorAll("button").forEach((b) => (b.disabled = true));
      feedback.replaceChildren(
        feedbackMessage(
          support.correct ? "success" : "error",
          support.correct
            ? "正解です"
            : "不正解：もう一度、探索の停止条件を確認しましょう",
          support.text,
          true,
        ),
      );
      if (!support.correct) feedback.append(el("p", support.result.reason));
      feedback.dataset.misconceptionId = support.correct
        ? "reason-check"
        : support.id;
      const trace = el("ol");
      for (const step of support.result.trace) trace.append(el("li", step));
      const review = button("該当する図と理由を確認", () => {
        const content = el("div");
        content.append(
          el("p", `注目する箇所：${support.focus}`),
          el(
            "p",
            "この問題と同じ固定 DNS 設定から、照会した名前だけを図示します。集合を採用した後の親・兄弟は探索しません。外部 DNS の操作はありません。",
          ),
        );
        content.append(
          mobileDnsTree(
            support.result.lookups.map((lookup, i, all) => ({
              name: lookup.name,
              parent: all[i + 1]?.name,
              detail: lookup.hasRecords
                ? "ここで RRset を採用・探索終了"
                : "CAA なし → 親へ探索",
            })),
          ),
        );
        content.querySelector("figure")!.classList.add("review-dns-tree");
        content.querySelectorAll(".dns-node strong").forEach((name) => {
          if (name.textContent === support.result.owner)
            name.parentElement?.setAttribute("aria-current", "step");
        });
        content.append(el("p", `採用：${support.result.owner ?? "なし"}`));
        for (const record of support.result.selected)
          content.append(el("code", formatRecord(record)));
        content.append(
          policyFeedback(support.result.allowed, support.result.reason),
          el(
            "p",
            "CAA ポリシー上の判断であり、発行成功ではありません。",
            "muted",
          ),
        );
        openReaderDialog(`question:${key}`, "問題の図を確認", content, review);
      });
      feedback.append(
        trace,
        review,
        button("別の回答で再試行", () => {
          questionStates.delete(key);
          group.querySelectorAll("button").forEach((b) => (b.disabled = false));
          feedback.replaceChildren();
          group.querySelector("button")?.focus();
        }),
      );
      addTermHelp(feedback, context);
    }
    for (const value of ["allow", "deny"] as const)
      group.append(
        button(
          value === "allow" ? "CAA 上、許可される" : "CAA 上、禁止される",
          () => {
            if (questionStates.has(key)) return;
            questionStates.set(key, value);
            const support = questionSupport(block.scenario, value);
            answer(value, support.correct);
            showFeedback(value);
          },
        ),
      );
    root.append(group, feedback);
    const previous = questionStates.get(key);
    if (previous) showFeedback(previous);
  }
  addTermHelp(root, context);
  if (block.kind === "diagram" || block.kind === "scope-diagram")
    root.insertBefore(nearbyTermHelp(context), root.children[1] ?? null);
  if (block.kind === "reading" && block.visual === "issuance-sequence")
    root
      .querySelector(".process-figure")
      ?.prepend(
        nearbyTermHelp(context, [
          "ca",
          "lets-encrypt",
          "resolver",
          "authoritative-dns",
        ]),
      );
  return root;
}
