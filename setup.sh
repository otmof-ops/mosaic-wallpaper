#!/usr/bin/env bash
# mosaic-wallpaper setup wizard — point it at a folder, pick a preset, done.
#
# Scans your environment (monitors, resolutions, display server, wallpaper
# backend) and runs off that automatically. All you supply is: which folder of
# images, which content preset, and how often to rotate. Everything else is
# detected. Re-runnable; backs up any existing config.
#
# Interactive:
#   ./setup.sh
#
# Fully automated (no prompts):
#   ./setup.sh --yes --dir ~/Pictures/wallpapers --preset wallpapers --interval 30min
#
# Options:
#   --dir PATH         folder of images to use
#   --preset NAME      standard | wallpapers | comics | any   (see --list-presets)
#   --interval VALUE   15min | 30min | 60min | 5min | daily | off
#   --backend NAME     auto | gnome | sway | feh | xwallpaper   (default: auto)
#   --save-layout      remember the current monitor arrangement (GNOME)
#   --no-save-layout   don't touch the monitor arrangement
#   --auto-update      check weekly and self-update (fast-forward only)
#   --no-auto-update   don't set up automatic updates
#   --no-enable        configure everything but don't start the timer/services
#   --yes              accept defaults, ask nothing (needs --dir)
#   --list-presets     print the presets and exit
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/mosaic-wallpaper"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CFG="$CFGDIR/config.ini"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
head2(){ printf '\n\033[1;35m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- presets: NAME → min_long_edge min_bytes min_aspect max_aspect fit_mode | description
preset_row() { case "$1" in
  standard)   echo "900 25000 0.30 3.20 fill|General photos & images — sensible all-rounder (default)";;
  wallpapers) echo "1280 40000 0.50 3.20 fill|Curated hi-res, mostly-landscape wallpapers";;
  comics)     echo "700 15000 0.20 2.20 fill|Comic / manga pages — allows tall art, drops banners & thumbnails";;
  any)        echo "1 1 0.01 100 fill|Everything — no filtering at all";;
  *) return 1;; esac; }

list_presets() {
  printf '  %-11s %s\n' "PRESET" "WHAT IT PICKS"
  for p in standard wallpapers comics any; do
    printf '  %-11s %s\n' "$p" "$(preset_row "$p" | cut -d'|' -f2)"
  done
}

# ---- args
DIR=""; PRESET=""; INTERVAL=""; BACKEND="auto"; SAVE_LAYOUT=""; AUTO_UPDATE=""; DO_ENABLE=1; ASSUME_YES=0
while [ $# -gt 0 ]; do case "$1" in
  --dir)          DIR="${2:?}"; shift 2;;
  --preset)       PRESET="${2:?}"; shift 2;;
  --interval)     INTERVAL="${2:?}"; shift 2;;
  --backend)      BACKEND="${2:?}"; shift 2;;
  --save-layout)  SAVE_LAYOUT=1; shift;;
  --no-save-layout) SAVE_LAYOUT=0; shift;;
  --auto-update)    AUTO_UPDATE=1; shift;;
  --no-auto-update) AUTO_UPDATE=0; shift;;
  --no-enable)    DO_ENABLE=0; shift;;
  --yes|-y)       ASSUME_YES=1; shift;;
  --list-presets) list_presets; exit 0;;
  -h|--help)      awk 'NR>1{if($0~/^#/){sub(/^# ?/,"");print}else exit}' "$0"; exit 0;;
  *) die "unknown option: $1";;
esac; done

TTY=/dev/tty; [ -r "$TTY" ] || TTY=/dev/stdin
ask() {  # ask VAR "prompt" "default"
  local __v=$1 p=$2 d=${3:-} ans
  if [ "$ASSUME_YES" -eq 1 ]; then printf -v "$__v" '%s' "$d"; return; fi
  read -r -p "$p${d:+ [$d]}: " ans <"$TTY" || ans=""
  printf -v "$__v" '%s' "${ans:-$d}"
}
confirm() {  # confirm "question"  → 0 yes / 1 no ; default yes
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local a; read -r -p "$1 [Y/n]: " a <"$TTY" || a=""
  case "${a:-y}" in [Yy]*) return 0;; *) return 1;; esac
}
count_images() {
  find "$1" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
       -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' \) 2>/dev/null \
    | head -n 20001 | wc -l | tr -d ' '
}

