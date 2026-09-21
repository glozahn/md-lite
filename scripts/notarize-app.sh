#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Local signing settings live in a git-ignored file so account identifiers stay out of the repository.
if [ -f scripts/notarize.env ]; then
    # shellcheck source=/dev/null
    source scripts/notarize.env
fi
export MDLITE_SIGNING_IDENTITY ASC_KEY_ID ASC_ISSUER_ID ASC_API_KEY_PATH

: "${MDLITE_SIGNING_IDENTITY:?Set MDLITE_SIGNING_IDENTITY to your Developer ID Application certificate name}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer ID}"

KEY_PATH="${ASC_API_KEY_PATH:-$HOME/.app-store-connect/AuthKey_${ASC_KEY_ID}.p8}"
DMG="${1:-$(ls -t dist/MD-Lite-*.dmg | head -1)}"
APP="dist/MD Lite.app"

if [ ! -f "$KEY_PATH" ]; then
    echo "App Store Connect key not found: $KEY_PATH" >&2
    exit 1
fi

echo "Signing with: $MDLITE_SIGNING_IDENTITY"
codesign --force --deep --options runtime --timestamp --sign "$MDLITE_SIGNING_IDENTITY" "$APP"
./scripts/build-dmg.sh
DMG="$(ls -t dist/MD-Lite-*.dmg | head -1)"

xcrun notarytool submit "$DMG" \
    --key "$KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# Repackage after stapling so the downloadable DMG contains the stapled app.
MDLITE_SKIP_BUILD=1 ./scripts/build-dmg.sh
DMG="$(ls -t dist/MD-Lite-*.dmg | head -1)"
echo "Notarized application: $APP"
echo "Notarized disk image: $DMG"
