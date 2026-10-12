#!/bin/sh
# Builds a universal (Apple silicon + Intel), ad-hoc signed VolBoost.app next to
# this script. VERSION=1.2.3 ./build.sh stamps the version into the bundle;
# ZIP=1 also writes VolBoost.zip for distribution.
set -e
cd "$(dirname "$0")"
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product VolBoost
BIN="$(swift build -c release $ARCHS --product VolBoost --show-bin-path)/VolBoost"

APP=VolBoost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/VolBoost"))"

if [ -n "$ZIP" ]; then
  rm -f VolBoost.zip
  # ditto keeps the code signature and bundle metadata intact.
  ditto -c -k --keepParent "$APP" VolBoost.zip
  echo "Wrote $(pwd)/VolBoost.zip"
fi
