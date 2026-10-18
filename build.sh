#!/bin/zsh
# Builds AudioPin.app into ./build using SwiftPM (universal: Apple Silicon +
# Intel), then signs it.
#
#   ./build.sh            release build, ad-hoc signed (fine for your own Mac)
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                         Developer ID signed with hardened runtime, ready to
#                         notarize (see release.sh)
#
# The Makefile's `release` target finds SIGN_ID automatically.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/AudioPin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AudioPin" "$APP/Contents/MacOS/AudioPin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --timestamp --options runtime \
    --entitlements Resources/AudioPin.entitlements \
    --sign "$SIGN_ID" "$APP"
  echo "Built $APP (signed: $SIGN_ID)"
else
  # Ad-hoc signature ("-") is enough for a personal, non-distributed build.
  codesign --force --sign - --identifier com.mattmoglia.AudioPin "$APP"
  echo "Built $APP (ad-hoc signed)"
fi
