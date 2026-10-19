#!/bin/bash
# Builds Dropwheel.app: universal (Apple silicon + Intel), sandboxed, hardened runtime.
#   scripts/build.sh            -> build/Dropwheel.app
#   scripts/build.sh --install  -> also copies it to ~/Applications and launches it
#
# Updates are compiled in only when release/update.env (or the environment) provides
# DROPWHEEL_FEED_URL and DROPWHEEL_ED_PUBLIC_KEY; otherwise the app has no updater at all.
# DROPWHEEL_VERSION / DROPWHEEL_BUILD set the version; DROPWHEEL_CONFIG=debug builds a debug app.
# DROPWHEEL_SIGN_IDENTITY="Developer ID Application: …" signs for distribution; without it the
# build is ad-hoc signed (runs on the machine that built it, or after "Open Anyway").
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DROPWHEEL_UPDATE_ENV:-}" ] && [ -f release/update.env ]; then source release/update.env; fi
if [ -z "${DROPWHEEL_FEED_URL:-}" ] && [ -n "${DROPWHEEL_REPO:-}" ]; then
  DROPWHEEL_FEED_URL="https://github.com/$DROPWHEEL_REPO/releases/latest/download/appcast.xml"
fi
CONFIG="${DROPWHEEL_CONFIG:-release}"
if [ "$CONFIG" = "release" ]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi

swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product Dropwheel
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP=build/Dropwheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Dropwheel" "$APP/Contents/MacOS/Dropwheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
[ -n "${DROPWHEEL_VERSION:-}" ] && plist "Set :CFBundleShortVersionString $DROPWHEEL_VERSION"
# Build numbers are timestamps, so any fresh build counts as newer than a published one.
plist "Set :CFBundleVersion ${DROPWHEEL_BUILD:-$(date -u +%Y%m%d%H%M)}"
if [ -n "${DROPWHEEL_FEED_URL:-}" ] && [ -n "${DROPWHEEL_ED_PUBLIC_KEY:-}" ]; then
  plist "Add :SUFeedURL string $DROPWHEEL_FEED_URL"
  plist "Add :SUPublicEDKey string $DROPWHEEL_ED_PUBLIC_KEY"
  plist "Add :SURequireSignedFeed bool true"            # the appcast must carry a valid signature
  plist "Add :SUVerifyUpdateBeforeExtraction bool true" # check the archive before unpacking it
  UPDATES=on
  echo "Updates: on ($DROPWHEEL_FEED_URL)"
else
  UPDATES=off
  echo "Updates: off (no release/update.env)"
fi

if [ ! -f build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign inside-out. Sparkle's parts are re-signed with our identity, and its Downloader gets the
# only network entitlement in the bundle.
IDENTITY="${DROPWHEEL_SIGN_IDENTITY:--}"
ENTITLEMENTS=build/Dropwheel.entitlements
cp Resources/Dropwheel.entitlements "$ENTITLEMENTS"
DOWNLOADER_ENTITLEMENTS=Resources/Downloader.entitlements
if [ "$UPDATES" = off ]; then
  # No updater configured: Sparkle stays linked but can't reach anything.
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.temporary-exception.mach-lookup.global-name" "$ENTITLEMENTS"
  DOWNLOADER_ENTITLEMENTS=build/Downloader-offline.entitlements
  cp Resources/Downloader.entitlements "$DOWNLOADER_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.network.client" "$DOWNLOADER_ENTITLEMENTS"
fi
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc signatures have no Team ID, so the hardened runtime can't match the app with its own
  # embedded Sparkle.framework. This one exception lets it load; Developer ID builds don't get it.
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
  TIMESTAMP=--timestamp=none
else
  TIMESTAMP=--timestamp
fi
sign() { codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign --entitlements "$DOWNLOADER_ENTITLEMENTS" "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Dropwheel"))"

if [ "${1:-}" = "--install" ]; then
  pkill -x Dropwheel 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Dropwheel.app"
  ditto "$APP" "$HOME/Applications/Dropwheel.app"
  open "$HOME/Applications/Dropwheel.app"
  echo "Installed to ~/Applications/Dropwheel.app"
fi
