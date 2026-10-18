#!/bin/zsh
# Cuts a public release:
#   1. stamps the version into Info.plist
#   2. builds, signs with Developer ID, notarizes with Apple, staples
#   3. zips to dist/AudioPin-<version>.zip
#   4. creates a GitHub release with the zip attached
#
# Usage: ./release.sh 1.1 "Short release notes"
#
# One-time setup (see README, "Releasing"):
#   - a "Developer ID Application" certificate in your login keychain
#   - a notarytool keychain profile named "AudioPin":
#       xcrun notarytool store-credentials AudioPin --apple-id YOU@EXAMPLE.COM \
#           --team-id TEAMID --password APP-SPECIFIC-PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-AudioPin $VERSION}"
PROFILE="${NOTARY_PROFILE:-AudioPin}"

SIGN_ID="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
if [[ -z "$SIGN_ID" ]]; then
  echo "No 'Developer ID Application' certificate in the keychain. See README > Releasing." >&2
  exit 1
fi

# Version = what people see; build = a number that always goes up.
BUILD="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

SIGN_ID="$SIGN_ID" ./build.sh release

mkdir -p dist
ZIP="dist/AudioPin-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/AudioPin.app "$ZIP"

echo "Submitting to Apple for notarization (usually 1-5 minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/AudioPin.app
# Re-zip so the stapled ticket is inside the download.
rm -f "$ZIP"
ditto -c -k --keepParent build/AudioPin.app "$ZIP"
spctl --assess --type execute --verbose=2 build/AudioPin.app

git add Resources/Info.plist
git commit -q -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push -q origin HEAD --tags

gh release create "v$VERSION" "$ZIP" --title "AudioPin $VERSION" --notes "$NOTES"
echo "Released AudioPin $VERSION"
