# dmgbuild settings for Kleyn's installer DMG. Run through scripts/make-dmg.sh,
# which passes the paths below with -D.
#
# The window size and icon positions must match Design/DMG/make-background.swift.

import os.path

app = defines["app"]              # path to Kleyn.app
background = defines["background"]  # path to Design/DMG/background.tiff
app_name = os.path.basename(app)

# Contents
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# The mounted volume uses Kleyn's icon.
volume_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
if os.path.exists(volume_icon):
    icon = volume_icon

# Window (the background path is set above)
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False

# Icons
icon_size = 128
text_size = 13
show_icon_preview = False
arrange_by = None
icon_locations = {
    app_name: (165, 190),
    "Applications": (495, 190),
}
