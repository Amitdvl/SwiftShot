# SwiftShot performance evidence protocol

This protocol measures the six-milestone goal without confusing renderer speed, software readiness, physical presentation, and successful paste. A passing unit test, a cached PNG, an `onAppear`, or a completed task does not prove an end-to-end target.

## Evidence classes

1. **Deterministic correctness tests:** validate metric math, capture/render behavior, and coordination. They do not prove latency, actual screen permission behavior, or visible UI readiness.
2. **Controlled renderer microbenchmarks:** real Release rendering/PNG encoding of a deterministic 3840 × 2160 synthetic card. They exclude capture, selection, clipboard, paste, save, OCR, and history UI. `renderer-first-use` means a new renderer instance in an already-running process, **not a cold app launch**. `renderer-reuse` repeats the same immutable request, including its first call, and measures cache reuse analogous to Copy → Save.
3. **Live software workflow timings:** mark real event boundaries in the app. The recorder never supplies missing marks, assumes paste happened, or substitutes timer completion for readiness.
4. **Observed interaction evidence:** verify a usable selector/editor frame and the resulting paste/save/OCR/history operation. A Core Animation completion callback is a software proxy, not proof that pixels reached the physical display. Use a display-rate recording or external camera when evaluating interaction/frame latency. Record that evidence separately; never insert a guessed physical timestamp into the software report.

## Reproducible run matrix

Use the same machine, OS, Release optimization/signing configuration, display arrangement/scaling/refresh rate, appearance, source fixture, export settings, and foreground paste destination for before/after runs. Record the source revisions and neutral instrumentation patch in the evidence index. Keep debug instrumentation and profilers out of primary acceptance runs unless both builds use exactly the same setup.

Run at least 30 successful samples **per build, workflow and condition**, retaining failures and cancellations as outcomes. Do not silently retry failed samples or discard slow ones. Run the following conditions separately:

| Dimension | Conditions and interpretation |
| --- | --- |
| Process state | Cold: quit/relaunch and exercise the first workflow, once per launch. Resident: app remains running; do not recreate the process between samples. |
| Desktop load | Idle desktop; controlled busy desktop with the same foreground/background applications and reproducible work. Record the workload definition without private window titles or content. |
| Displays | One display; multiple displays with recorded resolution, scale, placement and refresh rate. If unavailable, mark multidisplay evidence unverified. |
| Pixels and edits | Native 3840 × 2160 or 4096 × 2160 ordinary-edited copy gate; separately raw, redacted, smaller-share, P3, transparency and high-bit-depth cases. Do not pool them. |
| Workflows | Region → paste; live window → arrow → paste; redact → save; OCR; history reuse → paste. |

Counterbalance before/after order where practical. Make the source fixture and action sequence identical, including whether the capture is discarded/saved between runs. Record clicks/keystrokes/drags and corrections from the start action through the verified result. A correction is an action required to repair selection, annotation, text placement, mode, or export choice; it is a subset of actions. Omitted action instrumentation is exported as `null`, not fabricated zero.

Do not claim busy-desktop, multidisplay, Spaces/fullscreen, HDR, permissions, sleep/wake or competitor checks from a synthetic renderer test. Compare macOS Screenshot and CleanShot/Shottr only when available; do not install, purchase or invent competitor results as part of evidence collection.

## Recorder integration contract

`WorkflowPerformance.shared` is a main-actor, bounded in-memory recorder. Defaults retain 512 completed runs and 16 active runs. Dropped records and incomplete active runs are reported. No timer, polling, capture, OCR, screenshot content, text, document IDs, window titles, account details or paths are recorded. Export is explicit: `try recorder.export(to: chosenURL)`; it does not create parent directories or write automatically.

