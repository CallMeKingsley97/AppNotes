#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

NAME="AppNotes"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DMG="Build/${NAME}-${VERSION}-macOS.dmg"
STAGING="Build/package"

./build.sh
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "Build/${NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"
echo "==> Packaged: $PWD/$DMG"
