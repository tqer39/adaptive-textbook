export function installNavigationShortcuts(
  enabled: () => boolean,
  move: (direction: -1 | 1) => boolean,
) {
  document.addEventListener("keydown", (event) => {
    if (
      !enabled() ||
      event.defaultPrevented ||
      event.repeat ||
      event.isComposing ||
      event.ctrlKey ||
      event.metaKey ||
      event.altKey ||
      document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]')
    )
      return;
    const target = event.target;
    if (
      target instanceof Element &&
      target.closest(
        'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="combobox"]',
      )
    )
      return;
    const key = event.key.toLowerCase();
    if (key === "n" || key === "p") {
      if (move(key === "n" ? 1 : -1)) event.preventDefault();
    }
  });
}
