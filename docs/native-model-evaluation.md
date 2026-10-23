# Fixed native model evaluation

[English](native-model-evaluation.md) | [日本語](native-model-evaluation.ja.md)

This is the first product-source case for [Issue #6](https://github.com/tqer39/adaptive-textbook/issues/6).
It supplements the small [live connection smoke test](codex-live-validation.md).
The issue remains open: one known regression does not establish representative model quality or context efficiency.

## Case and fixed oracle

The [case inputs](../harness/evaluations/native-unsubscribe/protocol.json) pin source commit
`fe1ce0d4e1034643606eaad4b725421ee045aab4` and a hashed seed patch.
The patch removes the local article/search snapshot reconciliation from `FeedReaderModel.remove(_:)`.
After another connection removes a subscription, a later removal receipt may contain no newly deleted article IDs.
If reload then fails, stale unretained articles and selection must disappear while retained bookmarks and translations remain available.

The acceptance criteria, all existing Swift tests and Core receipt behavior are fixed.
Only `apple/Sources/TextbookUI/FeedReaderModel.swift` is editable during repair; detection reviews are read-only.
The oracle is the existing full Swift suite, including empty-receipt and retained-bookmark removal regressions.
The original recovery run demonstrated eight failed assertions across those two tests before repair, then all 107 tests and the native bundle regression passed.
No test assertions were changed. This does not validate native UI, physical devices or signing.

## Observations on 2026-10-23

All four model turns used `gpt-5.6-sol`, OpenAI, Standard (`default`), with separate executions for repair and review.
The recorded Pro-only checks reported `prolite`, 70% shared weekly usage before the baseline/repair/review turns and 71% before the focused turn, with no additional credits.
These shared percentages are not usage attributable to this experiment.
The existing [allowance and stop policy](codex-live-validation.md#subscription-and-stop-conditions) remained in force.

| Trial | Outcome | Elapsed | Cumulative input | Cached input, included in input | Output |
| --- | --- | --- | --- | --- | --- |
| Baseline source review | Detected the seeded defect; `revise` | 62.830 s | 320,381 | 265,984 | 3,509 |
| Focused source review | Detected the same defect; `revise` | 57.120 s | 245,820 | 200,064 | 3,564 |
| Recovery and separate review | Fixed tests restored; `approve` | 166.759 s | 621,629 | 522,624 | 7,338 |

Both detection trials had the identical source hash:
`0f704e6940693dd2045d2ab28eb810f7fb7070085a381e25a0ea8cc0b973be74`.
The focused task adds symbol searches and narrow source slices before wider reads; acceptance, model, checks and budgets remain unchanged.
Both trials found the one seeded defect. Other missed defects were not measured.
The focused variant was selected after observing baseline retrieval, with one attempt per variant.
Its recorded input was about 23% lower; output was slightly higher.
This exploratory pair does not establish causality, general savings, a monetary bill or a model ranking.
Both reviewers still read overlapping source ranges.

Token counters cover 4/4 distinct turns. Cached input is a subset, not an additional chargeable token count to add to input.
Repeated checks were zero under the harness definition: the same check index at the same source hash.
The necessary checks after repair run at a different hash and are not classified as repeated checks.
The recovery used one repair cycle, seven operations and one failed check operation.
Its 166.759 seconds include preflight, the failing suite, repair, successful checks and review.
The final suite benefited from a warm build cache; its shorter duration is not evidence of prompt efficiency.

### Recovery limitation found in transcript audit

The original worktrees retained the correct implementation in Git `HEAD`.
The repair role ran `git diff`, which exposed that solution, and ultimately restored it exactly.
The final source hash was `4d49c34bd33d79510f6cf0dc8d14360139ab8e5896a4f5c3b817fa1d40ebaaf1`.
The record proves fixed-test restoration and harness recovery mechanics, **not blind independent repair**.
The two detection transcripts did not inspect Git history/diffs, other checkouts, or execute tests.
The separate recovery reviewer read supplied hash-linked check logs; no additional model tests were dispatched.
Retain this limitation rather than silently replacing the result with a more favorable rerun.

Run IDs, task/source/log hashes, exact counters, operation metadata and limitations are in the
[public result record](../harness/evaluations/native-unsubscribe/results-2026-10-23.json).
Raw logs and SQLite ledgers remain private. Their hashes and this report alone do not independently authenticate unavailable raw logs.
The baseline snapshot predates recovery changing its workspace; it is historical evidence, not current acceptance of the faulty source.
Detection runs finish with `repair-budget-exhausted` because repairs are disabled; that status records the requested defect finding, not a model crash.

## Reproduction with a solution-free Git baseline

[The preparation command](../scripts/prepare-native-evaluation.py) exports the pinned source, verifies and applies the seed,
then makes a new repository whose only commit contains the faulty candidate.
It does not clone the correct commit or configure a remote.
It parameterizes the checked-in task templates and invokes the existing `freeze-task` or `prepare-product` CLI.
It never starts a model, runs product checks, reads authentication values or overwrites an existing output directory.
This is preparation for the existing harness, not a second runner.

Requirements: Python 3.9+, Git, the pinned source commit available locally, and the built Go harness.
Actual recovery checks additionally require the [Apple toolchain](../apple/README.md).
Choose a currently authorized model and authentication route before any later model dispatch.
Keep output private and outside the source checkout; use a fresh output directory for each trial.

```bash
mkdir -p .local-state
mise exec -- go build -C harness -o "$PWD/.local-state/textbook-harness" ./cmd/harness
python3 scripts/prepare-native-evaluation.py \
  --variant focused \
  --output /absolute/path/new-evaluation \
  --harness-binary "$PWD/.local-state/textbook-harness" \
  --codex-binary /absolute/path/native-codex \
  --codex-home /absolute/path/configured-codex-home \
  --model AUTHORIZED_MODEL_ID
```

Variants are `detection`, `focused` and `recovery`.
Recovery uses the maintained `apple-tests` profile, including preflight, and the unchanged acceptance criteria.
Task hashes vary with absolute paths, model selection and protocol; do not expect them to match the historical private tasks.
Inspect `manifest.json`, `task.json` and the fixture before explicitly running the existing CLI:

```bash
.local-state/textbook-harness run \
  -task /absolute/path/new-evaluation/task.json \
  -state /absolute/path/new-evaluation/state -allow-codex
.local-state/textbook-harness summary \
  -state /absolute/path/new-evaluation/state -run RUN_ID
```

The model invocation consumes included allowance. Do not rerun unknown or failed outcomes automatically;
follow [stop and recovery rules](../harness/README.md#stop-resume-and-evidence).
Preserve every trial and verify source identity, fixed controls, logs, token coverage and the oracle independently of the model verdict.
Audit actual reads: Git isolation does not sandbox filesystem access to other checkouts.

The revised `snapshot-only-v2` preparation was tested without model calls on 2026-10-23:
it reproduced the exact faulty source hash above, had one faulty commit, and could not resolve the correct base commit.
Four preparation regressions exercise all three variants, immutable controls, existing-output preservation and seed/control tampering refusal.
They run through the real CLI under `mise run harness:check`, locally and in the existing Linux/macOS CI jobs.
No live model outcome under the revised protocol has been measured yet.
Remaining work includes uncontaminated recovery evidence and additional fixed product cases before assessing representative effectiveness.
