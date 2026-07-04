# dmgbuild settings for the Tscribe installer window.
#
# Writes the Finder layout (background, icon positions, window) directly into the
# DMG — no Finder/AppleScript, so it works headless (background shells, CI) and
# deterministically. Invoked by scripts/package.sh:
#
#   python3 -m dmgbuild -s scripts/dmg_settings.py \
#       -D app=<Tscribe.app> -D background=<background.tiff> -D icon=<AppIcon.icns> \
#       "Tscribe" dist/<name>.dmg
#
# Icon positions here must match the arrow/glow in scripts/DMGBackgroundGen.swift.

import os.path

app = defines["app"]
appname = os.path.basename(app)

# Contents: the app plus the Applications drop target.
files = [app]
symlinks = {"Applications": "/Applications"}

# Compressed, read-only output.
format = "UDZO"

# Explicit image size (e.g. "3600M"). dmgbuild's auto-sizing under-counts the
# 2.9 GB bundled model and silently drops it, so package.sh passes a size with
# headroom for the Full edition.
if "size" in defines:
    size = defines["size"]

# Mounted-volume icon.
icon = defines.get("icon")

# Window + icon-view styling.
background = defines.get("background", "assets/dmg/background.tiff")
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
window_rect = ((200, 120), (640, 400))
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    appname: (170, 200),
    "Applications": (470, 200),
}
