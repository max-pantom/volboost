#!/bin/sh
# Regenerates Icon/AppIcon.icns from make-icon.swift.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swift make-icon.swift "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$TMP/icon_1024.png" preview.png
rm -rf "$TMP"
echo "Wrote $(pwd)/AppIcon.icns"
