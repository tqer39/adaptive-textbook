# Fixed history initialization evaluation

[English](history-model-evaluation.md) | [日本語](history-model-evaluation.ja.md)

This second product-source case for [Issue #6](https://github.com/tqer39/adaptive-textbook/issues/6)
complements the [native unsubscribe evaluation](native-model-evaluation.md).
It exercises persistent answer history and concurrent SQLite initialization rather than UI cache reconciliation.
The two cases cover those specific failure classes; they do not establish general model quality or generated-textbook correctness.

## Fixed case and protocol

The [protocol](../harness/evaluations/history-initialization/protocol.json) pins commit
`fe1ce0d4e1034643606eaad4b725421ee045aab4` and replaces the schema-version reread after `BEGIN IMMEDIATE`
with the previously read, potentially stale `version` value.
The seeded source hash is `99950366e5badd11b860e5c5875454ab24cc431515a9484fc8a5639b016badb1`.
This is a deliberate evaluation mutation, not a new defect reported against the unchanged production source.

Acceptance fixes concurrent successful first opens, exact future-version refusal, unknown-schema refusal without mutation,
answer validation/version association and existing persistence semantics.
Only `HistoryStore.swift` may change during repair. All existing Swift tests and `Textbook.swift` are frozen.
The existing independent initialization tests use a causal gate before lock acquisition; no timing-only race or weakened assertion was introduced.

Before any model invocation for this case, the baseline source review, focused source review and recovery tasks were prepared and hashed.
Each runs once, serially, without automatic retry for a preferred outcome.
The focused variant changes retrieval guidance only: start with the initializer, transaction/version decisions and matching tests, then expand as needed.
All three fixtures use `snapshot-only-v2`: their sole Git commit contains the faulty candidate, with no correct base object or remote.
The task criteria and tests are the same across variants; the two detection tasks have identical source hashes.
The broad two-case coverage interpretation was documented after dispatch, not preregistered as a general model study.

## Results on 2026-10-23

| Trial | Outcome | Elapsed | Cumulative input | Cached subset | Input minus cached | Output |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline source review | Seeded defect detected; `revise` | 36.980 s | 113,165 | 81,664 | 31,501 | 1,623 |
| Focused source review | Same defect detected; `revise` | 33.692 s | 107,579 | 58,880 | 48,699 | 1,473 |
| Recovery plus separate review | Fixed checks restored; `approve` | 76.805 s | 284,196 | 207,232 | 76,964 | 2,647 |

Both detection reviews identified stale pre-lock schema-version reuse: a second opener can reject a valid concurrently initialized database as corrupted,
and a future version committed while waiting for the lock receives the wrong refusal.
Each detected the seeded defect; unrelated missed defects and false positives were not measured.
Both also described the source-level possibility of overwriting a future version without tables; this was not separately executed as an oracle test.
Detection runs end in `repair-budget-exhausted` because repair is disabled, not because inference failed.

Focused cumulative input was about 4.9% lower, but input minus cached input was about 54.6% higher.
Both values matter: this is not evidence of a general cost reduction, and counters are not a monetary bill.
The case is known, the criteria and tests are explicit, and there is only one attempt per variant.
No model ranking, statistical confidence or comparison with the different unsubscribe workload is implied.

All four turns used `gpt-5.6-sol`, OpenAI and Standard (`default`), with complete 4/4 token-counter coverage.
The Pro-only guard recorded shared weekly usage of 74% for baseline and 75% for the other turns, without additional credits.
Shared allowance changes are not attributed solely to these trials; cached input remains a subset of input.
The [existing allowance and stop policy](codex-live-validation.md#subscription-and-stop-conditions) remains authoritative.
Same-source repeated check operations were zero.

Recovery run `f22adfb27ee7c22078d0a76c` first ran all 107 Swift tests and demonstrated two failures:
the concurrent first-open and future-version refusal regressions.
One repair changed only the permitted initializer; all 107 tests and the bundle regression then passed, followed by a separate read-only approval.
The final result was `accepted`, `stale=false`, seven operations and one repair cycle at source hash
`4d49c34bd33d79510f6cf0dc8d14360139ab8e5896a4f5c3b817fa1d40ebaaf1`.
The implementation matches the original correct source, but transcript audit found no access to that source through Git history or another checkout.
The final review's diff was against the faulty initial commit. Criteria, tests and source outside the permitted file remained unchanged.
The 76.805 seconds include preflight, failing checks, repair, passing checks and review; warm build caches affect check durations.

The [public result record](../harness/evaluations/history-initialization/results-2026-10-23.json) retains every trial,
task/source/log hash, recorded counters and limitations, alongside the [repair patch](../harness/evaluations/history-initialization/repair.patch).
Complete ledgers, logs and frozen private tasks were archived locally. Public hashes alone do not authenticate unavailable private logs.
The models inspected allowed current source/tests, canonical skill/contract text and supplied check logs; no external retrieval or model-dispatched tests were observed.
No native UI or physical-device acceptance is inferred from these model and unit-test results.

## Reproduce

Use the existing [preparation and dispatch procedure](native-model-evaluation.md#reproduction-with-a-solution-free-git-baseline)
with `--case history-initialization` and one of `--variant detection`, `focused` or `recovery`.
The common command delegates to `freeze-task` / `prepare-product`; it does not execute models during preparation.
Retain separate output directories, every attempted outcome, the fixed tests and the existing allowance guard.
An unavailable prerequisite or unknown model outcome is not a reason to start a replacement run automatically.

Together with the unsubscribe case, this completes the recorded two-case measurement matrix for UI-state and persistence boundaries.
Review and integration of the pending harness PRs still remain; Issue #6 is not closed by this report.
Unseen tasks, negative controls and repeated trials for broader confidence are tracked in [Wishlist #29](https://github.com/tqer39/adaptive-textbook/issues/29).
