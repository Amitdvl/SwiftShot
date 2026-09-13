# Product-focused release verification

## 2026-09-13 passive Scrolling Capture rebuild

Scrolling Capture was deleted and rebuilt as a passive workflow: choose **Capture Scrolling Area…**, select one viewport, scroll naturally, then **Finish** or **Cancel** from a compact nonactivating HUD. A persistent cropped ScreenCaptureKit stream excludes SwiftShot itself and feeds a bounded newest-wins queue. A pure off-main stitch engine accepts only confident seams, preserves verified partial output, and renders once into the normal `.scroll` editor path. There is no synthetic input, pointer movement, page-position restoration, bottom detection, or Accessibility/Input Monitoring dependency.

The current branch includes deterministic coverage for exact uneven offsets, sparse/repeated layouts, narrow unique markers, periodic dynamic rows, duplicates, noise, sticky edges, blank/ambiguous content, reverse motion, dimensions/scales, ingest and render-peak limits, concurrent cancellation, stalled native-stop ownership, source failure, zero-frame terminal HUD behavior, private lineage, and editor handoff. Native validation on the final signed Release app kept the browser scroller focused during natural keyboard scrolling, accepted a verified append, preserved it through a later low-overlap frame, and opened a continuous **1143 × 1219** partial in the normal editor. The HUD was visible during capture and absent from the captured pixels. Native Cancel was exercised twice and produced no editor document. Retained screenshots and their hashes are recorded in `build/goal/passive-scroll-audit-fixed-evidence.md`.

The final CI gate passed every preflight, diff, shell, benchmark-report, wrapper, project-generation, build, test, and final-diff phase. XCTest executed **393 tests with zero failures** in 69.458 seconds; retained evidence is `build/ci/run.m56yDz`. The Apple Development-signed installed app passed strict deep signature verification and remained launchable. Its executable SHA-256 is `0cf9473bf00aaf7d9a264d8f42df060bfefba3268311a60e8703c5e19f6dac9f`.

Local package: `build/release-artifacts/SwiftShot-scrolling-capture-2026-09-13-audit-fixed.zip`. ZIP integrity and extracted-bundle strict signature verification passed; SHA-256 is `62f1018cb8d3a2a09e385b39a1417cfb577c4df10aed561e6bb5663933cf4f50`. This is a development-signed local artifact, not a notarized public release. Historical sections after this candidate describe earlier builds; references there to automatic scrolling concern the retired implementation, not the current product.

## 2026-09-13 Scrolling Capture spotlight

Scrolling Capture now keeps the selected viewport bright inside a passive full-display spotlight while dimming the surrounding screen. A glowing selection edge, attached cumulative extent badge, and short accepted-frame trail make progress legible without obscuring the page. Finish and Cancel remain in a compact capsule outside the selection. The spotlight is nonactivating and click-through, so scrolling and pointer input continue to reach the source application; the control capsule stays one window level above it.

The stitch engine now publishes measurement-only `ScrollingCaptureExtent` updates after verified accepts instead of rendering preview pixels during capture. Native validation on the installed signed app showed the bright viewport and measurement advancing from **1.0 screen · 962 px** to **1.3 screens · 1,282 px** while the page visibly scrolled underneath and Chrome retained focus; Finish opened the stitched result in the normal editor. Retained visual evidence is `build/spotlight-native-final-initial.png` and `build/spotlight-native-final-progress.png`.

The focused Scrolling Capture slice passed **38/38 tests**. The full CI gate passed every phase and executed **398 tests with zero failures**; evidence is `build/ci/run.VnudPs`. The installed executable passed strict deep signature verification and has SHA-256 `bc39f9b115617f240b91b3b27e1e126f79fd25d50c7ea036765e96ab26c2b3f2`.

Local package: `build/release-artifacts/SwiftShot-scrolling-spotlight-2026-09-13.zip`. ZIP integrity passed; SHA-256 is `ee13f17a40c2f97e506084fd79bba6d7f7ec69bd70f723e6ea43aa806380df61`. This is a development-signed local artifact, not a notarized public release.

2026-09-11. This is the product finish pass defined in [GOAL.md](GOAL.md), not completion of the old exhaustive certification matrix. All artifacts below are retained locally under `build/goal/` and are not a public notarized release.

**Delivered:** product source commit `f9ea9c958834dac41d3510e43a385918134b712f` was pushed to `origin/main` and verified against the remote ref. The installed app's signature and executable hash were rechecked after publication; it remains running. No new material blocker was found in the bounded finish pass. Documentation-only delivery bookkeeping may follow this product commit without changing the tested binary.

## Rounded native polish candidate

