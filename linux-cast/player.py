#!/usr/bin/python3
"""Unprivileged Miracast playback window."""

import argparse
import ipaddress
import signal
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst

from cast import player_pipeline


def main(address):
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, Gtk
    Gst.init(None)
    window = Gtk.Window(title="鸿蒙投屏")
    window.set_default_size(960, 540)
    header = Gtk.HeaderBar(title="鸿蒙投屏", show_close_button=True)
    button = Gtk.Button.new_from_icon_name("view-fullscreen-symbolic", Gtk.IconSize.BUTTON)
    button.set_tooltip_text("全屏（F11）")
    header.pack_end(button)
    window.set_titlebar(header)

    pipeline = Gst.parse_launch(player_pipeline(ipaddress.IPv4Address(address)))
    window.add(pipeline.get_by_name("screen").get_property("widget"))
    fullscreen = False
    exit_code = 0

    def toggle_fullscreen(*_args):
        if fullscreen:
            window.unfullscreen()
        else:
            window.fullscreen()

    def state_changed(_window, event):
        nonlocal fullscreen
        fullscreen = bool(event.new_window_state & Gdk.WindowState.FULLSCREEN)
        header.set_visible(not fullscreen)

    def key_pressed(_window, event):
        if event.keyval == Gdk.KEY_F11:
            toggle_fullscreen()
            return True
        if event.keyval == Gdk.KEY_Escape and fullscreen:
            window.unfullscreen()
            return True
        return False

    def pipeline_error(_bus, message):
        nonlocal exit_code
        error, _debug = message.parse_error()
        print(error.message, file=sys.stderr)
        exit_code = 1
        Gtk.main_quit()

    button.connect("clicked", toggle_fullscreen)
    window.connect("key-press-event", key_pressed)
    window.connect("window-state-event", state_changed)
    window.connect("destroy", lambda _window: Gtk.main_quit())
    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message::error", pipeline_error)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, Gtk.main_quit)
    window.show_all()
    try:
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            return 1
        Gtk.main()
        return exit_code
    finally:
        pipeline.set_state(Gst.State.NULL)
        bus.remove_signal_watch()


def embedded(address, xid):
    gi.require_version("GstVideo", "1.0")
    from gi.repository import GstVideo

    Gst.init(None)
    # XVideo scales to the drawable without a caps renegotiation on every resize.
    # XWayland may not expose XVideo, so retain the software sink as a fallback.
    video = "ximagesink"
    accelerated = Gst.ElementFactory.make("xvimagesink")
    if accelerated is not None:
        try:
            if accelerated.set_state(Gst.State.READY) != Gst.StateChangeReturn.FAILURE:
                video = "xvimagesink"
        finally:
            accelerated.set_state(Gst.State.NULL)
    pipeline = Gst.parse_launch(player_pipeline(address, video=video))
    sink = pipeline.get_by_name("screen")
    GstVideo.VideoOverlay.set_window_handle(sink, xid)
    loop = GLib.MainLoop()
    exit_code = 0

    def error_received(_bus, message):
        nonlocal exit_code
        error, _debug = message.parse_error()
        print(error.message, file=sys.stderr)
        exit_code = 1
        loop.quit()

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message::error", error_received)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, loop.quit)
    try:
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            return 1
        loop.run()
        return exit_code
    finally:
        pipeline.set_state(Gst.State.NULL)
        bus.remove_signal_watch()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("address", type=ipaddress.IPv4Address)
    parser.add_argument("--xid", type=int)
    args = parser.parse_args()
    sys.exit(embedded(args.address, args.xid) if args.xid else main(args.address))
