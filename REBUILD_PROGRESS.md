# SwiftShot rebuild

## Lead contract

Outcome: freeze-first native capture with an in-place editing toolbar, managed backgrounds, native-pixel exports, and recoverable copy/save flows. Preserve fullscreen and OCR. Minimum OS remains macOS 14.

Non-goals: cloud, video, a large history browser, or a general image editor.

The lead owns capture backend, lifecycle, integration, independent verification, release packaging, and final review. Bounded workers own renderer/tests, background library/picker, and overlay interaction respectively. Shared model contracts are lead-owned. No concurrent edits to shared files.

## Baseline

- Source audit and independent review confirmed fractional resampling/distortion, one-slot pending-capture loss, swallowed timer cancellation, failed-save data loss, invisible errors, and mismatched shortcut flags.
- Installed preferences inspected using Computer Use; fixed background row and shortcut toggles observed. Full capture/export baseline remains to be exercised.
- Pixel calculation: 1920 × 1080 source drawn at 1920.8 × 1063.8 with (19.6,19.6) origin in existing compositor.

## Acceptance matrix

| Requirement | Evidence needed | Status |
| --- | --- | --- |
| Freeze before overlay | Acquisition precedes panel creation; injected acquisition/cancellation tests pass. Actual Release capture returns permissionDenied. | Runtime blocked on Screen Recording permission |
| Display geometry | Nine geometry/layout fixtures cover Retina pixels, origins, window placement, bounded inspectors and small screens. Active display changes close/preserve the editor. | Hardware mixed-scale/Spaces/hotplug checks pending |
| Toolbar and edits | Six synthetic NSHostingView light/dark screenshots reviewed; clipped inspectors fixed and rechecked. Crop, annotation, undo/redaction export tests pass. | Live overlay interaction pending permission |
| Background library | Nine tests cover copy/import/duplicate/invalid/remove/undo/rollback/relaunch/edit restoration. Running Release native picker import, selection, removal, Undo Removal and relaunch passed. Synthetic import cleaned afterward. | Drag/drop and overlay sheet focus still need live checks |
| Native pixel exports | Pixel fixture assertions for unframed/framed captures, opaque redactions and PNG parity pass. | Automated pass |
| Reliability | Deterministic rapid capture/navigation/cancellation tests, save failure/retry, successful export plus cleanup failure, recovery, shortcut migration/conflicts, real Vision OCR pass. | Physical global shortcut input remains unverified |
| Responsiveness and polish | Optimized 3840×2160 render: 101 ms; 17 main-thread progress intervals, largest gap 6.12 ms. Synthetic light/dark toolbar review passed after placement fixes. | Capture-to-overlay latency and live focus/transitions pending permission |
| Delivery | Production Release app built in dist without XCTest injection; intended diff reviewed independently and by lead. | Package and launch pass; commit/push recorded in git history |

## API references

- https://developer.apple.com/documentation/ScreenCaptureKit/SCScreenshotManager/captureImage(contentFilter:configuration:completionHandler:)
- https://developer.apple.com/documentation/screencapturekit/scdisplay
- https://developer.apple.com/documentation/swift/task/sleep(nanoseconds:)

## Progress

- Established immutable image / top-left pixel edit model and bounded worker contracts.
- Implemented freeze overlays, scoped editing toolbar, library management, native-pixel renderer, recovery store, shortcut migration, and visible failure/retry UI.
- Initial native XCTest run: 27/28 passed; Retina fixture's expected width corrected from 102 to 202 after independent arithmetic check (100.5 points at 2× plus outward rounding).
- Regression run: **35 tests passed, 0 failures** (`build/Tests-Regression.xcresult`), including actual Vision OCR, failed-save retry, clipboard/export PNG parity, late persistence after discard, protected pruning, pixel-exact framing, library rollback/relaunch, and window-placement geometry.
- Release build and app launch pass. Native settings inspected through Computer Use. Its targeted key delivery did not exercise Carbon global shortcuts; actual event/capture path remains to verify through visible capture menu and hardware input if needed.
- Independent review found and fixed stale OCR/copy/save completion dismissal, preservation failure navigation, session invalidation, and inaccessible single unsaved recovery.
- Window-specific snapshots now acquired before overlays, preserving window capture semantics when other apps overlap it. Runtime latency/memory remains to measure.


## Final verification checkpoint (2026-09-07)

- **52 XCTest checks passed, zero failures**, optimized Debug test host (`build/Tests-Final.xcresult`, `build/tests-final.log`). Test coverage spans 6 async workflow, 9 background library, 10 session races, 7 capture workflow, 7 renderer, 9 geometry/layout, 2 rendering evidence and 2 window visibility checks.
- Initial optimized/Release XCTest hosts failed library validation before running tests because ad-hoc test bundles have no matching Team ID. The successful invocation uses `ENABLE_HARDENED_RUNTIME=NO` only on the isolated test build. Production Release remains hardened; no signing/entitlement policy was weakened.
- Final independent review fixed recovery-navigation races, owned capture cancellation, misleading save-failure reporting after a successful write, stale transient crop previews and first-frame inspector clipping. Lead added display-layout cancellation, focus restoration, missing-background restoration for edit Undo and smooth integer-valued sliders.
- Visual evidence uses synthetic content and offscreen NSHostingView snapshots. It does **not** establish real capture, overlay keyboard handling, animated transitions, Spaces/fullscreen behavior or physical display performance. Local screenshots live under `build/evidence/` and are not committed.
- Running Release app settings and native background import sheet were exercised through Computer Use. Import/remove/undo/relaunch passed. macOS denied SwiftShot Screen Recording during actual capture. A request to enable it remains pending; access was not changed without authorization.
- Remaining checks: real region/window/fullscreen freeze and OCR flow; capture-to-overlay timing (particularly many visible windows); live crop/annotation/redaction/Copy→Save; actual global shortcut delivery; drag/drop and high-level overlay import sheet; focus restoration; display hotplug and mixed-scale/negative-origin hardware. Multi-display/Spaces checks are not claimed from unit fixtures.

Lead decision: **Not Done** until the pending runtime acceptance checks pass. The implementation and runnable artifact are ready for that verification.

- Final `./script/build_and_run.sh --verify` passed. `dist/SwiftShot.app` launched successfully, strict codesign verification passed, and the bundle contains no XCTest plug-ins. Production signature retains `adhoc,runtime`.
- Final slider-only polish was followed by a passing visual test and renewed screenshot inspection (`build/visual-final.log`).
