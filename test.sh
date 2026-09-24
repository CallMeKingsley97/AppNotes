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
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path Build/ModuleCache \
  Sources/Models.swift Sources/AppDetails.swift Tests/DetailsFixtures.swift Tests/AppDetailsTests.swift \
  -o Build/Tests/AppDetailsTests
Build/Tests/AppDetailsTests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path Build/ModuleCache \
  Sources/Models.swift Tests/CustomCategoryTests.swift \
  -o Build/Tests/CustomCategoryTests
Build/Tests/CustomCategoryTests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path Build/ModuleCache \
  Sources/Models.swift Sources/Preferences.swift Sources/ManualImport.swift Tests/ManualImportTests.swift \
  -o Build/Tests/ManualImportTests
Build/Tests/ManualImportTests
plutil -lint Info.plist Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
