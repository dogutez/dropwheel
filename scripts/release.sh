#!/bin/bash
# Prepares a release: universal app → zip → EdDSA signature → appcast.xml (Sparkle feed).
#   scripts/release.sh 1.1.0            Developer ID signed + notarized (needs both settings below)
#   scripts/release.sh 1.1.0 --adhoc    ad-hoc build; users must "Open Anyway" once
#
# Needs release/update.env with:
#   DROPWHEEL_REPO="owner/repo"                  GitHub repo that hosts releases
#   DROPWHEEL_ED_PUBLIC_KEY="…"                  from: swift scripts/update-signing.swift generate
# Optional:
#   DROPWHEEL_SIGN_IDENTITY="Developer ID Application: …"  sign for distribution
#   DROPWHEEL_NOTARY_PROFILE="…"                 notarize (xcrun notarytool store-credentials)
#
# It does not publish anything. It prints the `gh release create` command to run when ready.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.1.0> [--adhoc]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Version must look like 1.2 or 1.2.3"; exit 1; }
ENV_FILE="${DROPWHEEL_UPDATE_ENV:-release/update.env}"   # override for local end-to-end tests
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE is missing (see the header of this script)"; exit 1; }
set -a; source "$ENV_FILE"; set +a   # export, so scripts/build.sh sees the settings
: "${DROPWHEEL_REPO:?set DROPWHEEL_REPO in release/update.env}"
: "${DROPWHEEL_ED_PUBLIC_KEY:?set DROPWHEEL_ED_PUBLIC_KEY in release/update.env}"
[[ "$DROPWHEEL_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "DROPWHEEL_REPO must look like owner/repo"; exit 1; }
if [ -z "${DROPWHEEL_SIGN_IDENTITY:-}" ] || [ -z "${DROPWHEEL_NOTARY_PROFILE:-}" ]; then
  if [ "${2:-}" != "--adhoc" ]; then
    echo "No Developer ID / notary profile in $ENV_FILE. Add them, or pass --adhoc to release an"
    echo "ad-hoc build (users then have to click \"Open Anyway\" once)."
    exit 1
  fi
  echo "Warning: ad-hoc release (not notarized)."
fi

export DROPWHEEL_FEED_URL="${DROPWHEEL_FEED_URL:-https://github.com/$DROPWHEEL_REPO/releases/latest/download/appcast.xml}"
export DROPWHEEL_VERSION="$VERSION"
export DROPWHEEL_BUILD="${DROPWHEEL_BUILD:-$(date -u +%Y%m%d%H%M)}"   # always increases
# Tags are the bare version ("1.0.0"); "v1.0.0"/"v1.0.1" are permanently reserved on GitHub by
# immutable releases of an earlier repository at this address.
TAG="$VERSION"
DOWNLOAD_BASE="${DROPWHEEL_DOWNLOAD_BASE:-https://github.com/$DROPWHEEL_REPO/releases/download/$TAG}"

scripts/build.sh

mkdir -p release
ZIP="release/Dropwheel-$VERSION.zip"
rm -f "$ZIP"
if [ -n "${DROPWHEEL_NOTARY_PROFILE:-}" ]; then
  ditto -c -k --sequesterRsrc --keepParent build/Dropwheel.app "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$DROPWHEEL_NOTARY_PROFILE" --wait
  xcrun stapler staple build/Dropwheel.app
  rm -f "$ZIP"
fi
ditto -c -k --sequesterRsrc --keepParent build/Dropwheel.app "$ZIP"

LENGTH="$(stat -f%z "$ZIP")"
cat > release/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dropwheel</title>
    <item>
      <title>Dropwheel $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$DROPWHEEL_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$DROPWHEEL_REPO/releases/tag/$TAG</link>
      <enclosure url="$DOWNLOAD_BASE/Dropwheel-$VERSION.zip" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="__ED_SIGNATURE__"/>
    </item>
  </channel>
</rss>
EOF

# One Keychain approval: checks the key matches the app, signs the archive, then signs the feed
# itself (SURequireSignedFeed), so a swapped appcast is rejected too.
swift -suppress-warnings scripts/update-signing.swift sign-release "$ZIP" release/appcast.xml "$DROPWHEEL_ED_PUBLIC_KEY"

echo
echo "Ready: $ZIP and release/appcast.xml (build $DROPWHEEL_BUILD)."
echo "Publish with:"
echo "  git tag $TAG && git push origin $TAG"
echo "  gh release create $TAG \"$ZIP\" release/appcast.xml --repo $DROPWHEEL_REPO --title \"Dropwheel $VERSION\" --verify-tag"
