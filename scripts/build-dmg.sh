#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${MDLITE_SKIP_BUILD:-0}" != "1" ]; then
    ./scripts/build-app.sh
fi

APP="dist/MD Lite.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
# "universal" when the app runs on both Apple silicon and Intel.
ARCHS=$(lipo -archs "$APP/Contents/MacOS/MDLite")
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ARCH=universal ;; *) ARCH=$ARCHS ;; esac
DMG="dist/MD-Lite-${VERSION}-${ARCH}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/mdlite-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

# ditto preserves the app bundle's metadata and signature.
ditto "$APP" "$STAGING/MD Lite.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/README.md" <<INSTALL
# MD Lite ${VERSION}

**A little space to read, write, code.**

## Install

1. Drag **MD Lite** into **Applications**.
2. Eject this disk image.
3. Open MD Lite from Applications.

Requires macOS 14 or later, on Apple silicon or Intel. This release is signed with a Developer ID certificate and notarized by Apple.

## Start

- Open Markdown with **⌘O**, drop files into the window, or open a whole folder with **⇧⌘O**.
- **⌘1** Reading · **⌘2** Editor · **⌘3** Source · **⌘4** Split. Each document gets its own tab (**⌘T**, **⌘W**).
- **⌘/** shows every shortcut; **⌘,** opens Settings.

MD Lite is open source under the MIT License: https://github.com/glozahn/md-lite
Third-party license notices are included inside the application bundle.
INSTALL
cp LICENSE "$STAGING/LICENSE.txt"
codesign --verify --deep --strict "$STAGING/MD Lite.app"
hdiutil create -volname "MD Lite" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Disk image created: $DMG"
