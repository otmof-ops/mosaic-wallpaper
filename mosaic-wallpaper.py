#!/usr/bin/env python3
"""mosaic-wallpaper — a resolution-matched, per-monitor wallpaper composer for any Linux box.

It auto-detects your monitors (their count, resolution and arrangement), draws one image per
monitor from a configured image pool, composes a single desktop-sized canvas where each monitor's
region is filled with its own image, and sets it as the wallpaper through whatever backend your
desktop uses. On a timer it rotates — either every monitor at once, or one monitor at a time.

Nothing is hard-coded to a particular machine: monitors, resolutions, image source, paths and the
wallpaper backend are all detected or read from config.

Usage:
  mosaic-wallpaper.py               refresh EVERY monitor with a fresh random image
  mosaic-wallpaper.py <index>       refresh only monitor <index> (used by staggered timers)
  mosaic-wallpaper.py --detect      print the detected monitor layout and backend, then exit
  mosaic-wallpaper.py --dry-run     compose the canvas but do NOT change the wallpaper
  mosaic-wallpaper.py --print-config  show the effective config and where it lives

Config:  $XDG_CONFIG_HOME/mosaic-wallpaper/config.ini   (see config.example.ini)
"""
import os, sys, re, json, time, random, subprocess, urllib.parse, configparser, shutil

# ---------------------------------------------------------------------------- paths (XDG, no hard-coded uid)
def _xdg(var, default):
    v = os.environ.get(var)
    return v if v else os.path.expanduser(default)

CONFIG_DIR = os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), "mosaic-wallpaper")
CACHE_DIR  = os.path.join(_xdg("XDG_CACHE_HOME",  "~/.cache"),  "mosaic-wallpaper")
CONFIG     = os.path.join(CONFIG_DIR, "config.ini")
LAYOUT_CACHE = os.path.join(CACHE_DIR, "layout.json")     # last good detected layout
INDEX      = os.path.join(CACHE_DIR, "image-index.list")  # cached list of candidate images
STATE      = os.path.join(CACHE_DIR, "monitor-state.list")# current image per monitor
LASTF      = os.path.join(CACHE_DIR, "last-output")       # last A/B canvas written
os.makedirs(CACHE_DIR, exist_ok=True)

# ---------------------------------------------------------------------------- config
DEFAULTS = {
    "source":    {"directories": "~/Pictures", "extensions": "jpg jpeg png webp bmp gif",
                  "recursive": "true", "index_max_age_hours": "24"},
    "filter":    {"min_long_edge": "700", "min_bytes": "15000",
                  "min_aspect": "0.20", "max_aspect": "3.5"},
    "compose":   {"mode": "fill", "background": "#000000", "jpeg_quality": "90"},
    "wallpaper": {"backend": "auto"},
}
def load_config():
    cp = configparser.ConfigParser()
    cp.read_dict(DEFAULTS)
    if os.path.isfile(CONFIG):
        cp.read(CONFIG)
    return cp
CFG = load_config()

def cfg(section, key, fallback=None):
    return CFG.get(section, key, fallback=fallback)

def source_dirs():
    raw = cfg("source", "directories", "~/Pictures")
    parts = re.split(r"[\n,]+", raw)
    return [os.path.expanduser(p.strip()) for p in parts if p.strip()]

# ---------------------------------------------------------------------------- environment detection
def env_with_bus():
    e = dict(os.environ)
    rt = e.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    e.setdefault("XDG_RUNTIME_DIR", rt)
    e.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={rt}/bus")
    return e

def _finalize(mons, source):
    if not mons:
        return None
    mons.sort(key=lambda d: (d["y"], d["x"]))
    cw = max(d["x"] + d["w"] for d in mons)
    ch = max(d["y"] + d["h"] for d in mons)
    return {"source": source, "canvas": [cw, ch], "monitors": mons}

