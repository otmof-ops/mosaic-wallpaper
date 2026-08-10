# mosaic-wallpaper

A resolution-matched, per-monitor wallpaper composer for Linux — and a small set of
`systemd --user` timers that keep it fresh. Every monitor gets its **own** image, cropped to
its **exact** resolution and stitched into one canvas, so nothing is stretched, squashed, or
smeared across the gap between screens.

It auto-detects everything — number of monitors, their resolutions and positions, the display
server, and the right way to set the wallpaper — so the same install works on a laptop, a
triple-4K desktop, or a headless box, with no per-machine editing.

```
┌────────────────────┐┌────────────────────┐┌──────────────┐
│      3840×2160     ││      3840×2160     ││  2560×1440   │
│    fresh image A   ││    fresh image B   ││ fresh img C  │   ← one canvas, three regions,
│   cropped to fit   ││   cropped to fit   ││ cropped fit  │     each matched to its screen
└────────────────────┘└────────────────────┘└──────────────┘
```

## Why

Most "wallpaper across multiple monitors" tools assume every screen is the same size and in a
tidy row. Real desks aren't like that — mixed resolutions, mixed DPI, a portrait screen, a
tablet stacked below. This composes against the **actual** monitor rectangles reported by the
system, so each region is pixel-correct regardless of the arrangement.

## What's in the box

| Command | What it does |
|---|---|
| `mosaic-wallpaper.py` | Detect monitors → pick an image per monitor → crop/fit each to its resolution → compose one canvas → set it as the wallpaper. |
| `monitor-layout.py` | *(GNOME)* Save your monitor arrangement keyed by **model**, and restore it at login — fixes GPUs that renumber connectors and make GNOME "forget" your layout. |
| `mosaic-wallpaper-watch.py` | *(GNOME)* Watch for monitor changes (unplug, resolution change, screen off/on) and recompose instantly. |

## Setup (the easy way)

```sh
git clone <this repo> mosaic-wallpaper
cd mosaic-wallpaper
./setup.sh
```

`setup.sh` is a guided wizard. It **scans your machine** (monitors, resolutions, display server,
wallpaper backend) and then asks you only three things:

1. **which folder** of images to use,
2. **a preset** for what kind of images they are, and
3. **how often** to rotate.

It shows you the detected monitors to confirm, writes the config, installs the scripts + timers,
optionally saves your monitor layout (GNOME) and switches on weekly auto-updates, and paints the
first canvas — all in one go. Point it at a directory and you're done.

**Presets** (tune the quality filter + fit; pick at the prompt or with `--preset`):

| Preset | For | Picks |
|---|---|---|
| `standard` | general photos & images *(default)* | ≥900px, sensible aspect range |
| `wallpapers` | curated hi-res wallpapers | ≥1280px, mostly-landscape |
| `comics` | comic / manga pages | ≥700px, allows tall art, drops banners/thumbnails |
| `any` | everything | no filtering |

**Fully automated** (no prompts — great for provisioning a new box):

```sh
./setup.sh --yes --dir ~/Pictures/wallpapers --preset wallpapers --interval 30min --auto-update
./setup.sh --list-presets        # see the presets
./setup.sh --help                # all flags (--backend, --save-layout, --auto-update, --no-enable, …)
```

