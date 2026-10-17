import { button, el, markdown } from "./ui";
import { feedbackMessage } from "./feedback";
import { termExplanation, termIds, type TermId } from "./term-dictionary";
import {
  officialSourceUrl,
  proposalProblem,
  proposalSchema,
  unresolvedQuestions,
  type Book,
  type Proposal,
} from "./improvements";
import type { LearningStore } from "./diagram-exercise";
import { scenarios } from "./caa";
export function questionWorkbench(
  book: Book,
  blockId: string,
  store: LearningStore,
  accept: (p: Proposal) => Promise<string | null>,
) {
  const root = el("details", undefined, "question-workbench");
  root.append(el("summary", "この節・用語への質問と教材の改善"));
  const body = el("div");
  root.append(body);
  const { history } = store;
  const block = book.blocks.find((b) => b.id === blockId)!;
  const stamp = () => ({
    bookId: book.bookId,
    version: book.version,
    blockId,
    userId: history.userId,
    time: new Date().toISOString(),
  });
  function field(title: string, multiline = true) {
    const label = el("label", title);
    const control = multiline ? el("textarea") : el("input");
    if (control instanceof HTMLTextAreaElement) {
      control.rows = 2;
      control.maxLength = 1000;
    }
    label.append(control);
    return { label, control };
  }
  function draw() {
    body.replaceChildren(
      feedbackMessage(
        "neutral",
        "生成未接続",
        "質問・手動提案・差分の保存と反映はこのブラウザ内で動きます。AI の生成成功を示す候補はありません。外部送信は行いません。",
      ),
    );
    const termLabel = el("label", "質問する用語（任意）");
    const term = el("select");
    term.append(el("option", "節全体"));
    term.options[0].value = "";
    for (const id of termIds) {
      const o = el("option", termExplanation(id, blockId).label);
      o.value = id;
      term.append(o);
    }
    termLabel.append(term);
    const question = field("質問（1000文字まで）");
    const message = el("div");
    message.setAttribute("role", "status");
    body.append(
      termLabel,
      question.label,
      button("質問をローカル保存", () => {
        if (!question.control.value.trim()) {
          message.replaceChildren(
            feedbackMessage(
              "warning",
              "質問が未入力です",
              "聞きたい点を短く入力してください。",
            ),
          );
          return;
        }
        const text = question.control.value.trim();
        if (
          history.questions.some(
            (q) =>
              q.bookId === book.bookId &&
              q.version === book.version &&
              q.blockId === blockId &&
              q.termId === (term.value || null) &&
              q.text === text,
          )
        ) {
          message.replaceChildren(
            feedbackMessage(
              "warning",
              "同じ質問は保存済みです",
              "既存の質問を下で確認してください。",
            ),
          );
          return;
        }
        history.questions.push({
          ...stamp(),
          questionId: crypto.randomUUID(),
          termId: (term.value || null) as TermId | null,
          text,
          context:
            block.title +
            "\n" +
            (block.kind === "reading"
              ? block.markdown
              : block.kind === "question"
                ? block.prompt
                : block.title),
        });
        store.save();
        draw();
      }),
      message,
    );
    const questions = history.questions.filter(
      (q) => q.bookId === book.bookId && q.blockId === blockId,
    );
    for (const q of questions) {
      const item = el("details", undefined, "saved-question");
      item.append(el("summary", q.text));
      item.append(
        el(
          "p",
          `質問元：${q.blockId} / v${q.version} / ${q.termId ? termExplanation(q.termId, q.blockId).label : "節全体"}`,
        ),
        el("p", q.context, "muted"),
      );
      const unresolved = unresolvedQuestions(
        history.questions,
        history.questionEvents,
        book.bookId,
      ).some((x) => x.questionId === q.questionId);
      item.append(
        button(
          unresolved ? "疑問を解決済みにする" : "疑問を未解決に戻す",
          () => {
            history.questionEvents.push({
              ...stamp(),
              eventId: crypto.randomUUID(),
              questionId: q.questionId,
              action: unresolved ? "resolved" : "open",
            });
            store.save();
            draw();
          },
        ),
      );
      const manual = el("details");
      manual.append(el("summary", "根拠を確認して手動の追加案を作る"));
      const gap = field("不足している説明・図・確認点");
      const source = field("確認した公式出典URL", false);
      const checked = field("出典を確認した日（YYYY-MM-DD）", false);
      const evidence = field("出典のどの箇所が何を裏付けるか");
      const title = field("追加する見出し", false);
      const content = field("追加する説明・問題文（1000文字まで）");
      const kindLabel = el("label", "追加案の種類");
      const kind = el("select");
      kind.setAttribute("aria-label", "追加案の種類");
      for (const [v, t] of [
        ["reading", "説明"],
        ["issuance-sequence", "固定の発行前図つき説明"],
        ["lookup-flow", "固定の探索図つき説明"],
        ["question", "既存 CAA 意味論の確認問題"],
      ]) {
        const o = el("option", t);
        o.value = v;
        kind.append(o);
      }
      kindLabel.append(kind);
      const scenarioLabel = el("label", "問題に使う固定設定（問題の場合のみ）");
      const scenario = el("select");
      for (const s of scenarios) {
        const o = el("option", s.label);
        o.value = s.id;
        scenario.append(o);
      }
      scenarioLabel.append(scenario);
      const status = el("div");
      status.setAttribute("role", "status");
      manual.append(
        el(
          "p",
          "手動入力です。根拠の内容や新しさを自動で確認したとは扱いません。出典未確認・確認から30日超は反映を保留します。",
        ),
        gap.label,
        source.label,
        checked.label,
        evidence.label,
        kindLabel,
        title.label,
        content.label,
        scenarioLabel,
        button("手動追加案を保存して差分確認", () => {
          const id = crypto.randomUUID();
          const blockIdNew = "local-" + id.replace(/\d/g, "a");
          const candidate = {
            ...stamp(),
            proposalId: id,
            questionId: q.questionId,
            originVersion: q.version,
            mode: "manual",
            gap: gap.control.value,
            sourceUrl: source.control.value,
            checkedOn: checked.control.value,
            evidence: evidence.control.value,
            block:
              kind.value === "question"
                ? {
                    id: blockIdNew,
                    kind: "question",
                    title: title.control.value,
                    prompt: content.control.value,
                    scenario: scenario.value,
                  }
                : {
                    id: blockIdNew,
                    kind: "reading",
                    title: title.control.value,
                    markdown: content.control.value,
                    ...(kind.value === "reading" ? {} : { visual: kind.value }),
                  },
          };
          const parsed = proposalSchema.safeParse(candidate);
          if (
            !parsed.success ||
            !title.control.value.trim() ||
            !content.control.value.trim()
          ) {
            status.replaceChildren(
              feedbackMessage(
                "warning",
                "追加案は未保存です",
                "不足点・見出し・本文・出典URL・確認日・根拠を入力してください。",
              ),
            );
            return;
          }
          if (
            history.proposals.some(
              (p) =>
                p.version === book.version &&
                p.questionId === q.questionId &&
                JSON.stringify(p.block).replace(p.block.id, "") ===
                  JSON.stringify(parsed.data.block).replace(
                    parsed.data.block.id,
                    "",
                  ),
            )
          ) {
            status.replaceChildren(
              feedbackMessage(
                "warning",
                "同じ追加案は保存済みです",
                "既存提案の差分を確認してください。",
              ),
            );
            return;
          }
          history.proposals.push(parsed.data);
          store.save();
          draw();
          root.open = true;
          root
            .querySelector<HTMLDetailsElement>(`[data-proposal-id="${id}"]`)
            ?.setAttribute("open", "");
        }),
        status,
      );
      item.append(manual);
      body.append(item);
    }
    for (const p of history.proposals.filter(
      (p) => p.bookId === book.bookId && p.blockId === blockId,
    )) {
      const preview = el("details", undefined, "proposal-preview");
      preview.dataset.proposalId = p.proposalId;
      preview.append(el("summary", `差分：${p.block.title}（手動提案）`));
      preview.append(
        el("p", `不足点：${p.gap}`),
        el("p", `質問元 v${p.originVersion} → 対象版 v${p.version}`),
        el("h3", "反映前"),
        el(
          "p",
          `「${book.blocks.find((b) => b.id === blockId)?.title ?? blockId}」の後に、このブロックはありません。`,
        ),
        el("h3", "反映後：追加するブロック"),
        el("h4", p.block.title),
      );
      if (p.block.kind === "reading") {
        preview.append(markdown(p.block.markdown));
        if (p.block.visual)
          preview.append(
            el(
              "p",
              `使用する許可済み図：${p.block.visual}。図の計算は既存の固定 CAA 意味論です。`,
            ),
          );
      }
      if (p.block.kind === "question")
        preview.append(
          el("p", p.block.prompt),
          el("p", `固定 scenario：${p.block.scenario}`),
        );
      const a = el("a", "根拠の公式資料を開く");
      if (officialSourceUrl(p.sourceUrl)) {
        a.href = p.sourceUrl;
        a.target = "_blank";
        a.rel = "noreferrer";
      } else a.textContent = "出典URLは未確認のため開けません";
      preview.append(
        a,
        el("p", `確認日：${p.checkedOn} / 根拠：${p.evidence}`),
      );
      const problem = proposalProblem(p, book, history.proposalEvents);
      const feedback = el("div");
      feedback.setAttribute("role", "status");
      if (problem)
        feedback.append(feedbackMessage("warning", "反映は保留", problem));
      const confirm = el(
        "label",
        "差分と公式根拠を読み、この追加だけを反映する",
      );
      const checkbox = el("input");
      checkbox.type = "checkbox";
      confirm.prepend(checkbox);
      const apply = button("この差分を本人選択で反映", async () => {
        if (!checkbox.checked || apply.disabled) return;
        apply.disabled = true;
        checkbox.disabled = true;
        cancel.disabled = true;
        const error = await accept(p);
        if (error) {
          feedback.replaceChildren(
            feedbackMessage("error", "反映できませんでした", error),
          );
          checkbox.disabled = false;
          apply.disabled = false;
          cancel.disabled = false;
          return;
        }
      });
      apply.disabled = true;
      checkbox.addEventListener("change", () => {
        apply.disabled = !!problem || !checkbox.checked;
      });
      const cancel = button("提案を取り消す", () => {
        if (history.proposalEvents.some((e) => e.proposalId === p.proposalId))
          return;
        history.proposalEvents.push({
          ...stamp(),
          eventId: crypto.randomUUID(),
          proposalId: p.proposalId,
          action: "cancel",
        });
        store.save();
        draw();
      });
      cancel.disabled = history.proposalEvents.some(
        (e) => e.proposalId === p.proposalId,
      );
      preview.append(confirm, apply, cancel, feedback);
      body.append(preview);
    }
  }
  draw();
  root.append(button("質問・提案一覧を読み直す（未保存の入力は破棄）", draw));
  return root;
}