def detect_mutter():
    """GNOME/Mutter via the session DBus. Works on Wayland *and* X11 GNOME, headless-safe."""
    try:
        import gi
        from gi.repository import Gio
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        ret = bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                            "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None,
                            Gio.DBusCallFlags.NONE, 5000, None)
        _serial, monitors, logical, _props = ret.unpack()
        cur = {}
        for spec, modes, _mp in monitors:
            for mode in modes:
                if mode[6].get("is-current"):
                    cur[spec[0]] = (mode[1], mode[2])
        mons = []
        for x, y, scale, _tr, _prim, conns, _lp in logical:
            conn = conns[0][0]; wh = cur.get(conn)
            if wh:
                mons.append({"name": conn, "x": int(x), "y": int(y),
                             "w": round(wh[0] / scale), "h": round(wh[1] / scale)})
        return _finalize(mons, "mutter")
    except Exception:
        return None

def detect_sway():
    """sway / wlroots compositors via `swaymsg -t get_outputs`."""
    if not shutil.which("swaymsg"):
        return None
    try:
        out = subprocess.check_output(["swaymsg", "-t", "get_outputs", "-r"],
                                      text=True, env=env_with_bus(), timeout=10)
        data = json.loads(out); mons = []
        for o in data:
            if not o.get("active"):
                continue
            r = o["rect"]; sc = o.get("scale", 1) or 1
            mons.append({"name": o["name"], "x": int(r["x"]), "y": int(r["y"]),
                         "w": round(r["width"]), "h": round(r["height"])})
        return _finalize(mons, "sway")
    except Exception:
        return None

def detect_xrandr():
    """Any X11 desktop (KDE/XFCE/i3/…) via xrandr --listmonitors."""
    if not shutil.which("xrandr"):
        return None
    e = env_with_bus()
    for disp in [e.get("DISPLAY"), ":0", ":1", ":2"]:
        if not disp:
            continue
        e2 = dict(e); e2["DISPLAY"] = disp
        try:
            out = subprocess.check_output(["xrandr", "--listmonitors"], text=True,
                                          env=e2, stderr=subprocess.DEVNULL, timeout=10)
        except Exception:
            continue
        mons = []
        for line in out.splitlines():
            m = re.match(r"\s*\d+:\s+\+\*?(\S+)\s+(\d+)/\d+x(\d+)/\d+\+(\d+)\+(\d+)", line)
            if m:
                mons.append({"name": m.group(1), "x": int(m.group(4)), "y": int(m.group(5)),
                             "w": int(m.group(2)), "h": int(m.group(3))})
        if mons:
            return _finalize(mons, "xrandr")
    return None

def detect_layout():
    """Best available: Mutter (GNOME) → sway → xrandr (X11). Falls back to the last cached layout."""
    layout = detect_mutter() or detect_sway() or detect_xrandr()
    if layout:
        try: json.dump(layout, open(LAYOUT_CACHE, "w"), indent=2)
        except Exception: pass
        return layout
    try:
        return json.load(open(LAYOUT_CACHE))
    except Exception:
        return None

# ---------------------------------------------------------------------------- image pool
def build_index():
    dirs = [d for d in source_dirs() if os.path.isdir(d)]
    exts = set("." + x.strip().lower().lstrip(".") for x in cfg("source", "extensions").split())
    recursive = cfg("source", "recursive", "true").lower() in ("1", "true", "yes", "on")
    paths = []
    for d in dirs:
        if recursive:
            for root, _dn, files in os.walk(d):
                if os.sep + "thumbnails" in root.lower() or os.sep + ".thumbnails" in root.lower():
                    continue
                for f in files:
                    if os.path.splitext(f)[1].lower() in exts:
                        paths.append(os.path.join(root, f))
        else:
            for f in os.listdir(d):
                if os.path.splitext(f)[1].lower() in exts:
                    paths.append(os.path.join(d, f))
    with open(INDEX, "w") as fh:
        fh.write("\n".join(paths) + ("\n" if paths else ""))
    return paths

def load_index():
    max_age = float(cfg("source", "index_max_age_hours", "24")) * 3600
    fresh = (os.path.exists(INDEX) and os.path.getsize(INDEX) > 0
             and (time.time() - os.path.getmtime(INDEX)) < max_age)
    if fresh:
        return [l.strip() for l in open(INDEX) if l.strip()]
    return build_index()

