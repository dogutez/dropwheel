# dmgbuild settings for Dropwheel.dmg (used by scripts/make-dmg.sh).
# The window shows the app on the left and an Applications shortcut on the right,
# over the background drawn by scripts/make-dmg-background.swift.

app = defines["app"]
background = defines["background"]

format = "ULFO"  # LZFSE-compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    "Dropwheel.app": (170, 190),
    "Applications": (490, 190),
}