# ---- 0. dependency fast-check (so we fail before asking questions)
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found."
if ! python3 -c 'import PIL' >/dev/null 2>&1; then
  warn "Python 'Pillow' is required to compose the canvas and isn't installed."
  command -v apt    >/dev/null 2>&1 && echo "     Debian/Ubuntu:  sudo apt install python3-pil python3-gi"
  command -v dnf    >/dev/null 2>&1 && echo "     Fedora:         sudo dnf install python3-pillow python3-gobject"
  command -v pacman >/dev/null 2>&1 && echo "     Arch:           sudo pacman -S python-pillow python-gobject"
  echo "     or anywhere:    python3 -m pip install --user Pillow"
  die "install Pillow, then re-run ./setup.sh"
fi

# ---- 1. scan the environment (uses the repo copy; no Pillow needed for --detect)
head2 "1. Scanning this machine"
DETECT="$("$HERE/mosaic-wallpaper.py" --detect 2>/dev/null || true)"
if [ -z "$DETECT" ]; then
  warn "no monitors detected yet (no live GNOME/sway/xrandr session, no cache) — continuing anyway."
  VIA="unknown"; DBACKEND="unknown"
else
  echo "$DETECT" | sed 's/^/   /'
  VIA="$(printf '%s\n' "$DETECT"      | sed -n 's/.*detected via: *\([^ ]*\).*/\1/p' | head -1)"
  DBACKEND="$(printf '%s\n' "$DETECT" | sed -n 's/.*backend: *\([^ ]*\).*/\1/p'      | head -1)"
fi
IS_GNOME=0; [ "$VIA" = "mutter" ] && IS_GNOME=1

# ---- 2. which images
head2 "2. Where are your images?"
if [ -z "$DIR" ]; then
  def="$HOME/Pictures"
  ask DIR "   Folder of images to use" "$def"
fi
DIR="${DIR/#\~/$HOME}"; DIR="$(cd "$DIR" 2>/dev/null && pwd || echo "$DIR")"
[ -d "$DIR" ] || die "not a directory: $DIR"
NIMG="$(count_images "$DIR")"; [ "$NIMG" = "20001" ] && NIMG="20000+"
[ "$NIMG" = "0" ] && warn "no images found under $DIR right now — it'll pick them up once you add some."
say "using: $DIR  ($NIMG images)"

# ---- 3. content preset
head2 "3. What kind of images? (preset — tunes the quality filter & fit)"
if [ -z "$PRESET" ]; then
  list_presets
  ask PRESET "   preset" "standard"
fi
ROW="$(preset_row "$PRESET")" || die "unknown preset '$PRESET' (see --list-presets)"
read -r MIN_EDGE MIN_BYTES MIN_ASP MAX_ASP MODE _ <<<"${ROW%%|*}"
say "preset: $PRESET  →  min ${MIN_EDGE}px, aspect ${MIN_ASP}–${MAX_ASP}, fit=$MODE"

# ---- 4. rotation interval
head2 "4. How often should it change?"
if [ -z "$INTERVAL" ]; then
  echo "   1) every 15 min   2) every 30 min   3) every 60 min"
  echo "   4) every 5 min    5) once a day     6) off (manual only)"
  ask CH "   choice" "2"
  case "$CH" in 1) INTERVAL=15min;; 2) INTERVAL=30min;; 3) INTERVAL=60min;;
                4) INTERVAL=5min;; 5) INTERVAL=daily;; 6) INTERVAL=off;;
                *min|*h|off|daily) INTERVAL="$CH";; *) INTERVAL=30min;; esac
fi
[ "$INTERVAL" = "daily" ] && SYSTEMD_INT="24h" || SYSTEMD_INT="$INTERVAL"
if [ "$INTERVAL" = "off" ]; then say "rotation: off (run 'mosaic-wallpaper.py' yourself, or bind a key)"
else say "rotation: every $INTERVAL"; fi

# ---- 5. monitor arrangement (GNOME only; never auto-yes in --yes mode — needs the explicit flag)
if [ "$IS_GNOME" -eq 1 ] && [ -z "$SAVE_LAYOUT" ] && [ "$ASSUME_YES" -eq 0 ]; then
  head2 "5. Monitor arrangement (GNOME)"
  echo "   Remember the CURRENT arrangement so it's restored after reboots/hotplugs?"
  if confirm "   save current monitor layout"; then SAVE_LAYOUT=1; else SAVE_LAYOUT=0; fi
fi
[ -z "$SAVE_LAYOUT" ] && SAVE_LAYOUT=0

# ---- auto-updates (opt-in; needs git + systemd + enabling)
if [ -z "$AUTO_UPDATE" ]; then
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DO_ENABLE" -eq 0 ] || ! command -v git >/dev/null 2>&1; then
    AUTO_UPDATE=0
  else
    head2 "Automatic updates"
    echo "   Check weekly for a newer version and install it automatically (fast-forward only)?"
    if confirm "   enable auto-updates"; then AUTO_UPDATE=1; else AUTO_UPDATE=0; fi
  fi