def is_good_image(p):
    """A usable wallpaper image: big enough, sane aspect, not a tiny icon/spacer/banner."""
    from PIL import Image
    try:
        if os.path.getsize(p) < int(cfg("filter", "min_bytes")):
            return False
        with Image.open(p) as im:
            w, h = im.size
    except Exception:
        return False
    if not h:
        return False
    long_edge = max(w, h); asp = w / h
    return (long_edge >= int(cfg("filter", "min_long_edge"))
            and float(cfg("filter", "min_aspect")) <= asp <= float(cfg("filter", "max_aspect")))

def pick(pages):
    for _ in range(30):
        p = random.choice(pages)
        if os.path.isfile(p) and is_good_image(p):
            return p
    for _ in range(10):
        p = random.choice(pages)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p
    return random.choice(pages)

# ---------------------------------------------------------------------------- compose
def _bg_rgb():
    c = cfg("compose", "background", "#000000").lstrip("#")
    try:
        return tuple(int(c[i:i+2], 16) for i in (0, 2, 4))
    except Exception:
        return (0, 0, 0)

def compose(layout, state):
    from PIL import Image
    cw, ch = layout["canvas"]
    mode = cfg("compose", "mode", "fill").lower()
    canvas = Image.new("RGB", (cw, ch), _bg_rgb())
    for mon, page in zip(layout["monitors"], state):
        try:
            img = Image.open(page).convert("RGB")
        except Exception:
            continue
        mw, mh = mon["w"], mon["h"]; iw, ih = img.size
        if mode == "stretch":
            img = img.resize((mw, mh), Image.LANCZOS); px, py = mon["x"], mon["y"]
        elif mode == "fill":  # cover the whole monitor, cropping overflow
            scale = max(mw / iw, mh / ih)
            nw, nh = max(1, int(iw * scale)), max(1, int(ih * scale))
            img = img.resize((nw, nh), Image.LANCZOS)
            left = (nw - mw) // 2; top = (nh - mh) // 2
            img = img.crop((left, top, left + mw, top + mh)); px, py = mon["x"], mon["y"]
        else:                 # "fit": whole image on the background, letterboxed
            scale = min(mw / iw, mh / ih)
            nw, nh = max(1, int(iw * scale)), max(1, int(ih * scale))
            img = img.resize((nw, nh), Image.LANCZOS)
            px = mon["x"] + (mw - nw) // 2; py = mon["y"] + (mh - nh) // 2
        canvas.paste(img, (px, py))
    # Alternate A/B so cache-by-URI backends (GNOME) actually reload.
    last = open(LASTF).read().strip() if os.path.exists(LASTF) else ""
    out = os.path.join(CACHE_DIR, "canvas-%s.jpg" % ("B" if last.endswith("A.jpg") else "A"))
    canvas.save(out, "JPEG", quality=int(cfg("compose", "jpeg_quality", "90")))
    open(LASTF, "w").write(out)
    return out

# ---------------------------------------------------------------------------- wallpaper backends
def _desktop():
    return (os.environ.get("XDG_CURRENT_DESKTOP", "") + " "
            + os.environ.get("XDG_SESSION_DESKTOP", "")).lower()

def choose_backend(layout):
    want = cfg("wallpaper", "backend", "auto").lower()
    if want != "auto":
        return want
    if "gnome" in _desktop() or "unity" in _desktop() or "cinnamon" in _desktop():
        if shutil.which("gsettings"):
            return "gnome"
    if layout and layout.get("source") == "sway":
        return "sway"
    if os.environ.get("DISPLAY"):  # any X11 desktop
        if shutil.which("feh"):        return "feh"
        if shutil.which("xwallpaper"): return "xwallpaper"
    if shutil.which("gsettings"):      return "gnome"   # last resort
    return "none"

