# Minimal Native App and Development Harness

[English](native-harness.md) | [日本語](native-harness.ja.md)

The first implementation of the Swift / Go architecture, started on 2026-10-22.
The existing web prototype is retained, with the new components separated into `apple/` and `harness/`.
Live LLM requests for the textbook service, a synchronization server, new subscriptions, publication, and signing-key configuration are outside this phase.

## Acceptance criteria

- Provide shared macOS / iOS SwiftUI screens and Swift textbook / answer models.
- Allow reading a fixed Japanese textbook, answering comprehension questions, and reading explanations with supporting reasons.
- Save answers in SQLite and retrieve them after restart with their textbook version.
- Display save failures and never label an unsuccessful save as successful.
- Run frozen specifications, checks, independent review, and bounded repairs through a Go harness.
- Keep a SQLite ledger with actual exit codes, logs, and code identifiers, and provide stop, status, and resume operations.
- Reject altered specifications, invalid reviews, and approvals for code outside the target.
- Regression-test stopping descendants in the same process group, resuming after failure, and contention over the same run.

## Layout

- `apple/`: Swift Package, SwiftUI app, SQLite storage, iOS build path, and Swift tests.
- `harness/`: Local CLI with no additional Go dependencies, SQLite ledger, and execution / review control.
- `.local-state/`: Build caches and test data excluded from Git.

Go is pinned to 1.27.1 in the repository's `mise.toml`. macOS / Linux use the existing sqlite3 CLI.
SwiftUI and Xcode validation require macOS. Running the harness on Windows is outside the initial version's scope.
Package settings in other repositories or personal dotfiles are not changed.

## Development commands

```bash
mise run harness:check
mise run apple:test
mise run apple:build
```

See the [Apple instructions](../apple/README.md) and
[harness instructions](../harness/README.md) for detailed startup and task specifications.
[Tools and SaaS Comparison](harness-tools.md) records adoption criteria and unverified items.

## Reusable development skills

This checkout includes four repository-scoped skills in `.agents/skills/`.
Codex can select them by task, or you can explicitly invoke the names below. Automatic selection remains enabled.
Read only the selected skill and the references needed for the task; the existing guides, scripts, and source contracts remain authoritative.

| Invocation | Use when |
| --- | --- |
| [$harness-development](../.agents/skills/harness-development/SKILL.md) | Running or maintaining a bounded implementation/check/review/repair loop, including recovery. |
| [$independent-review](../.agents/skills/independent-review/SKILL.md) | Independently reviewing changes or reproducing a reported regression. |
| [$apple-native-validation](../.agents/skills/apple-native-validation/SKILL.md) | Validating Swift/SwiftUI changes, native builds, and actual macOS/iOS behavior. |
| [$search-performance-validation](../.agents/skills/search-performance-validation/SKILL.md) | Checking article-read or full-text search correctness and latency under contention. |

For example: `Use $search-performance-validation to verify the changed search implementation.`
The skills route to existing procedures and do not grant additional spending or execution authority.
Skill/documentation-only updates use documentation checks; native builds, live model calls, and large benchmarks are selected only when the affected behavior or requested validation requires them.
Codex detects skill changes automatically; if a skill does not appear, restart Codex. See the [official skill documentation](https://learn.chatgpt.com/docs/build-skills).

## Boundaries

This is a local harness that can execute commands, not an OS sandbox for safely running arbitrary third-party tasks.
Only trusted tasks are accepted, with limits on execution scope, environment, and logs.
Worktree separation prevents editing conflicts; it is distinct from credential isolation.
The design keeps real product keys, learning history, and signing / publication credentials away from development agents.

Codex connection code and successful real-model inference are validated separately.
Local protocol tests are not treated as evidence of real-account availability or generation quality.
The textbook app's generation budget is separate from the included allowance for development through Codex.

## Validation record

Validated on 2026-10-22 with a Mac Studio M4 Max, 64 GB, Go 1.27.1, Swift 6.3.3, and Xcode 26.6.

- `mise run harness:check`: Formatting, go vet, and Go tests with race detection passed.
- `mise run apple:test`: 11 Swift tests passed without warnings.
- The macOS release app and iOS Simulator app built successfully. iOS arm64 / x86_64 compiled without signing.
- Interactive macOS checks confirmed explanations for wrong and correct answers, saving 2 answers, and retained history after restart.
- Interactive checks in the iPhone 17 Pro / iOS 26.5 Simulator confirmed the textbook, a correct-answer explanation, answer saving, and 1 history entry.
- In a temporary Git workspace, the Go CLI ran checks → review requesting revision → repair → checks → approve.
  The run became accepted with 1 repair cycle and 5 evidence records. Stale status and refusal to resume were also checked after deleting code.
  This validates a local fixture, not the quality of semantic review by a model.
- The installed Codex 0.148.0 schema was checked against the adapter contract.
  Initial validation of the minimal version used an empty dedicated HOME and reached initialize / account reading without sending inference requests.
- Type checking and builds for the existing web prototype passed, as did 33 textbook tests and 32 server tests.
- `mise run lint`: ESLint and Markdown checks for 17 documents passed.

Independent review reproduced and led to fixes for date-precision loss, 32-bit rounding of correctness integers, screen navigation during saves,
approval shown for old code, evidence / time / before-and-after hash checks during review recovery, and workspace exclusion.
Regression tests and a separate owner's recheck followed the fixes.

Go validation on macOS / Linux and Apple build paths were added to CI, but no push or GitHub execution was performed in this phase.
Linux hardware, a physical iPhone, signing, notarization, App Sandbox, and DB encryption remain unverified.
The subsequent [Live Codex Connection Validation](codex-live-validation.md) connected implementation, review, and repair to real models.
Terra, authenticated through the existing Pro plan, completed five separate threads and one repair cycle, with boundary tests changing from failure to success.
Product-side textbook generation remains disconnected.
The local runner is not treated as strong OS isolation or a completed mechanism for strict yen / token spending limits.

## Extension to RSS, bookmarks, and on-device translation

An information collection tab was added to the shared SwiftUI app. It fetches RSS / Atom and stores originals,
bookmarks, and Japanese translations in a separate `feed-library.sqlite`. The answer-history DB is retained.
The initial 11 tests were preserved; early in the extension, 38 tests passed, including feed, storage, and asynchronous races.
Interactive Mac checks confirmed 148 articles from Apple's official RSS feed, bookmarks, Japanese translation generation, and SQLite storage.
The iPhone 17 Pro Simulator also passed checks for adding RSS, navigating to articles, and the bookmark list.
Apple Translation itself is validated on the Mac; the Simulator is not counted as a translation success.

The initial application of the harness to the real app did not reach autonomous acceptance.
An interruption occurred because communication for the larger implementation request was limited to the same 1 MiB as saved logs.
Communication and saved-log limits were separated, with regression tests added to distinguish failure reasons.
Repair now receives the latest compiler diagnostics directly, addressing repeated attempts to fix only old failures.
Failure lines near the beginning of long test output are also passed, within limits, from hash-verified logs.
The parent owner fixed Swift 6 translation-session isolation, and four bugs reproduced by independent subagents were also fixed.
Completion of an autonomous loop on the real app is validated separately from these local fixes and tests.
