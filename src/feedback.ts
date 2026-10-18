import { el } from "./ui";
export type FeedbackTone = "success" | "error" | "warning" | "neutral";
const icons: Record<FeedbackTone, string> = {
  success: "✓",
  error: "×",
  warning: "!",
  neutral: "i",
};
export function feedbackMessage(
  tone: FeedbackTone,
  label: string,
  reason: string,
  heading = false,
) {
  const root = el("div", undefined, "semantic-feedback");
  root.dataset.tone = tone;
  const title = el("div", undefined, "feedback-title");
  const icon = el("span", icons[tone], "feedback-icon");
  icon.setAttribute("aria-hidden", "true");
  title.append(icon, el(heading ? "h3" : "strong", label));
  root.append(title, el("p", reason));
  return root;
}
export function policyFeedback(allowed: boolean, reason: string) {
  const node = feedbackMessage(
    "neutral",
    allowed ? "○ CAA ポリシー上の許可" : "× CAA ポリシー上の禁止",
    reason,
    true,
  );
  node.dataset.policy = allowed ? "allow" : "deny";
  return node;
}
