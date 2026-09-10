# macOS integration and CI evidence

Status: this checklist defines required checks, not completed evidence. Every manual row below is **PENDING / UNVERIFIED** until a dated result and evidence location are recorded. An unavailable display, OS, permission, app or signing identity is not a pass.

## Deterministic CI boundary

`.github/workflows/macos-tests.yml` runs `bash script/ci_test.sh` on a disposable macOS runner. It selects Xcode 26.6, verifies the SHA-256 of XcodeGen 2.46.0, regenerates the project, and performs a clean optimized Debug build plus the complete `SwiftShotTests` suite. Compilation explicitly retains `MACOSX_DEPLOYMENT_TARGET=14.0`. The newer build host does **not** establish runtime compatibility with macOS 14.

The runner/toolchain choice follows the [GitHub macOS image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). The XcodeGen archive and its recorded digest come from the [2.46.0 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0). Runner images still receive updates; the script records actual OS, architecture, compiler, generator and Python versions for each run and fails if the pinned Xcode or generator is unavailable.

The command-line `ENABLE_HARDENED_RUNTIME=NO` and ad-hoc signing overrides are test-host-only; they enable XCTest injection without production signing credentials. They do not edit the Release signing settings, install `/Applications/SwiftShot.app`, or replace the user's running app. The script regenerates the working checkout's Xcode project, so use a disposable checkout when preserving an in-progress generated-project diff.

CI also runs the benchmark reporter's Python unit tests and checks staged, unstaged and commit/PR-diff whitespace. The Swift tests use synthetic pixels, isolated temporary storage and injected capture/clipboard/driver dependencies. CI must not request Screen Recording or Accessibility access, reset or grant TCC, drive the real desktop, post native scroll events, or claim an actual paste occurred. Any newly added permission-dependent test belongs in a separately gated manual suite, not the unattended target.

Synthetic renderer benchmarks may emit timing samples during this test suite. Hosted runner timings are diagnostic only: they are not same-machine before/after evidence and cannot satisfy selector, editor, clipboard, frame-rate, idle-CPU or memory acceptance targets. No tests are retried or converted into skipped successes by the script.

### Run and inspect

```sh
bash script/ci_test.sh
```

The script requires the pinned tools already available locally; it does not install tools. Each run gets a fresh `build/ci/run.*` directory and unique derived-data and result-bundle paths. Logs include each command's complete stdout/stderr, individual exit statuses, overall exit status, and `build.xcresult` / `tests.xcresult` when Xcode produces them. Build failure prevents test execution and writes an explicit `tests-not-run.txt`. The first actual failed check remains the script's exit status; a successful log tail or artifact upload cannot hide it.

GitHub uploads logs, status files and result bundles even after a failed test step, retaining them for 14 days. If infrastructure/tool setup fails before results exist, inspect the failed Actions setup step; missing bundles are not passing test evidence. Do not upload private manual screenshots, original captures, OCR contents, recovery stores, signing material or account data with CI artifacts.

## Manual environment matrix

Use a synthetic, non-private fixture. Record commit, app version/build, OS version, hardware, architecture, signing class, display resolution/scale/refresh/layout and relevant permission state. Check a stably signed Release app for real permissions/update behavior; an ad-hoc XCTest host is not a substitute. Use a separate test account or dedicated disposable application data for destructive recovery/retention scenarios.

| Environment | Required coverage | Status |
| --- | --- | --- |
| macOS 14, Apple silicon | Launch, basic workflows, permission flow, recovery, signed update | PENDING / UNVERIFIED |
| macOS 14, Intel where supported/available | Launch and same baseline workflows; record missing hardware explicitly | PENDING / UNVERIFIED |
| Latest supported macOS, Apple silicon | Complete checklist below | PENDING / UNVERIFIED |
| One display, native and scaled modes | Coordinate/pixel fidelity and interaction | PENDING / UNVERIFIED |
| Mixed-scale multiple displays | Negative origins, both arrangements, spanning windows, hotplug | PENDING / UNVERIFIED |
| P3 / HDR / high-refresh display where available | Explicit color/output contract, highlight handling, measured frame cadence | PENDING / UNVERIFIED |

## Manual workflow and failure matrix

Each row needs observed behavior, expected-versus-actual result, date, tester and evidence link. Record failures/cancellations as such. Do not quietly retry them into a pass.

