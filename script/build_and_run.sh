#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="/Applications/SwiftShot.app"
DERIVED_DATA="$ROOT_DIR/build/release.noindex"
PRODUCT="$DERIVED_DATA/Build/Products/Release/SwiftShot.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
case "$MODE" in run|--verify|--debug|--logs|--telemetry|--build) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
mkdir -p build
# The team ID is public certificate metadata; private keys stay in Keychain.
SIGNING_TEAM="${SWIFTSHOT_SIGNING_TEAM:-$(security find-certificate -c 'Apple Development' -p | openssl x509 -noout -subject -nameopt sep_multiline | sed -n 's/^ *OU=//p')}"
if [[ -z "$SIGNING_TEAM" ]]; then
  echo "An Apple Development certificate is required (or set SWIFTSHOT_SIGNING_TEAM)." >&2
  exit 1
fi
# Never silently fall back to ad-hoc signing: its identity changes on every build.
xcodegen generate > build/generate.log 2>&1
if ! xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Release -derivedDataPath "$DERIVED_DATA" DEVELOPMENT_TEAM="$SIGNING_TEAM" build > build/release-build.log 2>&1; then
  tail -60 build/release-build.log
  exit 1
fi
codesign --verify --deep --strict "$PRODUCT"
DETAILS="$(codesign -dvv "$PRODUCT" 2>&1)"
if ! [[ "$DETAILS" == *"Authority=Apple Development:"* || "$DETAILS" == *"Authority=Developer ID Application:"* ]]; then
  echo "Refusing to install without a stable Apple signing identity." >&2
  exit 1
fi
# Require updates to satisfy the installed app's identity before replacing it.
if [[ -d "$APP_BUNDLE" ]]; then
  REQUIREMENT="$(codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$REQUIREMENT" ]]; then echo "Cannot read installed signing identity." >&2; exit 1; fi
  codesign --verify -R="$REQUIREMENT" "$PRODUCT"
fi
STAGE="$(mktemp -d /Applications/.SwiftShot-update.XXXXXX)"
cleanup() {
  if [[ -d "$STAGE/previous.app" && ! -e "$APP_BUNDLE" ]]; then
    if ! mv "$STAGE/previous.app" "$APP_BUNDLE"; then
      echo "Previous app retained at $STAGE/previous.app; restore it before updating." >&2
      return
    fi
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$PRODUCT" "$STAGE/SwiftShot.app"
codesign --verify --deep --strict "$STAGE/SwiftShot.app"
# Let the app preserve unsaved captures before replacing its executable.
if pgrep -x SwiftShot >/dev/null; then
  osascript -e 'tell application "SwiftShot" to quit'
  for ((attempt=0; attempt<30; attempt++)); do
    if ! pgrep -x SwiftShot >/dev/null; then break; fi
    sleep 1
  done
  if pgrep -x SwiftShot >/dev/null; then
    echo "SwiftShot could not quit safely; the installed app was kept." >&2
    exit 1
  fi
fi
if [[ -d "$APP_BUNDLE" ]]; then mv "$APP_BUNDLE" "$STAGE/previous.app"; fi
if ! mv "$STAGE/SwiftShot.app" "$APP_BUNDLE"; then
  if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$APP_BUNDLE"; fi
  exit 1
fi
"$LSREGISTER" -f "$APP_BUNDLE"
# Build products are disposable; retain the cache, logs, and one launchable app.
"$LSREGISTER" -u "$PRODUCT" >/dev/null 2>&1 || true
rm -rf "$PRODUCT"
echo "Installed $APP_BUNDLE"
if [[ "$MODE" == "--build" ]]; then exit 0; fi
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/SwiftShot" ;;
  --logs) open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SwiftShot"' ;;
  --telemetry) open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.swiftshot.app"' ;;
  --verify) open "$APP_BUNDLE"; sleep 1; pgrep -x SwiftShot >/dev/null; echo "SwiftShot is running" ;;
  *) open "$APP_BUNDLE" ;;
esac
