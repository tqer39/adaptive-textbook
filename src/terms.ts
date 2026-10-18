import { button, el } from "./ui";
import { openReaderDialog } from "./reader-dialog";
import { termIds, termExplanation, type TermId } from "./term-dictionary";
let saveTermQuestion:
  | ((
      context: TermContext,
      term: TermId,
      text: string,
      excerpt: string,
    ) => string)
  | undefined;
export function setTermQuestionHandler(
  handler: NonNullable<typeof saveTermQuestion>,
) {
  saveTermQuestion = handler;
}
export type TermContext = { bookId: string; version: string; blockId: string };
function termButton(term: TermId, context: TermContext) {
  const info = termExplanation(term, context.blockId);
  const trigger = button(
    info.label,
    () => {
      const content = el("div");
      content.append(
        el("h3", "短い定義"),
        el("p", info.definition),
        el("h3", "今の文脈"),
        el("p", info.context),
        el("h3", "具体例"),
        el("p", info.example),
      );
      if (info.detail) {
        const details = el("details");
        details.append(el("summary", "もう少し詳しく"), el("p", info.detail));
        content.append(details);
      }
      const source = el("a", `出典：${info.source.title}`);
      source.href = info.source.url;
      source.target = "_blank";
      source.rel = "noreferrer";
      if (info.relatedSource) {
        const related = el("a", `関連資料：${info.relatedSource.title}`);
        related.href = info.relatedSource.url;
        related.target = "_blank";
        related.rel = "noreferrer";
        content.append(related);
      }
      content.append(
        source,
        el(
          "p",
          "開いたことを理解済みとして記録しません。AI 呼び出しはありません。",
          "muted",
        ),
      );
      if (saveTermQuestion) {
        const form = el("details");
        form.append(el("summary", "この用語への質問を残す（生成未接続）"));
        const label = el("label", "この用語への質問（1000文字まで）");
        const input = el("textarea");
        input.rows = 2;
        input.maxLength = 1000;
        label.append(input);
        const result = el("p");
        result.setAttribute("role", "status");
        form.append(
          label,
          button("用語の質問をローカル保存", () => {
            result.textContent = input.value.trim()
              ? saveTermQuestion!(
                  context,
                  term,
                  input.value.trim(),
                  info.label + "\n" + info.definition + "\n" + info.context,
                )
              : "質問を入力してください。";
          }),
          result,
        );
        content.append(form);
      }
      openReaderDialog(
        `term:${context.bookId}:${context.version}:${context.blockId}:${term}`,
        `${info.label}の説明`,
        content,
        trigger,
      );
    },
    "term-trigger",
  );
  trigger.setAttribute("aria-label", `${info.label}の説明を開く`);
  trigger.dataset.termId = term;
  trigger.dataset.blockId = context.blockId;
  return trigger;
}
export function addTermHelp(root: HTMLElement, context: TermContext) {
  for (const term of termIds) {
    if (root.querySelector(`[data-term-id="${term}"]`)) continue;
    const word = termExplanation(term, context.blockId).label;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node: Node | null;
    while ((node = walker.nextNode())) {
      const parent = node.parentElement;
      if (
        !parent ||
        !parent.closest(
          ".prose, section > p, .question-feedback, .process-figure",
        ) ||
        parent.closest("button,a,svg")
      )
        continue;
      const at = node.textContent!.indexOf(word);
      if (at < 0) continue;
      const text = node.textContent!;
      (node as Text).replaceWith(
        document.createTextNode(text.slice(0, at)),
        termButton(term, context),
        document.createTextNode(text.slice(at + word.length)),
      );
      break;
    }
  }
}
export function nearbyTermHelp(
  context: TermContext,
  terms: readonly TermId[] = ["ca", "rrset", "iodef", "lets-encrypt"],
) {
  const links = el("p", undefined, "nearby-terms");
  links.append(el("span", "図の用語： "));
  for (const term of terms) {
    links.append(termButton(term, context), document.createTextNode(" "));
  }
  return links;
}
