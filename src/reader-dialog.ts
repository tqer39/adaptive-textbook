import { button, el } from "./ui";
type Entry = { dialog: HTMLDialogElement; trigger: HTMLElement; y: number };
const entries = new Map<string, Entry>();
let active: string | null = null;
function closeActive() {
  if (!active) return;
  const entry = entries.get(active)!;
  entry.dialog.close();
  (entry.trigger.isConnected
    ? entry.trigger
    : document.querySelector<HTMLElement>("main h2")
  )?.focus({ preventScroll: true });
  window.scrollTo(0, entry.y);
  active = null;
}
function sync() {
  const key = window.history.state?.readerOverlay as string | undefined;
  if (key === active) return;
  closeActive();
  if (key && entries.has(key)) {
    active = key;
    entries.get(key)!.dialog.showModal();
  }
}
window.addEventListener("popstate", sync);
export function openReaderDialog(
  key: string,
  title: string,
  content: HTMLElement,
  trigger: HTMLElement,
) {
  const old = entries.get(key);
  old?.dialog.remove();
  const dialog = el("dialog", undefined, "reader-dialog");
  const heading = el("h2", title);
  heading.id = `reader-dialog-${key}`;
  dialog.setAttribute("aria-labelledby", heading.id);
  let closing = false;
  const requestClose = () => {
    if (closing || !dialog.open) return;
    closing = true;
    window.history.back();
  };
  dialog.addEventListener("close", () => {
    closing = false;
  });
  const close = button("閉じて読書へ戻る", requestClose);
  dialog.addEventListener("cancel", (e) => {
    e.preventDefault();
    requestClose();
  });
  dialog.append(heading, close, content);
  document.body.append(dialog);
  entries.set(key, { dialog, trigger, y: window.scrollY });
  window.history.pushState({ readerOverlay: key }, "", window.location.href);
  sync();
}
