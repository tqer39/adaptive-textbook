# Product development sequence

[English](product-development.md) | [日本語](product-development.ja.md)

## Browser first

The owner's decision on 2026-10-24 is tracked in [Issue #41](https://github.com/tqer39/quilna/issues/41).
Concentrate product development on the browser and iterate until the owner explicitly judges it easy to use.
Keep macOS/iOS feature development, native UI experiments, packaging/distribution, device performance work and native model evaluations on hold until that acceptance.
Preserve existing native code, PRs and dated evidence; unfinished native issues remain open.
Existing CI and necessary security maintenance may still validate native code and the Go harness.

## Acceptance loop

1. Present one coherent browser learning flow: open a lesson, read and navigate, use diagrams, answer a question, understand its explanation, and reload/resume with the saved answer.
2. Record the app/source version, browser/viewport and the owner's concrete observations.
3. Reproduce and repair usability blockers, verify the affected behavior, then ask the owner to try the changed flow again.
4. Continue browser work until explicit owner acceptance. Record what was accepted and which features remain unfinished before moving to another platform.

Automated tests, CI, benchmarks and model reviews support verification; they cannot establish the owner's usability judgment.
Keep lesson/version identity and private answer history intact, and show actual save failures with a retry path.
Distinguish implemented behavior from simulations and disconnected features, including real-key entry, authentication and live generation.
Do not represent a fixed sample lesson as completion of the full generated-textbook product.

## Work ordering

- Address security and data-loss problems first, including [security maintenance](security-maintenance.md).
- Use Issue #41 for browser usability and concrete feedback; repair blocking defects before optional additions.
- Continue the full source-to-textbook-to-comprehension workflow in [Issue #7](https://github.com/tqer39/quilna/issues/7) on the browser first.
- Preserve source-aware sharing in [Issue #30](https://github.com/tqer39/quilna/issues/30) and paper discovery in [Issue #31](https://github.com/tqer39/quilna/issues/31) as follow-ups to the learning flow.
- Keep native-only work deferred until the owner accepts the browser experience.

This sequencing decision does not authorize paid provider calls, new credentials, publication or merging unrelated PRs.
Browser acceptance is currently pending. Do not infer it from an implementation report or a successful automated check.