The follow-up rounded-native polish candidate was built and installed from the final working tree on September 11, 2026. Its optimized Release suite passed **501/501 tests** (`build/polish/final-release-after-handoff.log`); the focused product slice passed **77/77** and the recent-thumbnail handoff regression passed separately. `script/build_and_run.sh --verify` completed the guarded Apple Development build, install and launch. The installed executable SHA-256 is `50004a6286c8658f98a42d41cc1b27c731d757550060eb4e4291c9ac657f298c`; `codesign --verify --deep --strict` passed. The package `build/polish/SwiftShot-rounded-native-polish-final.zip` passed `unzip -tq` with SHA-256 `3297e6123bbf2ddc580f6ab499fbf2cc90afeeb2bd9eb47f3abf8c10f869d4d4`.

The installed Settings window was inspected in light appearance with the rounded saving, recovery and recent-capture controls visible. Earlier retained native evidence covers dark appearance, increased contrast and reduced-transparency behavior. The native keyboard fixture was initially unable to acquire its own active/key window, then passed in the final full suite after the owned installed app was quit normally; that transient setup failure is retained in `build/polish/floating-keyboard-retry.log`.

## Verified on the installed candidate

- **497 Release XCTest cases passed, zero failures**, real process exit 0. Complete log/result: `product-finish-release.log` and `product-finish-release.xcresult`. Includes capture/export ownership, recovery/private mode, annotation/rendering, scrolling, history, presets, floating UI and App Intents behavior tests. Test-host AppKit/transaction and system App Intents warnings remain in the logs; a passing test is not proof of every external OS integration.
- **14 Python script/report checks passed**, zero failures; `product-finish-python.log`.
- Stable Apple Development-signed Release built, verified, installed and launched successfully through `script/build_and_run.sh --verify`; `product-finish-install.log`. Previous installed bundle retained in `SwiftShot-product-finish-before.zip`.
- Actual Region -> keyboard Redact -> drag -> Save produced a new **1280 x 320 PNG** in an initially empty task-owned folder. Independent comparison to the pre-capture synthetic reference found all **60,416 mask pixels opaque black**, all **349,184 outside pixels identical**, zero mismatches. File identity/size remained stable across verification; the native editor closed after Save without an observed warning. Evidence: `product-finish-redact-verdict.txt`, `product-finish-mask-preview.png`, `product-finish-output/SwiftShot-2026-09-10T214700-3E23574A.png`. The reference/mask were not derived from the output. Container privacy is additionally covered by the existing marked-source PNG tests; the native pixel helper itself is not a container parser audit.
- OCR's guarded native smoke copied the exact expected three-line fixture text; clipboard count advanced **467 -> 468** and was stable across the read. Frozen-selector pixels were visually checked. Evidence: `product-finish-ocr-retry/`. The first attempt had no expected words and insufficient source-focus proof; its failure is retained, not counted as a valid OCR accuracy/performance sample. Explicit source-window raise and foreground verification preceded the successful retry. No product OCR change or new phase tracing was required.
- Save destination restored to Desktop through Preferences; temporary fixture closed. No user recovery records were deleted or retention/private settings changed for the smoke.

## Reused evidence and review

The focused independent reviewer found no new confirmed material defect in Window identity revalidation, clipboard/export ownership, final opaque masks or recovery/shutdown ownership. The lead inspected those paths and current integration changes, removed only the unintegrated OCR tracing proposal from the test target (retained under `build/goal/deferred-OCRServiceTraceTests.swift`), and ran the final tests/install/smoke.

Prior native evidence in [GOAL_PROGRESS.md](GOAL_PROGRESS.md) includes actual Region/Window Copy -> paste and focus restoration, resizable pins, history reopening/context actions, independently checked distinct-source combines, private/public recovery, manual scrolling pixels and bounded automatic-scroll stop/loss behavior. Those observations retain their original build/date boundaries; they are not claimed as newly repeated on this binary. Current deterministic regression tests cover these features. No new product implementation was added in this finish pass merely to satisfy the superseded benchmarks.

## Deliberate follow-ups, not hidden passes

- OCR already uses bitmap-only rendering, avoiding PNG. Earlier correct warm OCR admission -> clipboard observations were **100.449/115.488 ms**; one first-use observation was **7502.576 ms**, unattributed. The bounded smoke established working ordinary text recognition, not broad language/accuracy or cold-latency certification. Further OCR optimization is not the release focus.
- Historical Window editor p95 and ordinary-edited native-4K Copy targets are not certified. Busy/multiple-display matrices, display-rate proof, full HDR fidelity and macOS 14 runtime checks are unverified on this machine.
- The retired automatic-scrolling implementation had conservative early rejections on some changing content. Its retained evidence is historical and must not be read as a claim about the passive rebuild above.
- Native Shortcuts registration/OS-transition and drag-destination coverage is incomplete. Local tests are not a claim of external CI success or notarization.

## Local package

`SwiftShot-product-finish-release.zip` passed ZIP integrity verification and contains the installed signed app. SHA-256: `d001416da37ccd2c0efdab9cf44091ac5ac41661a02a2fa3a354139447f628dd`.

Installed executable SHA-256: `5f656c92059f7340e9c435373d465f639d2166ce1352cb56d3a05d438ff5e37c`.
