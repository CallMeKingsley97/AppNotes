#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

# Run ./build.sh first so these checks also validate the bundled translations.
mkdir -p Build/Tests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path Build/ModuleCache \
  Sources/Preferences.swift Tests/PreferencesTests.swift \
  -o Build/Tests/PreferencesTests
Build/Tests/PreferencesTests "$PWD/Build/AppNotes.app"
plutil -lint Info.plist Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
