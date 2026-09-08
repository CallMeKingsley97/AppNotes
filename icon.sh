#!/bin/zsh
# 重新生成 AppIcon.icns
set -e
cd "$(dirname "$0")"

xcrun swiftc -O -target arm64-apple-macosx15.0 -framework AppKit -o /tmp/mkicon makeicon.swift

rm -rf AppIcon.iconset AppIcon.icns
mkdir -p AppIcon.iconset
/tmp/mkicon /tmp/appicon_1024.png

for s in 16 32 128 256 512; do
  sips -z $s $s /tmp/appicon_1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
done
sips -z 32 32   /tmp/appicon_1024.png --out AppIcon.iconset/icon_16x16@2x.png     > /dev/null
sips -z 64 64   /tmp/appicon_1024.png --out AppIcon.iconset/icon_32x32@2x.png     > /dev/null
sips -z 256 256 /tmp/appicon_1024.png --out AppIcon.iconset/icon_128x128@2x.png   > /dev/null
sips -z 512 512 /tmp/appicon_1024.png --out AppIcon.iconset/icon_256x256@2x.png   > /dev/null
cp /tmp/appicon_1024.png AppIcon.iconset/icon_512x512@2x.png

iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "==> AppIcon.icns 已更新 ($(wc -c < AppIcon.icns | tr -d ' ') bytes)"
