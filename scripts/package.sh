#!/bin/bash
set -euo pipefail

# Packages Tscribe into a self-contained, ad-hoc-signed .dmg.
# Free (no Apple Developer account). First launch on another Mac:
# right-click the app → Open → Open (one-time Gatekeeper bypass).
#
# Usage: package.sh [--edition full|lite]
#
#   full  (default)  Bundles whisper-cli + Silero VAD + the 2.9 GB large-v3 model.
#                    Transcribes 100% offline from first launch. ~2.7 GB DMG.
#                    Distributed manually (too big for GitHub's 2 GiB limit).
#
#   lite             Bundles whisper-cli + Silero VAD only (a few-MB DMG). The
#                    large-v3 model is downloaded once on first launch. Built with
#                    the LITE compile flag (ReleaseLite config) so the downloader
#                    + onboarding are compiled in.

EDITION="full"
while [ $# -gt 0 ]; do
  case "$1" in
    --edition) EDITION="${2:-}"; shift 2 ;;
    --edition=*) EDITION="${1#*=}"; shift ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done
case "$EDITION" in full|lite) ;; *) echo "Invalid edition: $EDITION (expected full|lite)"; exit 2 ;; esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$PROJECT_DIR/engine"
WHISPER_DIR="$HOME/Developer/whisper.cpp"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Tscribe"

# Small artifacts are vendored (hermetic + CI-friendly); the big model is not committed.
CLI="$ENGINE_DIR/whisper-cli"
VAD="$ENGINE_DIR/ggml-silero-v5.1.2.bin"
MODEL="$WHISPER_DIR/models/ggml-large-v3.bin"

if [ "$EDITION" = "full" ]; then
  CONFIG="Release"
  DMG_NAME="Tscribe.dmg"
else
  CONFIG="ReleaseLite"
  DMG_NAME="Tscribe-Lite.dmg"
fi

echo "==> Edition: $EDITION  (config: $CONFIG)"

echo "==> Checking engine artifacts"
for f in "$CLI" "$VAD"; do
  [ -f "$f" ] || { echo "   MISSING: $f"; exit 1; }
done
if [ "$EDITION" = "full" ]; then
  [ -f "$MODEL" ] || { echo "   MISSING: $MODEL (required for the full edition)"; exit 1; }
fi

# Lite drift-guard: the model the Lite app will download must be the exact bytes the
# Full edition bundles. Verify the pinned SHA in ModelInstaller.swift against the
# canonical local model when it's available (skipped on CI, which has no model).
if [ "$EDITION" = "lite" ]; then
  EXPECTED_SHA="$(grep -Eo 'sha256 = "[0-9a-f]{64}"' "$PROJECT_DIR/Sources/Core/ModelInstaller.swift" | grep -Eo '[0-9a-f]{64}' | head -1)"
  [ -n "$EXPECTED_SHA" ] || { echo "   Could not read pinned model SHA from ModelInstaller.swift"; exit 1; }
  if [ -f "$MODEL" ]; then
    echo "==> Drift-guard: verifying local model matches pinned SHA"
    ACTUAL_SHA="$(shasum -a 256 "$MODEL" | cut -d' ' -f1)"
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      echo "   SHA MISMATCH:"
      echo "     pinned (ModelSpec):  $EXPECTED_SHA"
      echo "     local model:         $ACTUAL_SHA"
      echo "   Update ModelSpec (and re-verify the Full bundle) before shipping Lite."
      exit 1
    fi
    echo "   OK: model matches pinned SHA ($EXPECTED_SHA)"
  else
    echo "==> Drift-guard skipped (no local model to verify; pinned SHA: $EXPECTED_SHA)"
  fi
fi

echo "==> Building $CONFIG"
cd "$PROJECT_DIR"
xcodegen generate >/dev/null
xcodebuild -project tscribe.xcodeproj -scheme tscribe -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build >/dev/null

APP="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$APP" ] || { echo "   Build did not produce $APP"; exit 1; }

echo "==> Bundling engine into $APP_NAME.app/Contents/Resources"
RES="$APP/Contents/Resources"
mkdir -p "$RES"
cp "$CLI" "$RES/whisper-cli"
cp "$VAD" "$RES/ggml-silero-v5.1.2.bin"
chmod +x "$RES/whisper-cli"
if [ "$EDITION" = "full" ]; then
  echo "    + bundling large-v3 model (2.9 GB)"
  cp "$MODEL" "$RES/ggml-large-v3.bin"
else
  echo "    (skipping large-v3 model — downloaded on first launch)"
fi

# Full offline-audit: the "no network at all" claim should be auditable — the
# Hugging Face URL only exists behind #if LITE, so it must be absent from Full.
if [ "$EDITION" = "full" ]; then
  echo "==> Offline audit: confirming no download URL in the Full binary"
  if strings -a "$APP/Contents/MacOS/$APP_NAME" | grep -q "huggingface.co"; then
    echo "   FAIL: found a Hugging Face URL in the Full build — networking code leaked in."
    exit 1
  fi
  echo "   OK: no download URL present"
fi

echo "==> Ad-hoc signing (inner binary first, then the app)"
codesign --force --sign - --timestamp=none "$RES/whisper-cli"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP" || echo "   (verify note above is expected for ad-hoc)"

echo "==> Sanity: bundled whisper-cli runs from its bundled location"
"$RES/whisper-cli" --help >/dev/null 2>&1 && echo "   OK: bundled whisper-cli executes"

echo "==> Creating styled .dmg"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME"
BG_SRC="$PROJECT_DIR/assets/dmg/background.tiff"
ICON_SRC="$APP/Contents/Resources/AppIcon.icns"
SETTINGS="$PROJECT_DIR/scripts/dmg_settings.py"

# Prefer dmgbuild: it writes the Finder layout (background, icon positions, window,
# volume icon) directly into the DMG — no Finder/AppleScript, so it works headless
# (background shells, CI) and deterministically. Best-effort install if missing.
if ! python3 -c 'import dmgbuild' >/dev/null 2>&1; then
  python3 -m pip install --user --quiet dmgbuild >/dev/null 2>&1 || true
fi

if python3 -c 'import dmgbuild' >/dev/null 2>&1 && [ -f "$BG_SRC" ]; then
  # Explicit image size with headroom — dmgbuild's auto-sizing under-counts the
  # 2.9 GB bundled model (Full) and silently drops it.
  APP_MB=$(du -sm "$APP" | cut -f1)
  DMG_SIZE_MB=$(( APP_MB + APP_MB / 5 + 100 ))
  python3 -m dmgbuild \
    -s "$SETTINGS" \
    -D app="$APP" \
    -D background="$BG_SRC" \
    -D icon="$ICON_SRC" \
    -D size="${DMG_SIZE_MB}M" \
    "$APP_NAME" "$DIST_DIR/$DMG_NAME" >/dev/null
  echo "   OK: styled installer window (dmgbuild)"
else
  echo "   note: dmgbuild/background unavailable — building a plain DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$DMG_NAME" >/dev/null
  rm -rf "$STAGE"
fi

echo "==> Done"
echo "    Edition:   $EDITION"
echo "    App size:  $(du -sh "$APP" | cut -f1)"
echo "    DMG:       $DIST_DIR/$DMG_NAME  ($(du -sh "$DIST_DIR/$DMG_NAME" | cut -f1))"
