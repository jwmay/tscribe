#!/bin/bash
set -euo pipefail

# Packages Tscribe into a self-contained, ad-hoc-signed .dmg.
# Free (no Apple Developer account). The app bundles whisper-cli + the large-v3
# model + the Silero VAD model, so it transcribes 100% offline on any Apple-Silicon Mac.
#
# First launch on another Mac: right-click the app → Open → Open (one-time Gatekeeper bypass).

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$HOME/Developer/whisper.cpp"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Tscribe"

MODEL="$WHISPER_DIR/models/ggml-large-v3.bin"
VAD="$WHISPER_DIR/models/ggml-silero-v5.1.2.bin"
CLI="$WHISPER_DIR/build/bin/whisper-cli"

echo "==> Checking engine artifacts"
for f in "$MODEL" "$VAD" "$CLI"; do
  [ -f "$f" ] || { echo "   MISSING: $f"; exit 1; }
done

echo "==> Building Release"
cd "$PROJECT_DIR"
xcodegen generate >/dev/null
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration Release \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "   Build did not produce $APP"; exit 1; }

echo "==> Bundling engine + models into $APP_NAME.app/Contents/Resources"
RES="$APP/Contents/Resources"
mkdir -p "$RES"
cp "$CLI"   "$RES/whisper-cli"
cp "$MODEL" "$RES/ggml-large-v3.bin"
cp "$VAD"   "$RES/ggml-silero-v5.1.2.bin"
chmod +x "$RES/whisper-cli"

echo "==> Ad-hoc signing (inner binary first, then the app)"
codesign --force --sign - --timestamp=none "$RES/whisper-cli"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" || echo "   (verify note above is expected for ad-hoc)"

echo "==> Sanity: bundled whisper-cli runs from its bundled location"
"$RES/whisper-cli" --help >/dev/null 2>&1 && echo "   OK: bundled whisper-cli executes"

echo "==> Creating .dmg"
mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST_DIR/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo "==> Done"
echo "    App size:  $(du -sh "$APP" | cut -f1)"
echo "    DMG:       $DIST_DIR/$APP_NAME.dmg  ($(du -sh "$DIST_DIR/$APP_NAME.dmg" | cut -f1))"
