#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/MD Lite.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp -f "$BIN_DIR/MDLite" "$APP/Contents/MacOS/MDLite"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -f LICENSE "$APP/Contents/Resources/Licenses/MDLite-MIT.txt"
swift scripts/icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
for dependency in swift-markdown swift-cmark; do
    for license in LICENSE LICENSE.txt COPYING NOTICE NOTICE.txt; do
        file=".build/checkouts/$dependency/$license"
        if [ -f "$file" ]; then cp -f "$file" "$APP/Contents/Resources/Licenses/$dependency-$license"; fi
    done
done
if [ -n "${MDLITE_SIGNING_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --sign "$MDLITE_SIGNING_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
echo "Application created: $APP"
