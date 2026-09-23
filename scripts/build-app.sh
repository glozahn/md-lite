#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -Osize
BIN_DIR="$(swift build -c release -Xswiftc -Osize --show-bin-path)"
APP="dist/MD Lite.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp -f "$BIN_DIR/MDLite" "$APP/Contents/MacOS/MDLite"
# Local symbols are not needed at runtime; stripping keeps the app small.
strip -x "$APP/Contents/MacOS/MDLite"
# Mermaid ships xz-compressed and is only decoded when a document contains a diagram.
cp -f Resources/Mermaid/mermaid.min.js.xz "$APP/Contents/Resources/mermaid.min.js.xz"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -f CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
cp -f LICENSE "$APP/Contents/Resources/Licenses/MDLite-MIT.txt"
cp -f Resources/Mermaid/LICENSE "$APP/Contents/Resources/Licenses/mermaid-LICENSE"
swift scripts/icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
for dependency in swift-markdown swift-cmark; do
    for license in LICENSE LICENSE.txt COPYING NOTICE NOTICE.txt; do
        file=".build/checkouts/$dependency/$license"
        if [ -f "$file" ]; then cp -f "$file" "$APP/Contents/Resources/Licenses/$dependency-$license"; fi
    done
done
# Remove a previous envelope before replacing the executable or resources.
# Otherwise codesign can retain a stale resource seal from an earlier build.
rm -rf "$APP/Contents/_CodeSignature"
if [ -n "${MDLITE_SIGNING_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$MDLITE_SIGNING_IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
echo "Application created: $APP"
