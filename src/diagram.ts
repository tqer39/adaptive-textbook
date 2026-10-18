import { policyFeedback } from "./feedback";
import { evaluate, formatRecord, scenarios, type Scenario } from "./caa";
import { mobileDnsTree } from "./mobile-dns-tree";
import { button, el } from "./ui";
export function diagram(initial: Scenario, onChange: (s: Scenario) => void) {
  const root = el("div");
  const label = el("label", "子の CAA を切り替える");
  const select = el("select");
  label.htmlFor = "scenario";
  select.id = "scenario";
  for (const s of scenarios) {
    const o = el("option", s.label);
    o.value = s.id;
    select.append(o);
  }
  select.value = initial;
  const panel = el("div");
  panel.setAttribute("aria-live", "polite");
  function draw() {
    const s = select.value as Scenario;
    const result = evaluate(s);
    panel.replaceChildren();
    // Fixed trusted SVG: no generated source, labels via textContent.
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 600 230");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-labelledby", "dns-title dns-desc");
    const title = document.createElementNS(ns, "title");
    title.id = "dns-title";
    title.textContent = "DNS 親子と CAA の探索";
    const desc = document.createElementNS(ns, "desc");
    desc.id = "dns-desc";
    desc.textContent = result.trace.join("。");
    svg.append(title, desc);
    for (const [y, name, caption] of [
      [15, "example.com", '親 / CAA 0 issue ";"'],
      [135, "api.example.com", scenarios.find((x) => x.id === s)!.label],
    ] as const) {
      const rect = document.createElementNS(ns, "rect");
      for (const [k, v] of Object.entries({
        x: "12",
        y: String(y),
        width: "576",
        height: "78",
        rx: "12",
        fill: "#f3f1e9",
        stroke: "#526b70",
      }))
        rect.setAttribute(k, v);
      svg.append(rect);
      for (const [offset, content] of [
        [29, name],
        [55, caption],
      ] as const) {
        const t = document.createElementNS(ns, "text");
        t.setAttribute("x", "32");
        t.setAttribute("y", String(y + offset));
        t.textContent = content;
        svg.append(t);
      }
    }
    const line = document.createElementNS(ns, "path");
    line.setAttribute("d", "M300 93 V135");
    line.setAttribute("stroke", "#526b70");
    line.setAttribute("stroke-width", "2");
    svg.append(line);
    svg.classList.add("desktop-dns-tree");
    panel.append(
      svg,
      mobileDnsTree([
        { name: "example.com", detail: '親 / CAA 0 issue ";"' },
        {
          name: "api.example.com",
          parent: "example.com",
          detail: scenarios.find((x) => x.id === s)!.label,
        },
      ]),
    );
    const records = el("div", undefined, "records");
    records.append(el("span", "子の RRset"));
    for (const r of scenarios.find((x) => x.id === s)!.records)
      records.append(el("code", formatRecord(r)));
    if (s === "absent") records.append(el("code", "空（CAA なし）"));
    panel.append(records);
    const trace = el("ol", undefined, "trace");
    for (const step of result.trace) trace.append(el("li", step));
    panel.append(
      trace,
      el("p", `採用: ${result.owner}`, "eyebrow"),
      policyFeedback(result.allowed, result.reason),
      el(
        "p",
        "発行成功を保証しません。外部 DNS への問い合わせや変更はありません。",
        "muted",
      ),
    );
  }
  select.addEventListener("change", () => {
    draw();
    onChange(select.value as Scenario);
  });
  const next = button("次の設定を試す →", () => {
    select.selectedIndex = (select.selectedIndex + 1) % scenarios.length;
    draw();
    onChange(select.value as Scenario);
  });
  next.className = "scenario-next";
  root.append(label, select, next, panel);
  draw();
  return root;
}
