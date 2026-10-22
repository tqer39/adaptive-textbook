# Investigating the initial Mac Chrome timeouts

[English](browser-timeout-investigation.md) | [日本語](browser-timeout-investigation.ja.md)

## Conclusion

The cause of the initial two failures remains unidentified. Passing sequentially is not treated as a resolution.
On the latest v1.5 (4852a0a), repetitions with the same two-worker setup as the initial run did not reproduce them.
No evidence was obtained of an application race or insufficient runner resources, and the application code was not changed.

A shared test-image output destination was found and changed to a destination specific to each test.
However, that collision is not established as the cause of the initial timeouts.
There is no basis for fixing the worker count at one, so both regular Chromium and installed Chrome are explicitly set to two workers.
The 30-second test timeout and no-retry policy remain, with traces retained on failure.

## What the initial logs establish

- Desktop test for retaining old answers and operational examples
  - Name: `new predictions, applications and old answers survive the version update`
  - Assertions for answers, retained old history, and three displayed results had already passed.
  - `page.screenshot({ fullPage: true })` on the applications screen timed out after 30 seconds.
  - The log reached fonts loaded, but image capture did not complete afterward.
- Mobile test for opening and closing term help
  - Name: `term help preserves reading position, context and focus without scoring`
  - After Back → Forward, the close-button locator resolved once and then the element detached from the DOM.
  - Locator retries did not complete, and the test timed out after 30 seconds.
  - The page snapshot at that point had no explanation screen; it showed the reading screen and resume button.

The initial run did not collect traces or continuous CPU/memory measurements.
An exact source snapshot from that development stage was not captured either, so current repetition results cannot identify why the DOM changed then.
The chat execution log is the evidence for the raw output from that run. Older test-results were replaced by later runs.

## Reproduction tests

All tests used new Playwright-owned contexts without connecting to the user's Chrome profile.
The tmux server serving the material being read, textbook data, and the user's localStorage were not changed.

- With the original output destinations, the two relevant cases × desktop/mobile × 10 repetitions, two workers: 40 passes.
  - 0 retries, skips, or flaky cases. 21.2 seconds; individual cases took 576–1042ms.
  - All 40 traces were captured. No operation failed.
  - The only console error was a favicon.ico 404. No application exceptions were observed.
- After separating output destinations, the same cases × desktop/mobile × 5 repetitions, two workers: 20 passes in 10.6 seconds.
- After separating output destinations, all 28 Chrome cases, two workers: passed in 7.4 seconds.
- All 28 regular Chromium cases, two workers: passed in 6.1 seconds.
- lint and typecheck: passed.

JSON, traces, and logs from the reproduction tests are stored in temporary storage on the machine:
`/tmp/caa-timeout-parallel.*`, `/tmp/caa-timeout-parallel/`,
`/tmp/caa-timeout-isolated.*`, and `/tmp/caa-timeout-isolated/`.
Long-term retention is not guaranteed because these locations are temporary.

## Checking the hypotheses

### Storage and ports

Each test uses the standard page fixture, with an independent BrowserContext per test.
There is no shared storageState, persistent profile, or global page fixture.
This matches [Playwright's context isolation](https://playwright.dev/docs/browser-contexts).

localhost:5173 only shares static material and Vite delivery; there is no server API that stores learning history.
The existing server is reused, and no operation starts a second server on the same port.
The application's answer-display Map and dialog Map are browser-side and are not shared across contexts.

### Image destinations

In the old implementation, desktop/mobile projects wrote term-help.png to the same file.
Other images also shared file destinations across repeats/retries or concurrent runs by different runners.
All were changed to `testInfo.outputPath()` to separate destinations by test/project/repeat/retry.
Regular Chromium and Chrome also have separate outputDir values.
The [API](https://playwright.dev/docs/api/class-testinfo#test-info-output-path)
provides this behavior.

The initial desktop applications failure and mobile term-help failure occurred at different operations.
There is no evidence that this file collision explains both. It is a known improvement to the test infrastructure.

### Load and workers

The machine has 64GiB RAM and 16 logical CPUs. Resource information was checked read-only during the reproduction tests.
This does not rule out a resource shortage in the initial run; CPU/memory trends from that run are unknown.
The current two-worker repetitions pass quickly, providing no basis for limiting workers to one.

Two workers preserve the original execution conditions while placing an upper bound on concurrent browsers if more test files are added.
Following [worker behavior](https://playwright.dev/docs/test-parallel), failures have not been hidden by extending timeouts or adding retries.

## If it recurs

Reproducible settings are saved in `playwright.chrome.config.ts`.
Use failure traces, DOM snapshots, navigation/console logs, and image-capture API state to distinguish
screen regeneration, history traversal, and stalled image capture.
If a resource shortage is suspected, record CPU/memory at the same time as that recurrence before drawing a conclusion.
For now, retain this as an observation with an unidentified cause, rather than calling it resolved.
