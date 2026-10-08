#!/bin/bash
# Signs the Quick Look extension first (it must run sandboxed), then the app around it.
# `--deep` is not used: it would re-sign the extension without its entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/MD Lite.app}"
APPEX="$APP/Contents/PlugIns/MDLiteQuickLook.appex"
if [ -n "${MDLITE_SIGNING_IDENTITY:-}" ]; then
    FLAGS=(--force --options runtime --timestamp --sign "$MDLITE_SIGNING_IDENTITY")
else
    FLAGS=(--force --sign -)
fi
if [ -d "$APPEX" ]; then
    codesign "${FLAGS[@]}" --entitlements Resources/QuickLook/QuickLook.entitlements "$APPEX"
fi
codesign "${FLAGS[@]}" "$APP"
