<img src="docs/assets/swiftshot-icon.png" width="128" height="128" alt="SwiftShot app icon" />

# SwiftShot

Capture, annotate, and copy screenshots from your Mac’s menu bar.

Select a region on a frozen screen, capture a window or display, or copy text from your screen. Edit beside the capture, then copy the result or save a PNG. Native Swift and SwiftUI. No account or cloud service required.

Visible SwiftShot windows and panels are part of ordinary display and region captures, so you can document the tool itself as you work. The compact Scrolling Capture HUD is excluded from its own stream.
Window capture also recognizes application-owned menus and dropdowns while ignoring compositor chrome such as the Dock and menu bar. Pinning is an explicit action in the capture toolbar; the recent thumbnail can be enabled separately in Settings.

## Capture to clipboard

Press **⌘⇧2**, select a region, and edit with the attached toolbar:

- **Explain:** add arrows, rectangles, text, highlights, numbered steps, and spotlights. Select annotations to move, resize, or edit them.
- **Hide details:** crop or cover sensitive areas with solid redactions.
- **Style:** add a background, padding, rounded corners, and a shadow.
- **Export:** copy with **⌘C** or save with **⌘S**. Native-size PNG is the default; use Smaller Share when you want a smaller image. Backgrounds expand the canvas.

Use **Copy Text from Screen** in the menu bar for OCR. Enable window, fullscreen, and OCR keyboard shortcuts in **Settings → Shortcuts**.

For the shortest path, **Quick Copy Region** copies your selection before restoring focus. It stays in memory unless you choose Save; its optional thumbnail lets you edit, save, pin, or drag the image. Raw output is the default; styling and named presets are explicit choices.

## Capture scrolling content

Choose **More Capture Options → Capture Scrolling Area…**, then drag around the visible part of the page or document. Scroll normally with your trackpad, mouse, or keyboard while SwiftShot quietly adds verified content. The source app keeps focus.

Press **Finish** in the floating HUD to open the stitched image in the normal editor, or **Cancel** to discard the session. If two views do not overlap confidently, SwiftShot pauses that append and asks you to scroll a little slower; accepted pixels remain intact. SwiftShot never drives the page, moves the pointer, guesses the bottom, or requires Accessibility/Input Monitoring permission.

## Keep working with your captures

- Open saved captures from local history, search indexed text, and manage pins and retention.
- Keep a resizable capture floating on screen, or combine captures vertically or side by side.
- Recapture the last region or use the available Apple Shortcuts actions.

## Build and run

Requires **macOS 14+**, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The local install script also requires an **Apple Development signing certificate** in Keychain. There is no publicly distributed, notarized download yet.

```sh
git clone https://github.com/Amitdvl/SwiftShot.git
cd SwiftShot
brew install xcodegen
./script/build_and_run.sh
```

The script builds a signed Release app, verifies update compatibility, lets the previous app preserve its captures before quitting, installs, and launches it. Grant SwiftShot Screen Recording access in **System Settings → Privacy & Security**, then retry the capture.

## Saved captures stay local

Quick Copy captures stay in memory and are discarded when SwiftShot quits. Captures are written to local recovery storage when you explicitly save them, so routine clipboard work does not build up files.

Private captures do not write recovery files or a local OCR index until you explicitly save them. Text indexing can be disabled separately.

**Recovery retains original pixels, including content behind crops and redactions.** Exported PNGs contain only the flattened result. Recovery files live in `~/Library/Application Support/SwiftShot/Recovery`.

## Verification and limits

See [release verification](docs/RELEASE_STATUS.md) for the latest local test and smoke results, including unverified hardware/OS cases. OCR is a supporting feature: recognition remains on-device, but first-use latency and difficult text can vary. Scrolling capture is bounded and conservative rather than a guarantee for every dynamic page.

[Report a bug or request a feature](https://github.com/Amitdvl/SwiftShot/issues) · [MIT license](LICENSE)