def set_wallpaper(backend, canvas_path, layout):
    env = env_with_bus()
    if backend == "gnome":
        uri = "file://" + urllib.parse.quote(canvas_path)
        for k, v in [("picture-uri", uri), ("picture-uri-dark", uri),
                     ("picture-options", "spanned"),
                     ("primary-color", cfg("compose", "background", "#000000"))]:
            subprocess.run(["gsettings", "set", "org.gnome.desktop.background", k, v], env=env)
        return True
    if backend == "feh":
        subprocess.run(["feh", "--no-fehbg", "--bg-fill", canvas_path], env=env); return True
    if backend == "xwallpaper":
        subprocess.run(["xwallpaper", "--zoom", canvas_path], env=env); return True
    if backend == "sway":
        # sway can't span one image; crop the composite per output and set each.
        from PIL import Image
        big = Image.open(canvas_path)
        ok = False
        for mon in layout["monitors"]:
            crop = big.crop((mon["x"], mon["y"], mon["x"] + mon["w"], mon["y"] + mon["h"]))
            cp = os.path.join(CACHE_DIR, "sway-%s.jpg" % re.sub(r"\W+", "_", mon["name"]))
            crop.save(cp, "JPEG", quality=90)
            r = subprocess.run(["swaymsg", "output", mon["name"], "bg", cp, "fill"], env=env)
            ok = ok or r.returncode == 0
        return ok
    return False

# ---------------------------------------------------------------------------- state
def load_state(n):
    state = [l.strip() for l in open(STATE)] if os.path.exists(STATE) else []
    while len(state) < n:
        state.append("")
    return state[:n]

def save_state(state):
    open(STATE, "w").write("\n".join(state) + "\n")

# ---------------------------------------------------------------------------- main
def main():
    args = sys.argv[1:]
    if "--print-config" in args:
        print(f"config file: {CONFIG}  ({'exists' if os.path.isfile(CONFIG) else 'using built-in defaults'})")
        CFG.write(sys.stdout); return 0
    layout = detect_layout()
    if not layout:
        print("mosaic-wallpaper: could not detect any monitors (no Mutter/sway/xrandr, no cache).",
              file=sys.stderr); return 2
    backend = choose_backend(layout)
    if "--detect" in args:
        print(f"detected via: {layout['source']}   backend: {backend}   canvas: {layout['canvas'][0]}x{layout['canvas'][1]}")
        for i, m in enumerate(layout["monitors"]):
            print(f"  [{i}] {m['name']:<12} {m['w']}x{m['h']} @ ({m['x']},{m['y']})")
        return 0

    pages = load_index()
    if not pages:
        print(f"mosaic-wallpaper: no images found in {source_dirs()} — set [source] directories in {CONFIG}",
              file=sys.stderr); return 3

    n = len(layout["monitors"]); state = load_state(n)
    which = next((a for a in args if not a.startswith("-")), "all")
    if which == "all":
        state = [pick(pages) for _ in range(n)]
    else:
        try:
            i = int(which)
            if 0 <= i < n:
                state[i] = pick(pages)
        except ValueError:
            pass
    for i in range(n):  # backfill missing/broken
        if not state[i] or not os.path.isfile(state[i]):
            state[i] = pick(pages)

    canvas = compose(layout, state)
    save_state(state)

    if "--dry-run" in args:
        print(f"[dry-run] composed {layout['canvas'][0]}x{layout['canvas'][1]} -> {canvas} (wallpaper NOT changed)")
        return 0
    if backend == "none":
        print(f"mosaic-wallpaper: no supported wallpaper backend found for this desktop.\n"
              f"  Install one of: feh / xwallpaper (X11), or run GNOME/sway. Canvas is at {canvas}",
              file=sys.stderr); return 4
    ok = set_wallpaper(backend, canvas, layout)
    names = [os.path.basename(os.path.dirname(p)) or os.path.basename(p) for p in state]
    print(f"{'refreshed' if ok else 'composed (set FAILED)'}: {which} via {backend} | {names}")
    return 0 if ok else 5

if __name__ == "__main__":
    sys.exit(main())