fi

# ---- confirm
head2 "Ready to apply"
cat <<EOF
   images    : $DIR  ($NIMG)
   preset    : $PRESET  (min ${MIN_EDGE}px · aspect ${MIN_ASP}-${MAX_ASP} · $MODE)
   rotate    : $([ "$INTERVAL" = off ] && echo "off (manual)" || echo "every $INTERVAL")
   backend   : $BACKEND$([ "$BACKEND" = auto ] && [ "$DBACKEND" != unknown ] && echo "  (detected: $DBACKEND)")
   detected  : ${VIA} · $(printf '%s' "$DETECT" | grep -c '@ (' || true) monitor(s)
   save layout: $([ "$SAVE_LAYOUT" = 1 ] && echo yes || echo no)
   auto-update: $([ "$AUTO_UPDATE" = 1 ] && echo "weekly" || echo no)
   enable now: $([ "$DO_ENABLE" = 1 ] && echo yes || echo "no (--no-enable)")
EOF
confirm "Apply this?" || { warn "aborted — nothing changed."; exit 0; }

# ---- 7. write config (backup any existing)
mkdir -p "$CFGDIR"
if [ -f "$CFG" ]; then cp "$CFG" "$CFG.bak.$(date +%s)"; say "backed up previous config -> $CFG.bak.*"; fi
cat > "$CFG" <<EOF
# mosaic-wallpaper — generated by setup.sh ($(date -Iseconds)); preset: $PRESET
[source]
directories = $DIR
extensions = jpg jpeg png webp bmp gif
recursive = true
index_max_age_hours = 24

[filter]
min_long_edge = $MIN_EDGE
min_bytes     = $MIN_BYTES
min_aspect    = $MIN_ASP
max_aspect    = $MAX_ASP

[compose]
mode = $MODE
background = #000000
jpeg_quality = 90

[wallpaper]
backend = $BACKEND
EOF
say "wrote config -> $CFG"

# ---- 8. install scripts + units (no enabling; keeps the config we just wrote)
head2 "Installing"
"$HERE/install.sh" --no-enable

# ---- 9. timer interval + enable
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  if [ "$INTERVAL" != "off" ]; then
    mkdir -p "$UNITS/mosaic-wallpaper.timer.d"
    printf '[Timer]\nOnUnitActiveSec=%s\n' "$SYSTEMD_INT" > "$UNITS/mosaic-wallpaper.timer.d/override.conf"
  else
    rm -f "$UNITS/mosaic-wallpaper.timer.d/override.conf" 2>/dev/null || true
  fi
  systemctl --user daemon-reload
  if [ "$DO_ENABLE" -eq 1 ] && [ "$INTERVAL" != "off" ]; then
    loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "couldn't enable linger; timer runs only while logged in."
    systemctl --user enable --now mosaic-wallpaper.timer >/dev/null
    say "timer enabled — rotating every $INTERVAL"
    if [ "$IS_GNOME" -eq 1 ]; then
      systemctl --user enable --now mosaic-wallpaper-watch.service >/dev/null
      say "monitor-change watcher enabled (GNOME)"
    fi
  fi
fi

# ---- 10. save monitor layout (GNOME)
if [ "$SAVE_LAYOUT" = 1 ] && [ "$IS_GNOME" -eq 1 ]; then
  "$BIN/monitor-layout.py" --save || warn "layout save failed"
  [ "$DO_ENABLE" -eq 1 ] && systemctl --user enable monitor-layout.service >/dev/null 2>&1 || true
  say "monitor layout saved + restore-at-login enabled"
fi

# ---- auto-updates (opt-in)
if [ "$AUTO_UPDATE" = 1 ] && [ "$DO_ENABLE" -eq 1 ]; then
  if "$HERE/update.sh" --enable-auto >/dev/null 2>&1; then say "auto-updates enabled — checks weekly, fast-forward only"
  else warn "couldn't enable auto-updates (needs git + a systemd session)."; fi
fi

# ---- paint once now
if [ "$DO_ENABLE" -eq 1 ]; then
  head2 "Painting your first canvas"
  if "$BIN/mosaic-wallpaper.py"; then say "done — your wallpaper is live."
  else warn "first paint didn't set the wallpaper (see message above); config is in place."; fi
else
  say "configured but not enabled. Paint when ready:  mosaic-wallpaper.py"
fi

echo
say "All set. Re-run ./setup.sh to change anything, or edit $CFG."
say "Update: ./update.sh  ·  auto-update: ./update.sh --enable-auto  ·  remove everything: ./uninstall.sh --nuke"
