"""Finder layout for the drag-and-drop installer, evaluated by dmgbuild."""
import os

application = defines['app']
format = 'UDZO'
filesystem = 'HFS+'
compression_level = 9
size = None
files = [application]
symlinks = {'Applications': '/Applications'}
badge_icon = os.path.join(application, 'Contents', 'Resources', 'HarmonyCast.icns')
background = defines['background']
window_rect = ((280, 160), (720, 440))
icon_locations = {'Harmony Cast.app': (180, 216), 'Applications': (540, 216)}
icon_size = 128
text_size = 14
show_icon_preview = False
show_status_bar = False
show_toolbar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
scroll_position = (0, 0)