Set `defaultContext` explicitly for a benchmark batch. Defaults remain `unspecified`; the recorder does not guess cold/resident state or desktop load. Context supports `launch`, `desktop`, `displayCount`, input/output `PixelSize`, `interaction` (`human`, `automatedUI`, `controlledHarness`, `unspecified`) and `content` (`raw`, `ordinaryEdited`, `complexEdited`, `unspecified`). Production collection may remain unspecified and cannot pass an acceptance gate.

```swift
let recorder = WorkflowPerformance.shared
recorder.defaultContext = .init(
    launch: .resident, desktop: .idle, displayCount: 1,
    inputPixels: .init(width: 3840, height: 2160),
    outputPixels: .init(width: 3840, height: 2160),
    interaction: .human, content: .ordinaryEdited)
let run = recorder.begin(workflow: .regionToPaste)
recorder.mark(.captureRequested, for: run)
// Real interaction/readiness callbacks only:
recorder.mark(.selectorReady, for: run)
recorder.mark(.selectionCommitted, for: run)
recorder.mark(.editorReady, for: run)
recorder.action(for: run)
recorder.mark(.copyRequested, for: run)
recorder.mark(.clipboardReady, for: run)
// Mark this only after an actual paste has been checked in the destination:
recorder.mark(.pasteVerified, for: run)
recorder.finish(run, outcome: .success)
```

Use explicit run IDs across asynchronous capture, renderer, clipboard, save and history operations. `mark` without an ID uses the newest active run and becomes a no-op when none exists; that convenience is unsuitable for overlapping operations. `update(workflow:context:for:)` may classify the actual workflow or update measured output dimensions without resetting its start time. `reset()` drops all retained evidence and should be called only at an explicit batch/privacy boundary after any wanted export.

### Required hooks (same boundaries before and after)

| Hook | Real boundary; never substitute |
| --- | --- |
| `captureRequested` | Accepted shortcut/menu action, **before** recovery waits, screen enumeration/capture, or overlay construction. Cold process-launch latency, if separately measured, must include launch externally. |
| `selectorReady` | Frozen pixels plus input handlers are installed and the selector has completed its first software presentation. Do not mark merely on return from `freeze`, `present`, or SwiftUI `onAppear`. Window mode is live, not a frozen selector and has no 150 ms frozen-selector gate. |
| `selectionCommitted` | Pointer-up or keyboard confirmation that commits the selected native-pixel region/window. |
| `editorReady` | Attached editor/toolbar is interactive after the first appropriate layout/presentation. A model assignment alone is not enough. |
| `copyRequested` | Accepted Copy action, before any render, recovery wait, encoding or clipboard work. |
| `clipboardReady` | Successful final clipboard ownership/data commit. Verify PNG/image data are immediately readable. A toast or queued work item is not this event. |
| `saveRequested` / `saveComplete` | Accepted Save action / requested PNG successfully written and reported complete; include required coordination waits. Track optional housekeeping separately if it continues after the visible save result. |
| `ocrRequested` / `ocrComplete` | Actual OCR action / recognition result available (and committed if the workflow promises copied text). Do not record recognized text. |
| `historyRequested` / `historyReady` | User opens/reuses a history entry / its recovered editor becomes interactive, including disk recovery and thumbnail/index work as applicable. |
| `pasteVerified` | The destination app actually received the correct image. This is a manual/automation verification hook, not an automatic consequence of `clipboardReady`. |
| `finish` | Verified end of the selected workflow, or explicit `.failed`/`.canceled`. Success without a required span remains incomplete evidence. |

For fast Copy → Save reuse, run the same document ID/revision/background/output options without changing edits, then separately alter each invalidating input. The renderer cache tests cover correctness; live spans cover the application cost. Retained editable originals are not security evidence for redacted export pixels.

### Opt-in critical-path pilot trace

