// Closed model: normal DNS replies, non-wildcard names, no aliases/parameters,
// flags 0, and fixed valid issue/iodef values. Not a general DNS resolver.
export type Scenario = "absent" | "report" | "deny" | "allow";
export type Record = { flags: 0; tag: "issue" | "iodef"; value: string };
export type DnsTree = { readonly [name: string]: readonly Record[] };
export const denyRecords: Record[] = [{ flags: 0, tag: "issue", value: ";" }];
export const allowRecords: Record[] = [
  { flags: 0, tag: "issue", value: "letsencrypt.org" },
];
export const reportRecords: Record[] = [
  { flags: 0, tag: "iodef", value: "mailto:security@example.com" },
];
export const scenarios: { id: Scenario; label: string; records: Record[] }[] = [
  { id: "absent", label: "子に CAA なし", records: [] },
  { id: "report", label: "子に iodef だけ", records: reportRecords },
  { id: "deny", label: "子にも発行禁止", records: denyRecords },
  { id: "allow", label: "子で Let’s Encrypt を許可", records: allowRecords },
];
export function evaluateName(
  tree: DnsTree,
  target: string,
  issuer = "letsencrypt.org",
) {
  const trace: string[] = [];
  const lookups: { name: string; hasRecords: boolean }[] = [];
  let name = target;
  let selected: readonly Record[] = [];
  let owner: string | null = null;
  while (name) {
    const rrset = tree[name] ?? [];
    lookups.push({ name, hasRecords: rrset.length > 0 });
    if (rrset.length) {
      selected = rrset;
      owner = name;
      trace.push(`${name}: CAA RRset あり → 採用して探索終了`);
      break;
    }
    trace.push(`${name}: CAA RRset なし → 親へ`);
    name = name.includes(".") ? name.slice(name.indexOf(".") + 1) : "";
  }
  if (!owner) trace.push("DNS root の手前まで CAA なし → 制限する RRset なし");
  const issues = selected.filter((r) => r.tag === "issue");
  const allowed = issues.length === 0 || issues.some((r) => r.value === issuer);
  const reason = !selected.length
    ? "対象から親へ探索しても CAA RRset がなく、CAA による発行制限はない。"
    : issues.length === 0
      ? "採用した RRset に issue がなく、iodef は報告先なので発行を制限しない。"
      : allowed
        ? `採用した RRset の issue が ${issuer} を許可する。`
        : issues.every((r) => r.value === ";")
          ? '採用した RRset は issue ";" のみ。許可する CA がなく、発行は禁止。'
          : `採用した RRset の issue は ${issuer} を許可していない。この CA は CAA 上、禁止。`;
  return { allowed, selected, owner, trace, reason, lookups };
}
export type Independent = "none" | "report" | "allow";
export type ChildPolicy = "deny" | "allow";
export function childOnlyTree(
  independent: Independent = "allow",
  policy: ChildPolicy = "deny",
): DnsTree {
  return {
    "example.com": [],
    "api.example.com": policy === "deny" ? denyRecords : allowRecords,
    "v1.api.example.com": [],
    "www.example.com": [],
    "special.api.example.com":
      independent === "none"
        ? []
        : independent === "report"
          ? reportRecords
          : allowRecords,
  };
}
export const scopeTargets = [
  { id: "parent", name: "example.com", label: "親自身" },
  { id: "child", name: "api.example.com", label: "子自身" },
  {
    id: "descendant",
    name: "v1.api.example.com",
    label: "子孫 / 独自 CAA なし",
  },
  { id: "sibling", name: "www.example.com", label: "兄弟" },
  {
    id: "independent",
    name: "special.api.example.com",
    label: "子孫 / 独自 RRset",
  },
] as const;
export const questionScenarios = [
  "absent",
  "report",
  "deny",
  "allow",
  "child-parent",
  "child-self",
  "child-descendant",
  "child-sibling",
  "child-independent",
  "limited-expected",
  "limited-other",
] as const;
export type QuestionScenario = (typeof questionScenarios)[number];
export function evaluate(scenario: QuestionScenario) {
  if (scenario.startsWith("child-")) {
    const id = scenario === "child-self" ? "child" : scenario.slice(6);
    const target = scopeTargets.find((t) => t.id === id)!;
    return evaluateName(childOnlyTree(), target.name);
  }
  if (scenario === "limited-expected" || scenario === "limited-other")
    return evaluateName(
      { "example.com": allowRecords },
      "example.com",
      scenario === "limited-expected" ? "letsencrypt.org" : "other-ca.example",
    );
  const child = scenarios.find((s) => s.id === scenario)!.records;
  const result = evaluateName(
    { "example.com": denyRecords, "api.example.com": child },
    "api.example.com",
  );
  if (child.length)
    result.trace.push("example.com: 探索しない（親の禁止とは合算しない）");
  return result;
}
export function grade(scenario: QuestionScenario, answer: "allow" | "deny") {
  return evaluate(scenario).allowed === (answer === "allow");
}
export function formatRecord(r: Record) {
  return `CAA ${r.flags} ${r.tag} "${r.value}"`;
}

export type LookupStage = {
  kind: "candidate" | "query" | "selected" | "decision";
  title: string;
  detail: string;
};
export function lookupStages(scenario: Scenario): LookupStage[] {
  const result = evaluate(scenario);
  const steps: LookupStage[] = [];
  for (const lookup of result.lookups) {
    steps.push({
      kind: "candidate",
      title: `候補: ${lookup.name}`,
      detail: steps.length
        ? "直前の名前に CAA がなかったので、左端のラベルを除いた親名を次の候補にする。"
        : "申請する対象名を、最初の照会候補にする。",
    });
    steps.push({
      kind: "query",
      title: `照会: ${lookup.name} の CAA`,
      detail: lookup.hasRecords
        ? "CAA レコードの集合が見つかった。親への探索はここで止める。"
        : "CAA レコードの集合がない。親名を候補にして照会を続ける。",
    });
  }
  steps.push({
    kind: "selected",
    title: `採用する集合を確定: ${result.owner ?? "なし"}`,
    detail: result.selected.length
      ? result.selected.map(formatRecord).join("\n")
      : "root の手前まで見つからなければ、採用する CAA RRset は空。",
  });
  steps.push({
    kind: "decision",
    title: result.allowed ? "○ CAA ポリシー上の許可" : "× CAA ポリシー上の禁止",
    detail: result.reason,
  });
  return steps;
}
