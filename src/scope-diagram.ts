import { policyFeedback } from "./feedback";
import {
  childOnlyTree,
  evaluateName,
  formatRecord,
  scopeTargets,
  type Independent,
  type ChildPolicy,
} from "./caa";
import { mobileDnsTree } from "./mobile-dns-tree";
import { el, button } from "./ui";
export function scopeDiagram() {
  const root = el("div");
  const policyLabel = el("label", "子 api の方針");
  const policy = el("select");
  policy.id = "child-policy";
  policyLabel.htmlFor = policy.id;
  for (const [value, text] of [
    ["deny", 'issue ";" のみ / 全 CA 禁止'],
    ["allow", 'issue "letsencrypt.org" / CA 限定'],
  ]) {
    const o = el("option", text);
    o.value = value;
    policy.append(o);
  }
  const ownLabel = el("label", "special.api の独自 RRset");
  const own = el("select");
  own.id = "independent";
  ownLabel.htmlFor = own.id;
  for (const [value, text] of [
    ["allow", 'issue "letsencrypt.org"'],
    ["none", "CAA なし"],
    ["report", "iodef だけ"],
  ]) {
    const o = el("option", text);
    o.value = value;
    own.append(o);
  }
  const issuerLabel = el("label", "比較する CA");
  const issuer = el("select");
  issuer.id = "issuer";
  issuerLabel.htmlFor = issuer.id;
  for (const [value, text] of [
    ["letsencrypt.org", "Let’s Encrypt"],
    ["other-ca.example", "別 CA（架空）"],
  ]) {
    const o = el("option", text);
    o.value = value;
    issuer.append(o);
  }
  const output = el("div");
  output.setAttribute("aria-live", "polite");
  function draw() {
    const tree = childOnlyTree(
      own.value as Independent,
      policy.value as ChildPolicy,
    );
    output.replaceChildren();
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 680 350");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-labelledby", "scope-title scope-desc");
    const title = document.createElementNS(ns, "title");
    title.id = "scope-title";
    title.textContent = "子だけに CAA を置いた DNS 木";
    const desc = document.createElementNS(ns, "desc");
    desc.id = "scope-desc";
    desc.textContent =
      "example.com の子は api と www。api の子は v1 と special。対象から親への経路だけを探索し、兄弟や下の名前は探索しない。";
    svg.append(title, desc);
    for (const d of [
      "M340 82 V110 H198 V136",
      "M340 110 H536 V136",
      "M198 202 V227 H148 V258",
      "M198 227 H436 V258",
    ]) {
      const path = document.createElementNS(ns, "path");
      path.setAttribute("d", d);
      path.setAttribute("stroke", "#526b70");
      path.setAttribute("fill", "none");
      path.setAttribute("stroke-width", "2");
      svg.append(path);
    }
    const positions = [
      [340, 48],
      [198, 169],
      [148, 291],
      [536, 169],
      [436, 291],
    ];
    scopeTargets.forEach((target, i) => {
      const [x, y] = positions[i];
      const r = evaluateName(tree, target.name, issuer.value);
      const rect = document.createElementNS(ns, "rect");
      for (const [k, v] of Object.entries({
        x: String(x - 128),
        y: String(y - 33),
        width: "256",
        height: "66",
        rx: "10",
        fill: r.allowed ? "#edf2ea" : "#f4e9df",
        stroke: "#526b70",
      }))
        rect.setAttribute(k, v);
      svg.append(rect);
      for (const [offset, text] of [
        [-6, target.name],
        [18, r.allowed ? "○ CAA 上、許可" : "× CAA 上、禁止"],
      ] as const) {
        const t = document.createElementNS(ns, "text");
        t.setAttribute("x", String(x));
        t.setAttribute("y", String(y + offset));
        t.setAttribute("text-anchor", "middle");
        t.textContent = text;
        svg.append(t);
      }
    });
    svg.classList.add("desktop-dns-tree");
    output.append(
      svg,
      mobileDnsTree(
        scopeTargets.map((target) => ({
          name: target.name,
          parent:
            target.id === "parent"
              ? undefined
              : target.id === "child" || target.id === "sibling"
                ? "example.com"
                : "api.example.com",
          detail: evaluateName(tree, target.name, issuer.value).allowed
            ? "○ CAA 上、許可"
            : "× CAA 上、禁止",
        })),
      ),
      el(
        "p",
        "親 example.com とその上位にも CAA なし、という模擬 DNS 木です。結果は各名前を単独で評価したものです。",
        "muted",
      ),
    );
    const list = el("div", undefined, "scope-results");
    for (const target of scopeTargets) {
      const r = evaluateName(tree, target.name, issuer.value);
      const item = el("div", undefined, "scope-result");
      item.dataset.target = target.id;
      item.append(
        el("strong", `${target.label}: ${target.name}`),
        policyFeedback(r.allowed, r.reason),
        el("p", `採用 RRset: ${r.owner ?? "なし"}`, "muted"),
      );
      const records = tree[target.name];
      item.append(
        el(
          "code",
          records.length
            ? records.map(formatRecord).join("\n")
            : "この名前の CAA: なし",
        ),
      );
      const details = el("details");
      details.append(el("summary", "この名前の探索を追う"));
      const trace = el("ol", undefined, "trace");
      for (const step of r.trace) trace.append(el("li", step));
      details.append(trace, el("p", r.reason));
      item.append(details);
      list.append(item);
    }
    output.append(list);
  }
  for (const select of [policy, own, issuer])
    select.addEventListener("change", draw);
  const next = button("独自 RRset の次の設定を試す →", () => {
    own.selectedIndex = (own.selectedIndex + 1) % 3;
    draw();
  });
  next.className = "scenario-next";
  root.append(
    policyLabel,
    policy,
    ownLabel,
    own,
    issuerLabel,
    issuer,
    next,
    output,
  );
  draw();
  return root;
}
