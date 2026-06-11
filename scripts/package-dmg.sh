#!/bin/zsh
# Packages a notarized PageFlow export into the gold-standard styled DMG.
#
# Usage: scripts/package-dmg.sh "<export folder containing PageFlow.app>" [output.dmg]
#
# The export must be a Developer ID, notarized + stapled app (Xcode Organizer →
# Distribute App → Direct Distribution). Verify first:
#   xcrun stapler validate "<export>/PageFlow.app"
#
# Layout per the documented gold standard: 660x400 window, app at (180,190),
# Applications drop-link at (480,190), HiDPI background with drag hint.
set -euo pipefail

EXPORT_DIR="${1:?usage: package-dmg.sh <export-folder> [output.dmg]}"
APP="$EXPORT_DIR/PageFlow.app"
[ -d "$APP" ] || { echo "error: no PageFlow.app in $EXPORT_DIR" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$REPO_ROOT/dist/PageFlow-$VERSION.dmg}"
BG="$REPO_ROOT/scripts/dmg-background.tiff"

xcrun stapler validate "$APP" >/dev/null || { echo "error: app is not stapled/notarized" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/PageFlow.app"
rm -f "$OUT"

create-dmg \
  --volname "PageFlow" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "PageFlow.app" 180 190 \
  --hide-extension "PageFlow.app" \
  --app-drop-link 480 190 \
  --no-internet-enable \
  "$OUT" \
  "$STAGING"

echo
echo "DMG: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
echo "Sparkle signature (for appcast.xml):"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -path "*artifacts/sparkle/Sparkle/bin/*" 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] && "$SIGN_UPDATE" "$OUT" || echo "  (sign_update not found — run Sparkle's sign_update manually)"
