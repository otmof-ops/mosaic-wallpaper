#!/usr/bin/env python3
"""monitor-layout — save and restore a GNOME monitor arrangement, keyed by monitor MODEL.

Some GPUs renumber their connectors on every boot (HDMI-1 becomes HDMI-0, DP-3 becomes DP-1…),
which makes GNOME "forget" your multi-monitor layout at each login. This keys the arrangement to
each monitor's *model* instead of its connector, so it survives the shuffle.

It is completely generic: you arrange your monitors once in Settings, run `--save`, and thereafter
`--apply` (run at login) restores that exact arrangement on this — or any — box.

Usage:
  monitor-layout.py --save     capture the CURRENT arrangement to config (do this once, set up)
  monitor-layout.py            apply the saved arrangement if not already correct (idempotent)
  monitor-layout.py --force    apply even if it looks correct (for testing)
  monitor-layout.py --show     print the current arrangement and the saved one

Config:  $XDG_CONFIG_HOME/mosaic-wallpaper/layout.json
Requires: GNOME/Mutter (uses org.gnome.Mutter.DisplayConfig over the session bus).
"""
import os, sys, json

def _xdg(var, default):
    v = os.environ.get(var)
    return v if v else os.path.expanduser(default)
CONFIG_DIR = os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), "mosaic-wallpaper")
LAYOUT = os.path.join(CONFIG_DIR, "layout.json")
TOL = 60  # px tolerance when deciding "already correct"

def _bus():
    import gi
    from gi.repository import Gio
    return Gio.bus_get_sync(Gio.BusType.SESSION, None), Gio

def get_state():
    bus, Gio = _bus()
    ret = bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                        "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None,
                        Gio.DBusCallFlags.NONE, 5000, None)
    return (bus, Gio) + ret.unpack()  # bus, Gio, serial, monitors, logical, props

def _current(monitors, logical):
    # model -> (connector, current-mode-id) ; connector -> (x, y, scale, primary)
    found, pos = {}, {}
    for spec, modes, _mp in monitors:
        conn, _vendor, product, _ser = spec
        curid = next((m[0] for m in modes if m[6].get("is-current")), None)
        if curid:
            found[product] = (conn, curid)
    for x, y, scale, _tr, primary, conns, _lp in logical:
        pos[conns[0][0]] = (int(x), int(y), float(scale), bool(primary))
    return found, pos

def cmd_save():
    _bus_, _Gio, _serial, monitors, logical, _props = get_state()
    found, pos = _current(monitors, logical)
    entries = []
    conn2model = {c: prod for prod, (c, _m) in found.items()}
    for conn, (x, y, scale, primary) in pos.items():
        model = conn2model.get(conn, conn)
        entries.append({"model": model, "x": x, "y": y, "scale": scale, "primary": primary})
    entries.sort(key=lambda e: (e["y"], e["x"]))
    os.makedirs(CONFIG_DIR, exist_ok=True)
    json.dump({"_comment": "Desired GNOME monitor arrangement, keyed by model. Edit or re-run --save.",
               "monitors": entries}, open(LAYOUT, "w"), indent=2)
    print(f"Saved current arrangement ({len(entries)} monitors) -> {LAYOUT}:")
    for e in entries:
        print(f"  {e['model']:<24} @ ({e['x']},{e['y']}) scale {e['scale']}{'  [primary]' if e['primary'] else ''}")
    return 0

def cmd_show():
    try:
        _b, _g, _s, monitors, logical, _p = get_state()
        found, pos = _current(monitors, logical)
        conn2model = {c: prod for prod, (c, _m) in found.items()}
        print("CURRENT:")
        for conn, (x, y, scale, primary) in sorted(pos.items(), key=lambda kv: (kv[1][1], kv[1][0])):
            print(f"  {conn2model.get(conn, conn):<24} @ ({x},{y}) scale {scale}{'  [primary]' if primary else ''}")
    except Exception as e:
        print(f"CURRENT: (unavailable — GNOME/Mutter only) {e}")
    print(f"SAVED ({LAYOUT}):")
    if os.path.isfile(LAYOUT):
        for e in json.load(open(LAYOUT))["monitors"]:
            print(f"  {e['model']:<24} @ ({e['x']},{e['y']}) scale {e['scale']}{'  [primary]' if e.get('primary') else ''}")
    else:
        print("  (none — run --save first)")
    return 0

def cmd_apply(force):
    if not os.path.isfile(LAYOUT):
        print("monitor-layout: no saved layout — run `monitor-layout.py --save` once first.", file=sys.stderr)
        return 1
    desired = json.load(open(LAYOUT))["monitors"]
    bus, Gio, serial, monitors, logical, _props = get_state()
    found, pos = _current(monitors, logical)  # found: model->(conn,modeid)
    plan = []
    for d in desired:
        hit = next(((c, mid) for prod, (c, mid) in found.items() if d["model"] in prod), None)
        if not hit:
            print(f"[layout] '{d['model']}' not connected — refusing to apply a partial layout", file=sys.stderr)
            return 0
        plan.append((hit[0], hit[1], d["x"], d["y"], float(d.get("scale", 1.0)), bool(d.get("primary"))))
    if not force:
        ok = all(abs(pos.get(c, (9e9, 9e9))[0] - x) <= TOL and abs(pos.get(c, (9e9, 9e9))[1] - y) <= TOL
                 for c, _mid, x, y, _s, _p in plan)
        if ok:
            print("[layout] already correct — no change")
            return 0
    from gi.repository import GLib
    lm = [(x, y, s, 0, primary, [(conn, mid, {})]) for conn, mid, x, y, s, primary in plan]
    args = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 2, lm, {}))  # 2 = PERSISTENT
    bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                  "org.gnome.Mutter.DisplayConfig", "ApplyMonitorsConfig", args, None,
                  Gio.DBusCallFlags.NONE, 5000, None)
    print("[layout] applied:", ", ".join(f"{c}@({x},{y})" for c, _m, x, y, _s, _p in plan))
    return 0

def main():
    args = sys.argv[1:]
    try:
        if "--save" in args:  return cmd_save()
        if "--show" in args:  return cmd_show()
        return cmd_apply("--force" in args)
    except ModuleNotFoundError:
        print("monitor-layout: requires python3-gi (GObject introspection) and a GNOME session.", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"monitor-layout: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
