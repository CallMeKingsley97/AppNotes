#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

NAME="AppNotes"

resolve_version() {
    local candidate="${GITHUB_REF_NAME:-}"
    if [[ "$candidate" != v* ]]; then
        candidate=$(git describe --tags --exact-match 2>/dev/null || true)
    fi
    if [[ "$candidate" == v* ]]; then
        printf '%s' "${candidate#v}"
        return
    fi
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist
}

VERSION=$(resolve_version)
DMG="Build/${NAME}-${VERSION}-macOS.dmg"
STAGING="Build/package"

./build.sh

# Keep the bundled version in sync with the tag-driven release version.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "Build/${NAME}.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "Build/${NAME}.app/Contents/Info.plist"

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
