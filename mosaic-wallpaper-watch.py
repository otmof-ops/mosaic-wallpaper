#!/usr/bin/env python3
"""mosaic-wallpaper-watch — recompose the wallpaper the instant the monitors change.

Subscribes to GNOME/Mutter's `MonitorsChanged` signal (screen off/on, hotplug, rearrange) and,
when it fires, (optionally) re-applies your saved monitor layout and then recomposes the wallpaper
for the new arrangement. Runs as a plain systemd --user service — session bus only, no X auth.

GNOME/Mutter only (that's where the signal lives). On other desktops the timer still rotates the
wallpaper; you just don't get the instant response to a monitor change.
"""
import os, subprocess

HERE    = os.path.dirname(os.path.abspath(__file__))
COMPOSE = os.path.join(HERE, "mosaic-wallpaper.py")
LAYOUT  = os.path.join(HERE, "monitor-layout.py")
def _xdg(var, d): return os.environ.get(var) or os.path.expanduser(d)
LAYOUT_CFG = os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), "mosaic-wallpaper", "layout.json")

_pending = None

def _env():
    e = dict(os.environ)
    rt = e.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    e.setdefault("XDG_RUNTIME_DIR", rt)
    e.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={rt}/bus")
    return e

def recompose():
    global _pending
    _pending = None
    # 1) Restore the saved monitor arrangement, if one was configured (idempotent no-op otherwise).
    if os.path.isfile(LAYOUT_CFG):
        try:
            subprocess.run(["python3", LAYOUT], env=_env(),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        except Exception:
            pass
    # 2) Repaint the wallpaper for the (now correct) layout.
    try:
        subprocess.run(["python3", COMPOSE], env=_env(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    except Exception:
        pass
    return False  # GLib one-shot

def on_change(*_a):
    # One off/on can emit several signals; coalesce to a single recompose ~1.5s after it settles.
    global _pending
    from gi.repository import GLib
    if _pending:
        GLib.source_remove(_pending)
    _pending = GLib.timeout_add(1500, recompose)

def main():
    try:
        import gi
        from gi.repository import Gio, GLib
    except Exception:
        print("mosaic-wallpaper-watch: requires python3-gi + a GNOME session; exiting.")
        return 0
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.signal_subscribe("org.gnome.Mutter.DisplayConfig", "org.gnome.Mutter.DisplayConfig",
                         "MonitorsChanged", "/org/gnome/Mutter/DisplayConfig", None,
                         Gio.DBusSignalFlags.NONE, on_change)
    GLib.timeout_add(2000, recompose)   # once at startup, in case things changed while we were down
    GLib.MainLoop().run()

if __name__ == "__main__":
    main()
