// Editorial estimates; actual reading and practice time varies by reader.
export const blockMinutes = [2, 3, 2, 3, 2, 3, 1, 1, 1, 4, 1, 3, 3];
export function learningPlan(
  start: number,
  minutes: number,
  estimates: readonly number[] = blockMinutes,
) {
  let end = Math.max(0, Math.min(start, estimates.length - 1));
  let estimate = estimates[end];
  while (end + 1 < estimates.length && estimate + estimates[end + 1] <= minutes)
    estimate += estimates[++end];
  return { start, end, estimate };
}