**Dependencies:** Python 3, [Pillow](https://python-pillow.org/) (image compositing), and — for
the GNOME-only layout/watch features — `python3-gi`. Setup prints the right package command for
apt / dnf / pacman if anything's missing.

## Install (the manual way)

If you'd rather not use the wizard, `install.sh` just places files and enables a default 30-min
timer, using a stock config you edit yourself:

```sh
./install.sh                 # install + enable, writes a default config
./install.sh --no-enable     # install files but don't start any services
./install.sh --no-systemd    # scripts + config only (use cron / your DE to schedule)
```

## Updating

```sh
./update.sh                  # pull the latest and refresh in place (no-op if already current)
./update.sh --check          # is a new version available? (changes nothing)
./update.sh --enable-auto    # check weekly and self-update, automatically
./update.sh --disable-auto   # stop auto-updates
```

Updates are **fast-forward only** and never touch your config or change what you've enabled — if the
checkout has local commits or uncommitted edits, `update.sh` refuses rather than clobber them.
Auto-update runs as a weekly `systemd --user` timer that quietly does nothing when you're already
current; the setup wizard offers to switch it on.

## Removing

```sh
./uninstall.sh               # remove scripts + units (keeps your config)
./uninstall.sh --purge       # also delete config + cache
./uninstall.sh --nuke        # everything: units, scripts, config, cache AND the cloned repo — no trace
```

## Configure

Everything lives in `~/.config/mosaic-wallpaper/config.ini` (see [`config.example.ini`](config.example.ini)).
The one line you'll actually want to change is where images come from:

```ini
[source]
directories = ~/Pictures/wallpapers, ~/Downloads/art
```

Point it at any folders of images — a wallpaper collection, a photo library, a comic/manga
library, whatever. The filter block skips anything that would make a poor wallpaper (icons,
banners, tiny thumbnails). Fitting mode (`fill` / `fit` / `stretch`), background colour and JPEG
quality are all there too.

## Use

```sh
mosaic-wallpaper.py              # refresh every monitor with a fresh random image
mosaic-wallpaper.py 0            # refresh only monitor 0 (used by staggered timers)
mosaic-wallpaper.py --detect     # show detected monitors + chosen backend, then exit
mosaic-wallpaper.py --dry-run    # compose the canvas but DON'T change the wallpaper
mosaic-wallpaper.py --print-config
```

`--detect` is the first thing to run on a new box — it tells you what it sees:

```
detected via: mutter   backend: gnome   canvas: 7680x3600
  [0] HDMI-1       3840x2160 @ (0,0)
  [1] HDMI-0       3840x2160 @ (3840,0)
  [2] DP-1         2560x1440 @ (2560,2160)
```

## How auto-detection works

**Monitor layout** is resolved from the best available source, in order:

1. **GNOME / Mutter** — `org.gnome.Mutter.DisplayConfig` over the session bus (logical geometry, scale-aware).
2. **sway / wlroots** — `swaymsg -t get_outputs`.
3. **X11** — `xrandr --listmonitors`.
4. **Cache** — the last known-good layout, so a headless timer still has something to work with.

**Wallpaper backend** is chosen to match the desktop: `gsettings` (GNOME/Cinnamon/Unity, X11 or
Wayland, painted `spanned`), per-output backgrounds on **sway**, or `feh` / `xwallpaper` for
plain X11 (i3, XFCE, KDE-on-X11…). Force one with `[wallpaper] backend =` if you like.

Because layout and resolution are read live every run, moving a monitor, changing a resolution,
or installing on a completely different machine needs **no** config edits.

## Keeping a monitor arrangement (GNOME)

Some GPUs renumber their outputs every boot (`HDMI-1` → `HDMI-0`), so GNOME loses your carefully
arranged screens. `monitor-layout.py` fixes it by keying the arrangement to each monitor's
**model**:

```sh
# arrange your monitors once in Settings, then:
monitor-layout.py --save     # remember this arrangement
monitor-layout.py --show     # compare current vs saved
monitor-layout.py            # re-apply if drifted (idempotent; run at login by the service)
```

Once saved, the `monitor-layout.service` restores it at every login and the watcher re-applies
it whenever the monitors change — right before recomposing the wallpaper.

## The systemd units

Installed to `~/.config/systemd/user/`, all path-agnostic (`%h` / `%t`, no hardcoded home or uid):

| Unit | Role |
|---|---|
| `mosaic-wallpaper.timer` → `mosaic-wallpaper@all.service` | Rotate the wallpaper every 30 min. |
| `mosaic-wallpaper@.service` | Template — `@all` refreshes all, `@0`/`@1`… refresh one monitor (for staggered per-screen timers). |
| `mosaic-wallpaper-watch.service` | *(GNOME)* Recompose the instant monitors change. |
| `monitor-layout.service` | *(GNOME)* Restore the saved arrangement at login. |

Change the cadence by editing `OnUnitActiveSec=` in the timer, then
`systemctl --user daemon-reload && systemctl --user restart mosaic-wallpaper.timer`.

Want each screen to change on its own staggered schedule instead of all at once? Copy the timer
per monitor pointing at `mosaic-wallpaper@0.service`, `@1`, … with different `OnUnitActiveSec`.

## Troubleshooting

- **Nothing happens / no images** — set `[source] directories` and check `mosaic-wallpaper.py --print-config`.
- **"no supported wallpaper backend"** — on plain X11 install `feh` or `xwallpaper`; on GNOME/sway it's automatic.
- **Wrong monitors detected** — run `--detect`; if it falls back to `cache`, your session has no Mutter/sway/xrandr (e.g. run from a non-graphical context without a warm cache).
- **GNOME doesn't reload the image** — handled: the composer alternates between two output filenames so `gsettings` can't cache-freeze the URI.
- **Timer doesn't run when logged out** — the installer enables `loginctl enable-linger`; if that failed (permissions), timers only run while you're logged in.

## Portability notes

Tested on GNOME/X11 with three mixed-resolution monitors (Pillow 10.2, Python 3.12). The layout
and backend abstractions cover GNOME, sway/wlroots and generic X11; the GNOME-specific
convenience features (`monitor-layout`, the change-watcher) degrade gracefully to "just the
timer" everywhere else. No root, no system files touched — everything is per-user under `~`.

## License

**Source-available — not open source.** Licensed under the **OFFTRACKMEDIA Studios Source-Available
Software License v1.0.0** (`OTM-IT-LIC-001/26`) — see [LICENSE](LICENSE). You may use, run, and modify
it for personal, internal-business, educational, and non-commercial purposes. **Reselling,
sublicensing, redistribution, and offering it as a product or hosted service are not permitted**
without OFFTRACKMEDIA Studios' prior written consent. All rights reserved to OTM; third-party
dependencies (Python, Pillow, PyGObject, …) keep their own licenses.
