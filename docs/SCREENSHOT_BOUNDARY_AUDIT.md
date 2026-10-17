# Screenshot boundary audit

2026-10-17 · Implementation: `fd84c6e` (isolated for publication from `b7ce3d9`) · Original presentation: `7579599`.

The editor now reserves a workspace beside the toolbox and above the toolbar, even when the toolbox is closed. A persistent black-and-white edge identifies the PNG output rectangle. Raw transparency uses a checkerboard; crop mode shows the complete source dimmed outside the crop and exposes resize handles. Editor chrome never enters the bitmap renderer. Toolbar dragging stays on its bottom rail.

## Reproduction and regression evidence

The original editor removed its selection outline when a selection committed. Its inspector fallback explicitly allowed overlap with a full-screen capture. A real hosted-view regression failed against the original source because no persistent output-boundary view existed. An isolated mutation retaining boundary geometry but removing the painted strokes was rejected by 84 contrast assertions.

The live crop check also exposed floating-point round-trip noise at fractional preview scales: a 1200×800 crop became 1200×801 when converted through points. A new regression reproduced `(1080,739,1200,801)` instead of `(1080,740,1200,800)`. The transform now snaps only numerical noise within 0.0000001 pixel of an integer before its existing outward rounding.

## Automated checks

- Original checkout optimized Debug suite on Xcode 27: **439 tests passed, zero failures**, including actual hosted AppKit control/gesture tests.
- Isolated publication suite on Xcode 27: **434 tests, 433 passed, one failure** in unchanged `AsyncWorkflowTests.testVisionRecognizesRenderedTextFixture`. Vision reports missing E5/ANE model resources with error code 13. All boundary/layout/export checks passed. The publication diff does not change OCR; the initial checkout contains a separate unpublished OCR fallback. Pinned macOS 26 CI is the publication gate.
- Python script tests: **17 passed**.
- Boundary raster tests cover every edge, white/black/busy/transparent content, light/dark appearance and toolbox open/closed. They require both light and dark edge pixels.
- Hosted-view tests require stationary output bounds across toolbox toggles and disjoint image/control frames. Crop, style, annotation selection, undo and redo retain their expected source coordinates.
- Native event tests exercise drawing with the toolbox open, text focus, compact inspector scrolling, selected-annotation deletion and text/status row changes.
- Copy/Save keyboard callbacks pass through the real renderer and PNG decoder. Independent literal crop offsets compare every output pixel; source identity, edits and undo history stay unchanged by presentation toggles.
- Geometry checks cover 640×480, 800×480, 1280×800 and 1920×1080; top insets 14/40; small, 4K, tall and wide images; aspect preservation, containment and dragged-toolbar limits.
- Existing renderer, annotation, floating capture, history, combine, scrolling and export tests remain in the complete suite.

## Running-app checks

Results below are recorded separately from shared-component and automated coverage. Live evidence remains local under `build/boundary-evidence/`; private desktop captures are not published.

| Operation | Observation / evidence | Result |
| --- | --- | --- |
| Region selection → editor | 600×400-point drag produced 1200×800 native pixels; all four output edges visible on neutral workspace | Passed |
| Toolbox open/close | Actual annotation toolbox appears to the right; preview and output frame remain stationary | Passed |
| Arrow drawing with toolbox open | Real drag lands at intended image points; toolbox does not intercept image input | Passed |
| Undo/redo | Actual keyboard undo/redo restores the arrow without changing output framing | Passed |
| Crop inspect/resize/exit | Full source shown dimmed; handles remain visible; resized output is reframed with persistent edge | Passed; final running Release shows 1200×800 after fractional-scale crop inspection |
| Rectangle, redact, highlight, steps, spotlight | Actual tool shortcuts and gestures place each annotation within the image while the toolbox remains beside it | Passed |
| Text creation, selection and nudging | Native text field accepts text; commit, Select and arrow-key nudge work with persistent output frame | Passed |
| Background and padding | Blue background and 144 px padding expand 1800×1000 content to 2088×1288; frame identifies the complete styled output | Passed |
| Toolbar dragging | Dragging toward image clamps to bottom rail; output framing stays stationary | Passed |
| Save edited image | Actual Save writes 2088×1288 PNG; inspected image includes edits and style without boundary strokes, crop handles or tool controls | Passed |
| Window capture | Live window selector outline, committed editor and open annotation toolbox all remain readable; styled output 2564×1872 | Passed |
| Pin → resize → Edit | Pin hover controls remain within its frame; resizing clamps at display edge (408×303 points); Edit returns to full editor with persistent output boundary | Passed |
| Copy from reopened pin | Actual Copy writes 2564×1872 clipboard PNG, matching the editor dimensions | Passed |
| Fullscreen capture | Native 2940×1912 content plus workflow padding produces 3132×2104; all four edges stay visible and stationary when toolbox opens | Passed |
| OCR selection | Actual title-bar region recognized and copied 11 characters; successful OCR exits to desktop without opening an editor | Passed |
| Small capture near screen edge | Drag from (1,1) to (21,21) produces 40×40 source; styled 328×328 output stays distinct with toolbox open; crop label remains 40×40 | Passed |
| Quick Copy | 300×200-point region writes a 600×400 clipboard PNG and exits without editor chrome | Passed |
| Smaller Share / drag export | Controls inspected in More inspector; renderer/export regression coverage passed; no live destination drag or Smaller Share action performed | Automated only |
| Scrolling capture / recapture | Menu-only entry points could not be operated reliably through native accessibility, Computer Use or Peekaboo on this OS; shared editor and existing flow tests pass | Live check unavailable |
| History / combine reopening | No entry exposed in current status-menu UI; shared editor and existing history/combine tests pass | Automated only |

The temporary Fullscreen and OCR shortcut toggles were restored to their initial disabled state. Region, Window and Quick Copy shortcuts remain enabled as initially found. Test-created Settings windows were closed. Local test images and logs remain ignored; none are published.

## Environment and limits

Live environment: Apple silicon, macOS 27.0.1 (26A434), signed Apple Development Release installed at `/Applications/SwiftShot.app`; one 1470×956-point Retina display, 2× capture pixels. Pinned CI uses Xcode 26.6; only Xcode 27.0 (27A266a) and XcodeGen 2.46.0 are installed locally. The equivalent complete XCTest command ran on Xcode 27; this does not claim local execution with the pinned compiler.

Other physical display/scaling configurations, mixed-scale multiple displays, Intel hardware and older macOS runtimes were unavailable. Their geometry is covered synthetically, not claimed as live verification. Editor zoom/pan and free window resizing are not exposed; the editor panel follows a fixed display and cancels on display configuration changes. Pin resizing is a separate operation.

All image-editor entry paths use `CaptureOverlayView`: region, window, fullscreen, recapture, scrolling result and reopening via history, pins or combine. Successful OCR and Quick Copy exit directly; OCR error recovery can retain an editor. Shared use and automated coverage establish the presentation contract; they do not substitute for an explicitly recorded live operation.

## Publication isolation and artifact hygiene

The initial local branch included unrelated unpublished OCR changes. The UI implementation was cherry-picked onto the remote default branch in an isolated worktree so publication excludes those changes. The initial 439-test result includes that local OCR coverage; the isolated publication result is recorded above. The running signed Release used for live checks contains the same UI implementation; its unrelated OCR implementation was left intact locally.

All generated application copies are beneath project-local `.noindex` derived-data directories. The active deployed application is `/Applications/SwiftShot.app`; no `dist/SwiftShot.app` or indexable generated app was left behind. Existing unrelated worktrees and their products were preserved.
