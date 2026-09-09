<img src="docs/assets/swiftshot-icon.png" width="128" height="128" alt="SwiftShot app icon" />

# SwiftShot

Capture, annotate, and copy screenshots from your Mac’s menu bar.

Select a region on a frozen screen, capture a window or display, or copy text from your screen. Edit beside the capture, then copy the result or save a PNG. Native Swift and SwiftUI. No account or cloud service required.

## Capture to clipboard

Press **⌘⇧2**, select a region, and edit with the attached toolbar:

- **Explain:** add arrows, rectangles, and text.
- **Hide details:** crop or cover sensitive areas with solid redactions.
- **Style:** add a background, padding, rounded corners, and a shadow.
- **Export:** copy with **⌘C** or save with **⌘S**. PNGs preserve native screenshot resolution; backgrounds expand the canvas.

Use **Copy Text from Screen** in the menu bar for OCR, or **Reopen Last Capture** to keep editing. Enable window, fullscreen, and OCR keyboard shortcuts in **Settings → Shortcuts**.

## Build and run

Requires **macOS 14+**, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). There is no packaged release yet.

```sh
git clone https://github.com/Amitdvl/SwiftShot.git
cd SwiftShot
brew install xcodegen
./script/build_and_run.sh
```

The script builds and launches the app. Grant SwiftShot Screen Recording access in **System Settings → Privacy & Security**, then retry the capture. Local ad-hoc builds may need permission again after rebuilding.

## Your captures stay local

Captures and edits are stored on your Mac for recovery after relaunch. Closing the editor does not delete them.

**Recovery retains original pixels, including content behind crops and redactions.** Exported PNGs contain only the flattened result. Recovery files live in `~/Library/Application Support/SwiftShot/Recovery`.

## In development

Quick Copy, searchable history, pinned captures, scrolling capture, workflow presets, and Apple Shortcuts integration are being tested locally and are not yet in the published source.

[Report a bug or request a feature](https://github.com/Amitdvl/SwiftShot/issues) · [MIT license](LICENSE)