| Scenario | Required observable checks | Status |
| --- | --- | --- |
| Region / window / fullscreen | Correct selected display and native pixel dimensions; no own overlay/panel in capture; spanning-window behavior is explicit | PENDING / UNVERIFIED |
| Permission denied / granted / revoked | Denial remains actionable; Settings/Retry work; stale callbacks do not reopen old sessions; no capture is reported successful on failure | PENDING / UNVERIFIED |
| Rapid cancellation / repeated shortcuts | Escape during capture, selection, render, OCR and save; new sessions do not receive old results; controls remain usable | PENDING / UNVERIFIED |
| Sleep / wake / display hotplug / resolution change | Stop unsafe acquisition; preserve finishable partial/unsaved content; reject stale coordinates; recover with a fresh selection | PENDING / UNVERIFIED |
| Spaces / fullscreen apps / Stage Manager | Selector, editor and pins follow intended visibility; focus returns appropriately; hidden/fullscreen targets fail safely | PENDING / UNVERIFIED |
| Native / smaller-share / color exports | Independently decode PNG; verify dimensions, source pixels, alpha, color profile, crop boundaries and background scaling; assess HDR behavior explicitly | PENDING / UNVERIFIED |
| Annotation / crop / undo / text focus | Arrow/shape/redaction placement, crop moves/resizes, undo/redo, keyboard focus, text shortcuts and editor response | PENDING / UNVERIFIED |
| Opaque redaction | Export and pasted pixels reveal no original pixels in redacted area; document that editable recovery originals remain sensitive | PENDING / UNVERIFIED |
| Copy → real paste → Save | Destination actually receives the intended image; identical revision exports match; failed clipboard/save leaves capture available | PENDING / UNVERIFIED |
| Quick Copy / OCR / recapture / presets | Correct independent workflow style/privacy; OCR handles empty/error results; last-region recapture rejects changed layout | PENDING / UNVERIFIED |
| History / search / reuse | Large history stays responsive; OCR index respects opt-out; recovered edit/export matches; corrupt/missing records fail visibly | PENDING / UNVERIFIED |
| Recovery / privacy / disk errors | Unsaved survives restart; private captures never enter durable history; disk full/unwritable destination offers retry; failed quit preserves usable editor | PENDING / UNVERIFIED |
| Retention / delete / source protection | Dedicated fixture only: confirmed permanent deletion targets the intended editable original; saved exports remain unaffected; unsaved captures are not silently pruned | PENDING / UNVERIFIED |
| Pins / combine | Multiple pins close/reopen and resize without accidental mutation; combined source order/pixels/style verified; oversized combine fails without losing sources | PENDING / UNVERIFIED |
| Manual scrolling capture | Uneven movement, sticky headers/footers, repeated content and dynamic regions; only verified overlap appended; partial completeness warning remains honest | PENDING / UNVERIFIED |
| Automatic scrolling capture | Explicit Accessibility/event-posting access; original app/window/scroll area plus pointer rechecked before every HID request; observed target or pointer loss latches stop and suppresses page/pointer/focus restoration; own panel never intercepts; Stop returns promptly. Public post routing is not atomic with validation and has no delivery acknowledgement. | PENDING / UNVERIFIED |
| Scroll restoration / limits | Check page offset, pointer and focus; uncertain restoration remains warned; memory/frame limits retain usable partial output without unbounded allocation | PENDING / UNVERIFIED |
| Signed update / relaunch | Existing app quits safely; replacement preserves designated signing requirement; failed update leaves original app intact; permissions and unsaved recovery survive | PENDING / UNVERIFIED |
| Idle / repeated-session resources | At least 60-second idle observations and 100-session series; record CPU, RSS trend/peak and cache ownership with actual measurement | PENDING / UNVERIFIED |
| End-to-end latency / display-rate / comparisons | Follow the benchmark protocol's cold/resident, idle/busy and display matrix; real readiness/paste observation and available competitor comparisons | PENDING / UNVERIFIED |

See [BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md) for sampling, action counts, percentile calculation and privacy rules. Keep the whole-goal Done/Not Done decision in [GOAL_PROGRESS.md](GOAL_PROGRESS.md); CI green alone does not close the manual matrix or performance gates.
