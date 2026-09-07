<img width="128" height="128" alt="SwiftShot icon" src="https://github.com/user-attachments/assets/9ed7fb63-6703-4cb4-934d-d9a171c2d9cd" />

# SwiftShot

A native macOS screenshot tool with a frozen-screen selection canvas and compact editing toolbar.

## Capture and edit

Use the menu bar or **⌘⇧2** to capture a region. SwiftShot acquires display images before showing the selection overlay. Drag a region, click a window in Window mode, or capture the display under the pointer in Fullscreen mode. A selection stays on its starting display; spanning windows are clipped to that display.

The attached toolbar provides **Copy, Save, Background, Annotate, Crop, and More**. Draw arrows, rectangles, text, or solid redactions; adjust the crop; and undo or redo edits. Copy leaves the capture open so you can save it too. Save writes a unique PNG and closes the unchanged editor after success. Escape dismisses the active tool/panel before closing the editor. Use ⌘C, ⌘S, ⌘Z, and ⇧⌘Z while editing; text fields retain their native shortcuts.

**Copy Text from Screen** in the menu bar recognizes a selected region with Apple Vision; More offers a retry if recognition fails. **Reopen Last Capture** brings the latest capture back for editing or saving. Optional **Immediate Copy** in Settings copies and closes after selection.

## Backgrounds and sharpness

Import multiple images or drop them into the background picker. Imports are validated and copied into SwiftShot's Application Support folder with stable identifiers. Remove a background with Undo Removal; hidden bundled backgrounds can be restored from the picker menu. Original files are never deleted. Adjust padding, corner radius, and shadow beside the capture.

The original screenshot remains immutable. PNG exports keep native screenshot pixel dimensions and integer placement, expanding the canvas for backgrounds instead of shrinking the screenshot. Background images scale to fill that canvas. Redactions are flattened as opaque pixels. Exports are limited to 64 million pixels to bound memory use.

## Recovery and privacy

Failed saves retain the capture and show Retry and Choose Folder. Captures and edits are also stored locally in `~/Library/Application Support/SwiftShot/Recovery` for recovery after relaunch. Unsaved captures remain until explicitly discarded; older saved recovery copies are pruned. Closing the overlay does not discard a capture. This local recovery storage contains screenshot content, including original pixels before crop/redaction; exported PNGs contain only the flattened result.

No accounts or cloud service are required. SwiftShot needs macOS Screen Recording permission. If denied, enable SwiftShot in **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen it if macOS requests that.

## Shortcuts

| Action | Default binding | Initially enabled |
| --- | --- | --- |
| Region | ⌘⇧2 | Yes |
| Fullscreen | ⌘⇧F | No |
| Window | ⌘⇧D | No |
| OCR region | ⌘⇧O | No |

Enable bindings in Settings → Shortcuts. Registration conflicts are displayed there. Existing save-folder preferences are preserved, and the previous mislabeled default modifier combination is migrated.

## Build and run

Requires macOS 14+, Xcode, and XcodeGen.

```sh
brew install xcodegen
./script/build_and_run.sh
```

The script generates the Xcode project, builds Release, packages `dist/SwiftShot.app`, and launches it. Use `--build` to package without launching, `--verify` to check launch, or `--debug`, `--logs`, and `--telemetry` for diagnostics. Codex's Run action invokes the same script. Build logs remain under `build/`.

For the optimized native test suite, use a separate test-host build directory. The command-line hardened-runtime override permits Xcode's ad-hoc signed XCTest injection; it does not change the production Release configuration.

```sh
xcodegen generate
xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot \
  -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_HARDENED_RUNTIME=NO \
  -destination platform=macOS -derivedDataPath build/tests test
```

See [REBUILD_PROGRESS.md](REBUILD_PROGRESS.md) for verification evidence and outstanding hardware/runtime checks.
