#!/bin/bash
set -euo pipefail

# Builds a styled .dmg with the installer window laid out by Finder (background,
# icon positions, window size, volume icon). Finder authors the background
# reference, which is the only kind macOS 26's Finder resolves — dmgbuild's
# synthesized alias does not render there. Requires a GUI login session (works
# locally; not on headless CI — see the DS_Store template path in package.sh).
#
# Usage: style-dmg.sh <app> <volume-name> <background.png> <out.dmg> [icon.icns]

APP="$1"; VOL="$2"; BG="$3"; OUT="$4"; ICON="${5:-}"

# Detach any stale mount of this volume name (incl. " 1" collisions).
for stale in "/Volumes/$VOL" "/Volumes/$VOL "*; do
  [ -d "$stale" ] && hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.png"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + $(du -sm "$STAGE" | cut -f1) / 5 + 100 ))
RW="$(mktemp -u).dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW" >/dev/null

ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEV="$(printf '%s\n' "$ATTACH" | awk '/^\/dev\//{d=$1} END{print d}')"
MNT="/Volumes/$VOL"   # deterministic: we set -volname and detached stale mounts above

# Volume icon (optional).
if [ -n "$ICON" ] && cp "$ICON" "$MNT/.VolumeIcon.icns" 2>/dev/null; then
  SetFile -a C "$MNT" 2>/dev/null || true
fi

osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 13
    set background picture of vo to file ".background:background.png"
    set position of item "$(basename "$APP")" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    update without registering applications
    delay 3
    close
  end tell
end tell
APPLESCRIPT

sync; sync
# Capture the Finder-authored .DS_Store so it can be reused headlessly (CI).
DS_OUT="${DS_STORE_OUT:-}"
[ -n "$DS_OUT" ] && cp "$MNT/.DS_Store" "$DS_OUT" 2>/dev/null || true

hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1 || true

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"
echo "styled DMG: $OUT (volume '$VOL')"
