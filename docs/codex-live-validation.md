# Live Codex Connection Validation

[English](codex-live-validation.md) | [日本語](codex-live-validation.ja.md)

Validation of the development harness connected to Codex App Server, authenticated through an existing ChatGPT subscription.
This is separate from API connections through which the textbook app would offer translation or textbook generation to its users.

## Subscription and stop conditions

The [official OpenAI authentication guide](https://learn.chatgpt.com/docs/auth)
distinguishes ChatGPT login for included subscription usage from API keys for usage-based billing.
This validation permits only ChatGPT authentication and does not pass API keys.
The [allowance and additional-credit guide](https://learn.chatgpt.com/docs/pricing) is also checked.

- Check `account/read` and `account/rateLimits/read` before sending each model turn.
- Require a known remaining included allowance; do not send at 80% usage or higher, on reaching a limit, when additional credits are present, or when information is insufficient.
- Run at Standard, without inheriting Fast / Ultrafast.
- Do not automatically purchase, add funds, choose to spend additional credits, reset an existing allowance, or switch to the API.
- Limit operation count, repair cycles, and runtime, and do not automatically resend requests with unknown outcomes.

Remaining allowance is point-in-time information for the shared account. It does not reserve one turn's usage.
CLI 0.148.0's protocol has no yen ceiling or option to reserve only included allowance.
It does not guarantee an absolute spending cap or a bound on usage when another chat is used concurrently.
Execution is held when additional spending would be needed, and the user is informed.

## Real-model test

`scripts/codex-live-smoke.py` creates a temporary Git workspace without secrets
to validate a small Go grading function for free-text answers in a Japanese textbook.

1. In Run A, a real model implements the function and passes fixed basic tests and an independent real-model review.
2. The driver injects an explicit test-only fault that breaks Unicode whitespace handling.
3. In Run B, a separate real-model review detects the fault and passes findings to the repair role.
4. Repair, basic tests, and rereview run automatically.
5. The driver runs its own Unicode boundary tests in a separate working copy and compares failure before repair with success afterward.

The reviewer is not instructed to return `revise`. If it misses the injected fault, the smoke test fails.
The test checks whether independent review detects acceptance conditions missed by the basic tests alone.
This is an artificial small task, not proof of handling arbitrary product tasks or of general review accuracy.

## Reproduction

Specify the Go harness executable, native Codex executable, authenticated CODEX_HOME, and model ID.
Do not put authentication values in arguments. Use `model/list` to check the model IDs actually offered.

```bash
GOCACHE="$PWD/.local-state/go-cache" go build -C harness \
  -o "$PWD/.local-state/textbook-harness" ./cmd/harness
python3 scripts/codex-live-smoke.py \
  --harness-binary "$PWD/.local-state/textbook-harness" \
  --codex-binary /absolute/path/native-codex \
  --codex-home /absolute/path/configured-codex-home \
  --model MODEL_ID \
  --go-binary /absolute/path/go \
  --output "$PWD/.local-state/codex-live"
```

Use a new output directory. Existing results are not overwritten.
Do not put production signing keys, API keys, or learning history in the validation folder.

## Record

Before real-model inference, the following metadata was checked through official CLI 0.148.0.
Email addresses, account IDs, authentication values, and raw protocol traffic are excluded from the record.

- Authentication: `chatgpt`; plan type: `prolite`.
- Shared weekly allowance: 8% used, no additional credits, and no spending-control or limit-reached condition.
- `model/list` default: `gpt-5.6-sol`. Selection is based on the model list returned by this CLI.

Execution results are tied to the model's final output, code hash, frozen specification hash, validation logs, and thread / turn IDs.
CLI-only connectivity checks and fake-server tests are distinguished from successful real inference.

### Differences fixed during live integration

- `hooks` contains a `state` dictionary holding trust status, in addition to event arrays.
  Replacing `state` with an array makes thread creation fail, so a regression test was added to distinguish it from events.
- With CLI 0.148.0, `features.hooks=false` is specified both at startup and in thread settings.
  Emptying event arrays alone does not disable `hooks.json` from another configuration layer.
  Legacy notifications are disabled separately with `notify=[]`.
- `failed`, `interrupted`, and unknown outcomes are distinguished, and only official error types and HTTP status are stored.
  `responseTooManyFailedAttempts` and HTTP 429 were observed through the live connection.

In the Sol attempt, implementation and independent review passed, and the post-injection review detected the Unicode fault.
The repair turn failed with HTTP 429; saved history and unchanged code were checked read-only.
A later Sol retry in a separate workspace also returned 429, so Terra, offered under the same Pro authentication, was selected.
Failed turns were not automatically resent, and there was no switch to API keys or additional purchases.

### Passing real-model test

Completed on 2026-10-22 with Codex CLI 0.148.0, `gpt-5.6-terra`, Standard, and existing personal Pro authentication.
The driver and Go harness ran the following sequence without human intervention in implementation, review, or repair.

| Target | Verified result |
| --- | --- |
| Run A | Real-model implementation → basic tests → independent review returning `approve` |
| Fault injection | Broke Unicode whitespace handling and confirmed failure of the fixed boundary tests |
| Run B | Basic tests → `revise` → real-model repair → basic tests → `approve` in another thread |
| After repair | Fixed Unicode boundary tests passed; specification and validation files remained unchanged |
| Model | Requested and resolved models matched for all 5 operations; all 5 threads were distinct, with turn state `completed` |
| State reconciliation | `accepted`, `stale=false`, and the current code hash matched the final approval hash |
| Duration | 101.13 seconds for the successful sequence of 2 runs, excluding preparation diagnostics and failed attempts |

Run A ID: `c6bd6d684e9d60b0bec96937`; Run B ID: `60d7ac4648a7e328d28cbd67`.
Details were saved outside Git in `.local-state/codex-live-20261022-terra2/report.json` and both runs' SQLite ledgers.
The final read still showed ChatGPT / `prolite`, 11% weekly usage, no additional credits, and no spending-control or limit-reached condition.
Usage percentages cover the whole shared account and are not treated as consumption attributable to this test alone.
No additional subscriptions, credit purchases, or API-key billing were used.

The final Go code passed `mise run harness:check` (gofmt, go vet, race detection; 76.003 seconds).
Python syntax, preparation-only execution, rejection of an existing output directory, and fixed-test fault detection were also checked.

An earlier Terra attempt stopped on a review approval request, so the review policy was adjusted to `on-request`.
`readOnly`, the network prohibition, and refusal of additional-permission requests remain in place.
Subsequent HTTP 429 errors or similar failures also stop execution rather than automatically switching to a paid path.
Automatic model switching and automatic retry are not implemented.
