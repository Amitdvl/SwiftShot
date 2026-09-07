#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="SwiftShot"
APP_BUNDLE="$ROOT_DIR/dist/SwiftShot.app"
case "$MODE" in run|--verify|--debug|--logs|--telemetry|--build) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
mkdir -p build dist
xcodegen generate > build/generate.log 2>&1
if ! xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Release -derivedDataPath build/release build > build/release-build.log 2>&1; then
  rg -n -C 2 'error:|BUILD FAILED' build/release-build.log | head -80 || tail -12 build/release-build.log
  exit 1
fi
# Stage only after a successful build; keep the previous app until the new one is ready.
if [[ -d dist/SwiftShot.staging.app ]]; then rm -rf dist/SwiftShot.staging.app; fi
ditto build/release/Build/Products/Release/SwiftShot.app dist/SwiftShot.staging.app
if [[ -d "$APP_BUNDLE" ]]; then rm -rf "$APP_BUNDLE"; fi
mv dist/SwiftShot.staging.app "$APP_BUNDLE"
echo "Built $APP_BUNDLE"
if [[ "$MODE" == "--build" ]]; then exit 0; fi
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/SwiftShot" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SwiftShot"' ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.swiftshot.app"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null; echo "SwiftShot is running" ;;
  *) open -n "$APP_BUNDLE" ;;
esac
