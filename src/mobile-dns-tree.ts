import { el } from "./ui";
export function mobileDnsTree(
  nodes: { name: string; detail: string; parent?: string }[],
) {
  const figure = el("figure", undefined, "mobile-dns-tree");
  figure.append(el("figcaption", "DNS の親子関係（下へ進むと子・子孫）"));
  function children(parent?: string): HTMLUListElement {
    const list = el("ul");
    for (const node of nodes.filter((n) => n.parent === parent)) {
      const item = el("li");
      const card = el("div", undefined, "dns-node");
      card.append(el("strong", node.name), el("p", node.detail));
      item.append(card);
      if (nodes.some((n) => n.parent === node.name))
        item.append(children(node.name));
      list.append(item);
    }
    return list;
  }
  figure.append(children());
  return figure;
}
