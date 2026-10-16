#!/bin/zsh
# Builds AudioPin.app into ./build using SwiftPM, then ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build/AudioPin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AudioPin" "$APP/Contents/MacOS/AudioPin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature ("-") is enough for a personal, non-App Store app.
codesign --force --sign - --identifier com.mattmoglia.AudioPin "$APP"
echo "Built $APP"
