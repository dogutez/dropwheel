#!/bin/bash
# Packs build/Dropwheel.app into a drag-to-Applications disk image.
#   scripts/make-dmg.sh release/Dropwheel.dmg
# With DROPWHEEL_SIGN_IDENTITY set, the image is signed as well (notarize it afterwards).
#
# Uses dmgbuild (MIT, pinned below) at build time only, installed into build/.dmgbuild; nothing
# from it ends up inside the app.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: scripts/make-dmg.sh <out.dmg>}"
APP=build/Dropwheel.app
[ -d "$APP" ] || { echo "Build the app first: scripts/build.sh"; exit 1; }

VENV=build/.dmgbuild
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.7"
fi

# Retina-ready background: 1× and 2× PNGs combined into one TIFF.
swift scripts/make-dmg-background.swift build/dmg-background.png 1
swift scripts/make-dmg-background.swift build/dmg-background@2x.png 2
tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png -out build/dmg-background.tiff >/dev/null 2>&1

rm -f "$OUT"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D background=build/dmg-background.tiff "Dropwheel" "$OUT" >/dev/null

if [ -n "${DROPWHEEL_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$DROPWHEEL_SIGN_IDENTITY" --timestamp "$OUT"
fi
hdiutil verify "$OUT" >/dev/null
echo "Made $OUT"
