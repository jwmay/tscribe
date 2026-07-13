#!/bin/bash
set -euo pipefail

# Generates the Sparkle appcast — the feed the Standard edition polls to learn that a newer
# Tscribe exists. Emits a single <item> describing the release being cut.
#
# One item, not a history: Sparkle only ever offers the newest version, so a running list
# buys nothing and would mean carrying state (the previous appcast) between CI runs. Fewer
# moving parts on the path that can silently push code onto a lawyer's Mac.
#
# The enclosure is signed with our EdDSA key. That signature — not HTTPS, not GitHub — is
# what actually protects users: Sparkle refuses any update whose signature doesn't match
# the SUPublicEDKey compiled into the app, so even someone who took over the appcast host
# or the release assets still cannot ship a malicious Tscribe.
#
# Usage: make-appcast.sh --app <Tscribe.app> --zip <Tscribe.zip> --tag <vX.Y.Z> \
#                        --download-url <url of the zip> [--notes <file>] [--out <path>]
#
# Signing key, in order of preference:
#   SPARKLE_PRIVATE_KEY   env var (CI) — the base64 seed from `generate_keys -x`, piped to
#                         sign_update on stdin so it never lands on disk or in a process
#                         argument (i.e. never in `ps`, never in a CI log).
#   otherwise             the login keychain (a local maintainer run), where `generate_keys`
#                         put it. It never has to leave the keychain.

APP=""; ZIP=""; TAG=""; DOWNLOAD_URL=""; NOTES=""; OUT="appcast.xml"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
for v in APP ZIP TAG DOWNLOAD_URL; do
  [ -n "${!v}" ] || { echo "Missing required --${v//_/-} (lowercased)"; exit 2; }
done
[ -d "$APP" ] || { echo "No such app: $APP"; exit 1; }
[ -f "$ZIP" ] || { echo "No such zip: $ZIP"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# sign_update ships inside Sparkle's own SPM artifact, so its version always matches the
# framework the app was linked against — nothing extra to download, nothing to pin twice.
SIGN_UPDATE="$(find "$PROJECT_DIR/build/SourcePackages/artifacts" -name sign_update -not -path '*old_dsa*' 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || {
  echo "Could not find Sparkle's sign_update. Build once so SPM resolves Sparkle:"
  echo "  xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration ReleaseStandard -derivedDataPath build build"
  exit 1
}

# Version identity comes from the app that is ACTUALLY being shipped, not from project.yml.
# If the two ever disagree, the appcast should describe what's in the zip.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
BUILD="$(plist CFBundleVersion)"                # sparkle:version — what Sparkle compares
SHORT="$(plist CFBundleShortVersionString)"     # sparkle:shortVersionString — what users see
MINOS="$(plist LSMinimumSystemVersion 2>/dev/null || echo "14.0")"

# Sanity: the tag should describe the same version as the app, or someone has mis-tagged and
# users would be offered an update whose version doesn't match its contents.
if [ "v$SHORT" != "$TAG" ] && [ "$SHORT" != "$TAG" ]; then
  echo "Tag/app version mismatch: tag=$TAG but the app is $SHORT (build $BUILD)"
  echo "Bump project.yml (/bump-version) and re-tag, or tag v$SHORT."
  exit 1
fi

echo "==> Signing $ZIP with the EdDSA update key"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIGNED="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"
  echo "    (key from SPARKLE_PRIVATE_KEY, via stdin)"
else
  SIGNED="$("$SIGN_UPDATE" "$ZIP")"
  echo "    (key from the login keychain)"
fi
# sign_update prints: sparkle:edSignature="…" length="…"
echo "$SIGNED" | grep -q 'sparkle:edSignature=' || { echo "sign_update produced no signature: $SIGNED"; exit 1; }

PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NOTES_HTML=""
[ -n "$NOTES" ] && [ -f "$NOTES" ] && NOTES_HTML="$(cat "$NOTES")"

{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tscribe</title>
    <link>https://updates.docmayscience.com/appcast.xml</link>
    <description>Updates for Tscribe (Standard edition)</description>
    <language>en</language>
    <item>
      <title>Version $SHORT</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
XML
  if [ -n "$NOTES_HTML" ]; then
    printf '      <description><![CDATA[\n%s\n      ]]></description>\n' "$NOTES_HTML"
  fi
  cat <<XML
      <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $SIGNED />
    </item>
  </channel>
</rss>
XML
} > "$OUT"

# A malformed appcast is a silently-dead update channel, so fail here rather than ship it.
xmllint --noout "$OUT" 2>/dev/null || { echo "Generated appcast is not well-formed XML:"; cat "$OUT"; exit 1; }

echo "==> Wrote $OUT"
echo "    version:  $SHORT (build $BUILD), min macOS $MINOS"
echo "    enclosure: $DOWNLOAD_URL"
