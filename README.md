# SwiftShot

A fast, lightweight screenshot tool for macOS.

Capture regions, windows, or full screens with global shortcuts. Optionally add styled backgrounds and OCR text from screenshots — all from the menu bar.

## Features

- **Region, Window & Fullscreen** capture modes
- **OCR** — select a region and copy recognized text to clipboard
- **Background compositing** — wrap screenshots in styled gradient backgrounds
- **Global keyboard shortcuts** — capture from any app
- **Auto-copy to clipboard** — screenshots land on your clipboard instantly
- **Notification banner** on every capture

## Default Shortcuts

| Action | Shortcut |
|---|---|
| Capture Region | `Cmd + Shift + 2` |
| Capture Fullscreen | `Cmd + Shift + F` |
| Capture Window | `Cmd + Shift + D` |
| OCR Region | `Cmd + Shift + O` |

Shortcuts can be enabled/disabled in **Preferences > Shortcuts**.

## Requirements

- macOS 14.0+
- Screen Recording permission (prompted on first capture)

## Building from Source

```sh
# Install xcodegen if needed
brew install xcodegen

# Generate & build
xcodegen generate
xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Release -derivedDataPath build clean build

# The app is at build/Build/Products/Release/SwiftShot.app
```
