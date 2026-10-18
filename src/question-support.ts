import { evaluate, type QuestionScenario } from "./caa";
const misconceptions: Record<
  QuestionScenario,
  { id: string; text: string; focus: string }
> = {
  report: {
    id: "merge-parent",
    text: "この選択では、親の禁止を子の集合に足すのかを確認しましょう。子の iodef で集合が見つかり、親へ進みません。",
    focus: "子 api.example.com の iodef と探索停止",
  },
  absent: {
    id: "stop-empty",
    text: "この選択では、CAA がない名前で探索を終えるのかを確認しましょう。空なら親の集合を探します。",
    focus: "子から親への探索",
  },
  deny: {
    id: "ignore-issue",
    text: 'この選択では、issue ";" のみの集合が許可する CA を確認しましょう。許可する CA はありません。',
    focus: "子の発行禁止",
  },
  allow: {
    id: "merge-parent",
    text: "この選択では、子の許可と親の禁止を合算するのかを確認しましょう。子の集合だけで判断します。",
    focus: "子の CA 許可",
  },
  "child-parent": {
    id: "upward",
    text: "この選択では、子の禁止が親へ伝わるのかを確認しましょう。親を調べるときは子を探しません。",
    focus: "親自身 example.com",
  },
  "child-self": {
    id: "ignore-issue",
    text: 'この選択では、対象自身の issue ";" の意味を確認しましょう。この集合は CA を許可しません。',
    focus: "子自身 api.example.com",
  },
  "child-descendant": {
    id: "descendants",
    text: "この選択では、子孫が自分の CAA だけで判断されるのかを確認しましょう。v1.api に集合がないため、親 api の禁止を採用します。",
    focus: "v1.api → api の探索",
  },
  "child-sibling": {
    id: "sideways",
    text: "この選択では、禁止が兄弟へ伝わるのかを確認しましょう。www の探索経路に api は入りません。",
    focus: "兄弟 www → example.com の探索",
  },
  "child-independent": {
    id: "merge-parent",
    text: "この選択では、親子の集合を合算するのかを確認しましょう。special.api の独自集合で止まり、api の禁止は足しません。",
    focus: "special.api の独自 RRset",
  },
  "limited-expected": {
    id: "all-ca-ban",
    text: "この選択では、全面禁止と特定 CA の許可を区別しましょう。採用した issue は Let’s Encrypt を許可します。",
    focus: "issue の CA 指定",
  },
  "limited-other": {
    id: "any-ca",
    text: "この選択では、一つの CA の許可が別 CA にも使えるのかを確認しましょう。letsencrypt.org の許可は other-ca.example の許可ではありません。",
    focus: "指定した CA と比較する CA",
  },
};
export function questionSupport(
  scenario: QuestionScenario,
  answer: "allow" | "deny",
) {
  const result = evaluate(scenario);
  const correct = (answer === "allow") === result.allowed;
  const support = misconceptions[scenario];
  return {
    ...support,
    correct,
    text: correct ? `理由を確認：${result.reason}` : support.text,
    result,
  };
}
