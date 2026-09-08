#!/bin/zsh
set -e
cd "$(dirname "$0")"

NAME="AppNotes"
SRC="Sources"
BUILD="Build"
APP="$BUILD/$NAME.app"
CONTENTS="$APP/Contents"

SDK=$(xcrun --show-sdk-path)

echo "==> Compiling (sdk: $SDK)"
rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

xcrun swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$BUILD/ModuleCache" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Carbon \
  -o "$CONTENTS/MacOS/$NAME" \
  "$SRC"/*.swift

cp Info.plist "$CONTENTS/Info.plist"
cp -R Resources/. "$CONTENTS/Resources/"

if [ -f "AppIcon.icns" ]; then
  cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built: $PWD/$APP"
