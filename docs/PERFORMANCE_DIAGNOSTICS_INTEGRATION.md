# Opt-in performance diagnostics

`PerformanceDiagnostics.shared` owns a separate, single-active-run `WorkflowPerformance` recorder. It starts disabled on every process launch. Opening the panel does not enable recording or begin a run. No timers, polling, screenshot/OCR work, automatic files or durable preferences are added.

The panel allows an operator to choose the workflow and process/load/display/interaction/content conditions, enable instrumentation, and explicitly begin a run. Conditions are frozen at begin. Live hooks may subsequently fill measured input/output pixel dimensions. A second begin is refused until the first run is finished, failed, canceled or disabled.

## Lead integration API

```swift
let diagnostics = PerformanceDiagnostics.shared

// Menu action, not an automatic startup window:
diagnostics.showWindow()
// When a known target must stay uncovered, pass its Cocoa global-screen frame:
diagnostics.showWindow(avoiding: targetFrame)

// The panel's user-controlled toggle and Begin Run button normally do these:
diagnostics.setEnabled(true)
let run = diagnostics.beginRun() // UUID?; nil while disabled or already active

// Capture this optional ID at the actual action boundary, before suspension.
let diagnosticID = diagnostics.activeRunID
diagnostics.mark(.captureRequested, for: diagnosticID)

// Always hide known diagnostic panels before capture, even if recording is off.
diagnostics.setCaptureHidden(true)
// Perform actual capture and readiness work here.
diagnostics.mark(.selectorReady, for: diagnosticID)
diagnostics.mark(.selectionCommitted, for: diagnosticID)
diagnostics.mark(.editorReady, for: diagnosticID)
diagnostics.updatePixels(input: .init(width: inputWidth, height: inputHeight),
                         output: .init(width: outputWidth, height: outputHeight),
                         for: diagnosticID)

diagnostics.mark(.copyRequested, for: diagnosticID)
// Only after successful, immediately readable clipboard ownership/data commit:
diagnostics.mark(.clipboardReady, for: diagnosticID)

// Restore only when it is safe to display a utility panel again.
diagnostics.setCaptureHidden(false)

// Real observed workflow actions only; a correction also increments actions.
diagnostics.action(for: diagnosticID)
diagnostics.action(correction: true, for: diagnosticID)

// The explicit UI button calls this only after the operator checks the image
// in its destination. Automatic mark(.pasteVerified, for: ...) always refuses.
diagnostics.verifyPaste()

// Usually the explicit panel buttons own finish. Never finish at clipboardReady
// if the selected workflow continues through actual destination paste.
diagnostics.finish(outcome: .success, for: diagnosticID)
// Or .failed / .canceled for the actual terminal outcome.

diagnostics.exportWithSavePanel() // Explicit JSON export; native overwrite UI.
diagnostics.hideWindow()          // Hides only; does not finish the current run.
diagnostics.clearResults()        // Explicit memory-only clear, refused mid-run.
```

The no-ID `mark`, `action`, `updatePixels` and `finish` conveniences target the current run and are only suitable for synchronous user actions. The explicit `for: UUID?` overloads reject both nil and stale IDs. Passing a captured nil from a disabled or not-yet-armed operation therefore cannot contaminate a newer run. `beginRun()` does not mark `captureRequested`, `historyRequested`, or any other workflow stage.

The lead must remove or guard older direct `WorkflowPerformance.shared.begin` production hooks. The wrapper cannot disable an unrelated caller of the underlying recorder. Test/microbenchmark-local recorders remain independent.

Use the true boundaries in [BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md), including a scoped native layout/presentation readiness probe. A SwiftUI `onAppear`, a model assignment, a queued save, or a toast is not a replacement for those boundaries. Async capture/export/OCR/history callbacks must retain the initiating diagnostic ID.

## Observation and reporting limits

- **Paste is explicit.** The verification button records when the operator presses it after checking the destination. It includes the operator's verification delay. It is not an exact earlier paste timestamp, a clipboard-readability check, or physical-display proof. Automatic `mark(.pasteVerified)` is rejected.
- **Conditions are labels, not sensors.** Cold/resident and busy/idle are operator-supplied. Relaunch between cold samples. Cold process-launch latency is not included in this recorder and needs external evidence.
- **Armed time differs from workflow spans.** CPU/RSS and total duration cover Begin Run through Finish, including diagnostic interaction and concurrent process work. Span endpoints use the actual hooks. No per-workflow CPU attribution or true per-run peak RSS is claimed.
- **Actions are observed counts.** Use hooks or the manual `+1 Action` / `+1 Correction` buttons without double-counting. Corrections are a subset of actions. If no action is entered, both fields remain null. Do not count the diagnostics bookkeeping buttons as workflow actions.
- **Missing evidence stays missing.** Explicit Success can still have missing spans; JSON retains that outcome and the missing-stage counts. No endpoints are supplied or backdated. Active runs are exported as unfinished counts, not completed invented samples.
- **Acceptance remains external.** The panel does not mark any milestone Done, infer physical presentation, claim multidisplay coverage from one display, or turn fewer than 30 comparable samples into a passing gate.

Reports use the existing metadata-only schema and therefore contain no screenshot/image bytes, OCR text, capture document IDs, window titles, paths, URLs or free-form input. A chosen export destination is used solely for that explicit JSON write and is not included in the report. The save panel snapshots the report when Export is pressed; later measurements are not silently merged into that pending export.

## Ownership and bounds

The shared wrapper permits only one active run and retains at most the recorder's default 512 completed runs; dropped counts remain visible. Each run has one event per finite stage enum and action/correction counts cap at 1,000,000. Invalid/nonpositive pixel metadata and display counts outside 1–16 are refused. Pixel metadata is numeric only and does not allocate an image.

The utility panel is constructed only when explicitly shown and uses nonactivating native window behavior. `setCaptureHidden` orders out its owned panel and cancels an uncommitted diagnostics save chooser; it does not enumerate windows, activate another app, or discard the active run. An export cannot open while capture-hidden. Placement checks all supplied display-visible frames and refuses to show if no safe corner avoids a supplied capture rectangle. The capture integration must still hide the panel before all full-screen/window/region acquisition, even if diagnostics are disabled. Closing the panel releases its view/window ownership but keeps its recorder; disabling diagnostics cancels an active run once and stops future sampling. Clearing results affects memory only.

Run tests through the lead-owned test host: `SwiftShotTests/PerformanceDiagnosticsTests`. Real panel placement, picker/export interactions, source-window focus, safe capture hiding and manual destination verification still require a real macOS runtime pass; deterministic tests alone do not verify those gestures.