Diagnostic exports also contain `captureLatencyTrace`: fixed stage names, monotonic offsets, the diagnostic run UUID, selector/editor classification, and a zero-based surface ordinal. The trace is explicitly armed with the diagnostic run, does not sample CPU/RSS per event, is not observed by SwiftUI, and retains at most 32 runs with 256 events each. Dropped runs/events are explicit. Nil/stale/ended callbacks do not read the clock or attach to a later run. Both instrumented builds must use identical helper/receipt/diagnostic code and corresponding neutral hooks; never backport behavior fixes into the baseline.

Use this trace for attribution before optimization: scroll drain, recovery ownership handoff, permission preflight, native panel/hosting attachment and ordering, first layout/display submission, transaction completion and main-actor receipt delivery. The existing `Frozen` log excludes permission preflight, so subtracting it from the workflow span does not isolate UI time. The existing `shortcutToSelector` workflow mark starts inside `AppState.capture`, after the Carbon callback's main-queue and Task handoffs. It is a lower bound on accepted-global-shortcut response, not the full callback-to-selector interval. Trace `shortcutReceived` → the final selector `receiptDelivered` is the additional software gate boundary for global-shortcut runs; missing upstream trace cannot prove the full shortcut target. Neither timestamp measures physical key-switch or display-photon latency.

Trace offsets and workflow offsets have separate start instants: subtract only within the same trace/report clock origin. Live Window capture can record two selection callback sites (initial click and delivery of acquired pixels); use the first committed event for end-to-end click cost. Do not replace existing readiness callbacks with construction, `onAppear`, or a timer, and do not use an eight-run exploratory pilot as the 30-sample acceptance series.

Window acquisition additionally carries the initiating optional diagnostic UUID into the capture provider. Its seven phase marks contain no window/display identity or content:

| Interval | Included work |
| --- | --- |
| `windowCaptureStarted` → `windowMetadataStarted` | Permission and display-layout preflight |
| `windowMetadataStarted` → `windowMetadataResolved` | Shareable-content query, lookup, optional current-process fallback and await resumption |
| `windowMetadataResolved` → `windowImageRequestStarted` | Identity/geometry checks, filter construction, dimensions and memory reservation |
| `windowImageRequestStarted` → `windowImageCallbackReceived` | Inline configuration construction and SCK request through its completion callback—not isolated GPU or CPU time |
| `windowImageCallbackReceived` → `windowImageRequestReturned` | Callback bridge and resumption on the caller's actor; the callback mark precedes continuation resumption |
| `windowImageRequestReturned` → `windowResultPrepared` | Cancellation, pixel/layout/identity checks, crop and result construction |

The remaining result-return/caller work still belongs to the full selection→editor interval. A returned image is not yet validated; a prepared result is not editor readiness. Failed/canceled calls leave genuinely missing endpoints. Require an unambiguous ordered acquisition sequence and zero dropped events; do not pair repeated stages from different attempts. The new marks add measurement overhead: label the instrumented pilot separately and do not treat an instrumentation build as an optimization. The baseline helper may share the phase enum, but the old eager-window baseline has no corresponding capture-at-click operation; do not backport the new capture behavior to manufacture matching internal phases.

## Controlled baseline harness

The preserved pre-change tree is `build/goal-baseline-source`. Preserve its original snapshot and test log. Mirror **only** the exact `WorkflowPerformance.swift` and `ControlledRenderBenchmarkTests.swift` files for the microbenchmark, and any separately reviewed, behavior-neutral live hooks. Do not backport render/capture fixes, optimization changes, new dependencies or UI behavior. Save an instrumentation-only diff and compare file hashes so fixtures and sampling code are identical.

The lead regenerates/builds both projects with the same Release flags and separate derived-data/result-bundle locations. Only the lead runs test hosts, shared UI, capture permissions, installs, display changes or app launches. The worker must not start parallel test hosts.

Select these tests explicitly using the repository's verified `xcodebuild test` invocation:

```text
SwiftShotTests/ControlledRenderBenchmarkTests/testNative4KFirstUseRenderer
SwiftShotTests/ControlledRenderBenchmarkTests/testNative4KRepeatedRenderer
```

