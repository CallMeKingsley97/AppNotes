#!/bin/zsh
# 重新生成 macOS 应用图标的全部尺寸。
set -e
cd "$(dirname "$0")"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/appnotes-icon.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
iconset="$tmp_dir/AppIcon.iconset"
mkdir "$iconset"

xcrun swiftc -O -target arm64-apple-macosx15.0 -module-cache-path "$tmp_dir/ModuleCache" \
  -framework AppKit -o "$tmp_dir/mkicon" makeicon.swift
master="$iconset/icon_512x512@2x.png"
"$tmp_dir/mkicon" "$master"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  if [ "$size" -lt 512 ]; then
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  fi
done

iconutil -c icns "$iconset" -o "$tmp_dir/AppIcon.icns"
mkdir -p AppIcon.iconset
cp "$iconset"/*.png AppIcon.iconset/
cp "$tmp_dir/AppIcon.icns" AppIcon.icns
printf '==> AppIcon.icns 已更新\n'
