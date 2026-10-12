#!/bin/sh
# Builds VolBoost.app (ad-hoc signed) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=VolBoost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VolBoost "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
