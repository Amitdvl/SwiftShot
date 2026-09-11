<img src="docs/assets/swiftshot-icon.png" width="128" height="128" alt="SwiftShot app icon" />

# SwiftShot

Capture, annotate, and copy screenshots from your Mac’s menu bar.

Select a region on a frozen screen, capture a window or display, or copy text from your screen. Edit beside the capture, then copy the result or save a PNG. Native Swift and SwiftUI. No account or cloud service required.

Visible SwiftShot windows and panels are part of display and region captures, so you can document the tool itself as you work.

## Capture to clipboard

Press **⌘⇧2**, select a region, and edit with the attached toolbar:

- **Explain:** add arrows, rectangles, text, highlights, numbered steps, and spotlights. Select annotations to move, resize, or edit them.
- **Hide details:** crop or cover sensitive areas with solid redactions.
- **Style:** add a background, padding, rounded corners, and a shadow.
- **Export:** copy with **⌘C** or save with **⌘S**. Native-size PNG is the default; use Smaller Share when you want a smaller image. Backgrounds expand the canvas.

Use **Copy Text from Screen** in the menu bar for OCR, or **Reopen Last Capture** to keep editing. Enable window, fullscreen, and OCR keyboard shortcuts in **Settings → Shortcuts**.

For the shortest path, **Quick Copy Region** copies your selection before restoring focus. Its optional thumbnail lets you edit, save, pin, or drag the image. Raw output is the default; styling and named presets are explicit choices.

## Keep working with your captures

- Reopen captures from local history, search indexed text, and manage pins and retention.
- Keep a resizable capture floating on screen, or combine captures vertically or side by side.
- Recapture the last region or use the available Apple Shortcuts actions.
- Use manual or automatic scrolling capture. If content changes or overlap cannot be verified, SwiftShot stops and warns about an incomplete result; inspect it before sharing.

## Build and run

Requires **macOS 14+**, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The local install script also requires an **Apple Development signing certificate** in Keychain. There is no publicly distributed, notarized download yet.

```sh
git clone https://github.com/Amitdvl/SwiftShot.git
cd SwiftShot
brew install xcodegen
./script/build_and_run.sh
```

The script builds a signed Release app, verifies update compatibility, lets the previous app preserve its captures before quitting, installs, and launches it. Grant SwiftShot Screen Recording access in **System Settings → Privacy & Security**, then retry the capture.

## Your captures stay local

Captures and edits are stored on your Mac for recovery after relaunch. Closing the editor does not delete them.

Private captures do not write recovery files or a local OCR index. Explicitly saving or dragging a private capture still exports the image you requested. Text indexing can be disabled separately.

**Recovery retains original pixels, including content behind crops and redactions.** Exported PNGs contain only the flattened result. Recovery files live in `~/Library/Application Support/SwiftShot/Recovery`.

## Verification and limits

See [release verification](docs/RELEASE_STATUS.md) for the latest local test and smoke results, including unverified hardware/OS cases. OCR is a supporting feature: recognition remains on-device, but first-use latency and difficult text can vary. Scrolling capture is bounded and conservative rather than a guarantee for every dynamic page.

[Report a bug or request a feature](https://github.com/Amitdvl/SwiftShot/issues) · [MIT license](LICENSE)