Each test uses three scenarios (`raw-4k`, `ordinary-edited-4k`, `redacted-4k`) and 30 samples by default. `SWIFTSHOT_BENCHMARK_SAMPLES=1` can provide an explicitly labeled smoke run if the test runner receives that environment variable; such a run is not statistical acceptance evidence. The harness has no automatic skips, timing-test weakening, or acceptance-target overrides. It emits `SWIFTSHOT_BENCHMARK {JSON}` lines and validates output dimensions/nonempty PNG data. Keep full logs and the real test exit status; do not mistake a successful `tail`/report command for a passing test host.

The harness deliberately uses baseline-era `RenderRequest(image:edits:backgroundURL:)` and `ImageRenderer.render` APIs. Its resource sampler is neutral instrumentation. No screenshot, real clipboard content, OCR string or destination path enters the sample record.

## Compare exported evidence

The reporter accepts explicit workflow JSON exports and/or controlled benchmark logs. It keeps renderer and workflow groups separate, deduplicates cumulative workflow exports by run ID, and reports missing spans, failures, cancellations, dropped records and unfinished active runs.

```sh
python3 script/benchmark_report.py \
  --baseline build/goal/baseline-render-benchmark.log build/goal/baseline-workflows.json \
  --current build/goal/current-render-benchmark.log build/goal/current-workflows.json \
  --output build/goal/benchmark-comparison.md
```

Omit absent files rather than creating empty artifacts. The reporter fails on missing/invalid input or logs without samples. It does not silently turn a crashed test host into an empty successful comparison. A renderer-only comparison must remain labeled renderer-only.

Median is the middle observation, averaging the middle pair for even counts. p95 uses nearest rank (`ceil(0.95 × n)`). Report n with every condition. Failed and canceled runs do not lower successful-latency percentiles: they remain explicit counts and all raw metadata remain in the source exports. Fewer than 30 samples or missing/failed/dropped evidence prevents a software gate claim.

Resident software targets are 150 ms shortcut → frozen selector; 50 ms selection → editor; 200 ms Copy → readable clipboard for ordinary-edited native 4K. Copy gate eligibility requires explicit native 3840/4096 × 2160 input/output dimensions and ordinary-edited content. Smaller-share, raw, different-size, cold, unknown-condition, and renderer-only samples do not satisfy that gate. A `withinSoftwareTarget` result still needs actual interaction/readiness and paste verification; it is not completion of the six-milestone goal.

## CPU, memory and display-rate checks

The recorder uses `getrusage` for process user+system CPU and process-lifetime high-water RSS, and `task_info` for current RSS. Values are `null` if OS sampling fails. Per-run CPU covers the whole process, including overlapping/background work; CPU percent may exceed 100% across cores. Begin/end RSS is **not** the run's true peak. Native Instruments/Activity Monitor or an external bounded sampler is required for peak working-set, frame rate, and attribution.

For idle CPU, begin an `.idleObservation` run, leave SwiftShot resident with no editor/capture work for a fixed recorded interval (at least 60 seconds), and finish/export. This creates no timer or continuous capture in SwiftShot. Repeat idle, open-editor-idle, and post-session states. Record the actual CPU fraction; do not invent a numerical definition of “negligible.”

For memory, record a long repeated-session series (at least 100 capture/edit/copy/cancel/reopen cycles), native and smaller exports, cache invalidations, memory-pressure behavior and post-idle RSS. Evaluate trends and retained ownership rather than a single successful sample or process-lifetime peak. A bounded recorder/cache is not proof that all app/session allocations are bounded.

For display-rate interaction, exercise slow/fast selection drag, resize handles, magnifier, annotation motion and pin resizing at each available display refresh rate. Capture actual frame cadence/input responsiveness with a clearly identified observation method. Any unavailable hardware, access, comparator or physical-presentation check remains **unverified** in `GOAL_PROGRESS.md`; it must not be declared Done.
