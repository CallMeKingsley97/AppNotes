#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

REVIEW_APP="Build/UIReview.app"
mkdir -p "$REVIEW_APP/Contents/MacOS" "$REVIEW_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx15.0 \
  -module-cache-path Build/ModuleCache \
  Sources/Preferences.swift Sources/Models.swift Sources/Fetcher.swift Sources/Components.swift \
  Sources/AppDetails.swift Sources/DetailView.swift Sources/CategoryViews.swift \
  Sources/Views.swift Sources/SettingsView.swift Sources/OverlayViews.swift Tests/DetailsFixtures.swift Tests/UIReview.swift \
  -o "$REVIEW_APP/Contents/MacOS/UIReview"
cp -R Resources/. "$REVIEW_APP/Contents/Resources/"
cat > "$REVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UIReview</string>
<key>CFBundleIdentifier</key><string>com.workbuddy.appnotes.ui-review</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
echo "Built UI review: $REVIEW_APP/Contents/MacOS/UIReview"
