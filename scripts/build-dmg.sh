#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP="dist/MD Lite.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
DMG="dist/MD-Lite-${VERSION}-${ARCH}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/mdlite-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

# ditto preserves the app bundle's metadata and signature.
ditto "$APP" "$STAGING/MD Lite.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/READ ME.txt" <<'INSTALL'
MD Lite — A little space to read.

Installation
1. Drag MD Lite into Applications.
2. Eject this disk image.
3. Open MD Lite from Applications.

Requires macOS 14 or later and a Mac matching the architecture in the DMG filename.

This development build is ad hoc signed and has not been notarized by Apple.
macOS may block downloaded copies. You may also build the app from source.

Open Markdown files with Command-O or drag them into the window.
The application interface is currently in Spanish.

MD Lite is open source under the MIT License.
Third-party license notices are included inside the application bundle.
INSTALL
cp LICENSE "$STAGING/LICENSE.txt"
codesign --verify --deep --strict "$STAGING/MD Lite.app"
hdiutil create -volname "MD Lite" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Disk image created: $DMG"
