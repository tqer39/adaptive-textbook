# Tool selection for the development harness

[English](harness-tools.md) | [日本語](harness-tools.ja.md)

This selection record was checked against official documentation and Context7 on 2026-10-22.
The comparison focused on developing Swift native applications and Go services, without treating the existing implementation language as a selection constraint.
Choosing an approach is separate from verifying a live connection. This research made no contracts, external trace submissions, live model calls, or purchases/charges.

## Initial architecture

A local Go runner controls development, with persistent state in SQLite.
Agent execution is separated behind a stdio connection to the official Codex App Server.
This is separate from the product's lesson-generation database, budget, and credentials.
The existing OpenAI Pro subscription is the primary development resource; no additional Anthropic subscription or multiple SaaS products are assumed.

Each phase records its input, code identifier, verification results, review findings, and stop reason.
The runner checks evidence against the same code before proceeding and never blindly resends external operations with unknown outcomes.
App Server protocol tests use a fake executable; real authentication, model eligibility, and quota consumption are checked separately.
These protocol tests alone do not establish a successful connection to the live service.

## Comparison and decisions

| Candidate | Decision for this project | Adoption/reconsideration trigger |
| --- | --- | --- |
| Codex App Server | Adopt as the integration boundary; live communication unverified | Check CLI/authentication/model before a live connection |
| Temporal | Defer initially | Multiple hosts or long waits make maintaining custom recovery burdensome |
| Langfuse | Defer initially | Need to compare quality/failure causes across many runs and models |
| LangSmith | Defer initially | Shared evaluation/operations UI benefits outweigh data-transfer, contract, and operational costs |
| GitHub Actions | Use for independent CI checks | Set up configuration/run budgets and add Go/Apple validation |
| Kanary Relay | Optional conversational aid | Design/review handoffs across multiple GUIs become frequent |

## Findings from official documentation

### Codex App Server

App Server is an integration interface for conversation history, approvals, authentication, and agent events.
It handles threads and turns through JSON-RPC over stdio.
The runner distinguishes final response status, approval requests, process exit, and interruptions before deciding whether an operation succeeded.
Available authentication paths and models have not been verified with the real account.
A Pro subscription is not treated as blanket permission for charges from a separate API-key-based route.
See the [official OpenAI App Server documentation](https://learn.chatgpt.com/docs/app-server).

### Temporal

Workflows reconstruct state from persisted history and therefore require deterministic execution.
External operations need idempotency and outcome reconciliation for Activity retries and re-execution after worker shutdown.
Adding Temporal alone does not automatically remove duplicate side effects such as LLM requests or payments.
The initial runner also records intent before execution, holds unknown outcomes, and makes explicit resend decisions.
See the [official Temporal Tasks documentation](https://docs.temporal.io/tasks) and
[Activity definitions](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-definition.mdx).

### Langfuse and LangSmith

Both are candidates for observing model calls and evaluations.
LangSmith documents integrations with multiple providers and implementations, rather than being limited to a particular framework.
Langfuse self-hosting includes PostgreSQL, ClickHouse, Redis, object storage, and other components beyond the application.
Those are not initial requirements for this single runner.
See the [Langfuse self-hosting documentation](https://langfuse.com/self-hosting) and
[LangSmith Observability documentation](https://docs.langchain.com/langsmith/observability).

Before adoption, decide which prompts, responses, code, and personal information may be transmitted and stored.
Even local records should not collect bodies or secrets indiscriminately; use task IDs, phases, durations, exit codes, and artifact references by default.
Observability SaaS does not replace permission controls or budget stops.

### GitHub Actions and Kanary Relay

GitHub-hosted runners support Linux, Windows, and macOS and can provide independent CI verification.
Pin third-party actions to full commit SHAs and restrict permissions/secrets to what is necessary.
The initial design does not register the personal Mac as a shared self-hosted runner executing untrusted PRs.
See GitHub's [runner documentation](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners) and
[secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use).

Kanary Relay is officially described as a GUI-to-GUI handoff aid where the reader chooses to send.
A separate unattended runner is still required for stop/resume, budgets, and test evidence.
See the [official Kanary explanation](https://kanary.to/blog/harness-of-harnesses).

## Where pstack fits

Further research found [pstack in the official Cursor Marketplace](https://cursor.com/marketplace/cursor/pstack).
It is a development plugin/Agent Skills collection distributed and verified by Cursor, separate from the Unix stack-trace utility pstack.
The [publisher's README](https://github.com/cursor/plugins/blob/main/pstack/README.md)
lists `/add-plugin pstack`, `/setup-pstack`, and `/poteto-mode` as entry points.
No standalone built-in `/pstack` command was found in the primary sources reviewed.

`/interrogate` provides opposing reviews by independent models, and `/benchmark-checklist` checks measurement conditions; both fit this project's approach.
They are procedures and decision criteria, not substitutes for the Go runner's ledger, stopping, permissions, or evidence storage.
Reviews in separate conversations are not described as equivalent to comparisons across different model families.

The [official Grok Bot Skills and routines documentation](https://docs.x.ai/grok-bot/skills-routines-and-automations)
describes adding packaged skills and invoking them through the desktop `/` menu.
Whether the owner's subscription/catalog permits adding pstack, or the same skill works unchanged across hosts, remains unverified.
Third-party ports for Grok Build are not treated as official Grok Bot support.
This work installed nothing and changed no settings; it remains a candidate for evaluation after identifying the required skills and versions.

## Costs and open questions

SaaS subscriptions, quotas, additional charges, macOS CI execution, and self-hosting infrastructure costs have not been estimated.
There is no promise that free allowances and existing subscriptions cover all processing.
Development Pro quota, development API spending, and product lesson-generation costs are recorded and managed separately.
Before enabling external traces or new paid infrastructure, confirm the data involved, retention conditions, applicable prices, and budget.
