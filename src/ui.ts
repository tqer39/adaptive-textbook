export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  text?: string,
  className?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  if (className) node.className = className;
  return node;
}
export function button(
  text: string,
  action: () => void,
  className = "",
): HTMLButtonElement {
  const b = el("button", text, className);
  b.type = "button";
  b.addEventListener("click", action);
  return b;
}
// Restricted Markdown: paragraphs, bold and inline code only. HTML stays text.
export function markdown(text: string) {
  const root = el("div", undefined, "prose");
  for (const para of text.split("\n\n")) {
    const p = el("p");
    for (const token of para.split(/(\*\*[^*]+\*\*|`[^`]+`)/g)) {
      p.append(
        token.startsWith("**")
          ? el("strong", token.slice(2, -2))
          : token.startsWith("`")
            ? el("code", token.slice(1, -1))
            : document.createTextNode(token),
      );
    }
    root.append(p);
  }
  return root;
}
