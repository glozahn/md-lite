#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# One binary for Apple silicon and Intel Macs. MDLITE_ARCH=arm64 builds a quicker local copy.
ARCH_FLAGS=()
for arch in ${MDLITE_ARCH:-arm64 x86_64}; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release -Xswiftc -Osize "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release -Xswiftc -Osize "${ARCH_FLAGS[@]}" --show-bin-path)"
APP="dist/MD Lite.app"
APPEX="$APP/Contents/PlugIns/MDLiteQuickLook.appex"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APPEX/Contents/MacOS"
cp -f "$BIN_DIR/MDLite" "$APP/Contents/MacOS/MDLite"
# Finder's Quick Look preview for Markdown files.
cp -f "$BIN_DIR/MDLiteQuickLook" "$APPEX/Contents/MacOS/MDLiteQuickLook"
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" Resources/QuickLook/Info.plist > "$APPEX/Contents/Info.plist"
# Local symbols are not needed at runtime; stripping keeps the app small.
strip -x "$APP/Contents/MacOS/MDLite" "$APPEX/Contents/MacOS/MDLiteQuickLook"
# Mermaid ships xz-compressed and is only decoded when a document contains a diagram.
cp -f Resources/Mermaid/mermaid.min.js.xz "$APP/Contents/Resources/mermaid.min.js.xz"
# MathJax, like Mermaid, is decoded only when a document contains math.
cp -f Resources/MathJax/tex-svg.js.xz "$APP/Contents/Resources/tex-svg.js.xz"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -f CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
cp -f LICENSE "$APP/Contents/Resources/Licenses/MDLite-MIT.txt"
cp -f Resources/Mermaid/LICENSE "$APP/Contents/Resources/Licenses/mermaid-LICENSE"
cp -f Resources/MathJax/LICENSE "$APP/Contents/Resources/Licenses/mathjax-LICENSE"
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
rm -rf "$APP/Contents/_CodeSignature" "$APPEX/Contents/_CodeSignature"
./scripts/sign-app.sh "$APP"
echo "Application created: $APP"
