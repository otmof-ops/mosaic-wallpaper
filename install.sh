#!/usr/bin/env bash
# mosaic-wallpaper installer — portable, no hardcoded paths or uid.
# Installs the scripts to ~/.local/bin, a default config to
# ~/.config/mosaic-wallpaper, and (if systemd --user is available) the timer +
# watcher units. Safe to re-run; keeps any existing config.
#
#   ./install.sh                install + enable units
#   ./install.sh --no-enable    install files only, don't enable/start anything
#   ./install.sh --no-systemd   install scripts + config only, skip systemd entirely
#   ./install.sh --refresh      re-lay files + restart active units (used by update.sh; keeps config/enable-state)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/mosaic-wallpaper"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

ENABLE=1; USE_SYSTEMD=1; REFRESH=0; QUIET=0
for a in "$@"; do case "$a" in
  --no-enable)  ENABLE=0 ;;
  --no-systemd) USE_SYSTEMD=0 ;;
  --refresh)    REFRESH=1; ENABLE=0 ;;
  --quiet)      QUIET=1 ;;
  -h|--help) awk 'NR>1{if($0~/^#/){sub(/^# ?/,"");print}else exit}' "$0"; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

say()  { [ "$QUIET" = 1 ] && return 0; printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependencies ----------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found."
if ! python3 -c 'import PIL' >/dev/null 2>&1; then
  if [ "$REFRESH" = 1 ]; then
    warn "Pillow missing — files refreshed, but composing will fail until you install it."
  else
    warn "Python imaging library 'Pillow' is missing (needed to compose the canvas)."
    if command -v apt >/dev/null 2>&1; then
      echo "     Debian/Ubuntu:  sudo apt install python3-pil python3-gi"
    elif command -v dnf >/dev/null 2>&1; then
      echo "     Fedora:         sudo dnf install python3-pillow python3-gobject"
    elif command -v pacman >/dev/null 2>&1; then
      echo "     Arch:           sudo pacman -S python-pillow python-gobject"
    fi
    echo "     or, anywhere:   python3 -m pip install --user Pillow"
    die "install Pillow, then re-run ./install.sh"
  fi
fi
[ "$REFRESH" = 1 ] || python3 -c 'import gi' >/dev/null 2>&1 || \
  warn "python3-gi not found — GNOME monitor-watch/layout features will be skipped (timer still works)."

# --- scripts ---------------------------------------------------------------
mkdir -p "$BIN"
install -m 0755 "$HERE/mosaic-wallpaper.py"       "$BIN/mosaic-wallpaper.py"
install -m 0755 "$HERE/monitor-layout.py"         "$BIN/monitor-layout.py"
install -m 0755 "$HERE/mosaic-wallpaper-watch.py" "$BIN/mosaic-wallpaper-watch.py"
install -m 0755 "$HERE/update.sh"                 "$BIN/mosaic-wallpaper-update.sh"
say "installed scripts -> $BIN"
case ":$PATH:" in *":$BIN:"*) : ;; *) [ "$REFRESH" = 1 ] || warn "$BIN is not on your PATH — add it to use the commands by name." ;; esac

# --- record where this checkout lives, so update.sh / uninstall.sh can find it
mkdir -p "$CFGDIR"
printf "# written by install.sh — where mosaic-wallpaper was installed from\nREPO_DIR='%s'\n" "$HERE" > "$CFGDIR/install.env"

# --- config ----------------------------------------------------------------
if [ "$REFRESH" = 0 ]; then
  if [ -f "$CFGDIR/config.ini" ]; then
    say "keeping existing config -> $CFGDIR/config.ini"
  else
    cp "$HERE/config.example.ini" "$CFGDIR/config.ini"
    say "wrote default config  -> $CFGDIR/config.ini   (edit [source] directories!)"
  fi
fi

# --- systemd --user --------------------------------------------------------
is_gnome() { python3 - <<'PY' >/dev/null 2>&1
import gi; from gi.repository import Gio
b = Gio.bus_get_sync(Gio.BusType.SESSION, None)
b.call_sync("org.gnome.Mutter.DisplayConfig","/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig","GetCurrentState",None,None,0,2000,None)
PY
}

if [ "$USE_SYSTEMD" -eq 1 ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  mkdir -p "$UNITS"
  cp "$HERE"/systemd/*.service "$HERE"/systemd/*.timer "$UNITS"/
  systemctl --user daemon-reload
  if [ "$REFRESH" = 1 ]; then
    # Restart only what's currently running, so new code/units take effect without changing enable-state.
    for u in mosaic-wallpaper.timer mosaic-wallpaper-watch.service mosaic-wallpaper-update.timer; do
      systemctl --user is-active --quiet "$u" 2>/dev/null && systemctl --user restart "$u" >/dev/null 2>&1 || true
    done
    say "refreshed units + restarted active services"
  else
    say "installed systemd --user units -> $UNITS"
    if [ "$ENABLE" -eq 1 ]; then
      # Let timers fire without an active login session (e.g. headless / after logout).
      loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "couldn't enable linger; timers run only while logged in."
      systemctl --user enable --now mosaic-wallpaper.timer >/dev/null
      say "enabled mosaic-wallpaper.timer (rotates every 30 min)"
      if is_gnome; then
        systemctl --user enable --now mosaic-wallpaper-watch.service >/dev/null
        systemctl --user enable monitor-layout.service >/dev/null   # inert until you --save a layout
        say "enabled GNOME monitor-watch + layout-restore services"
      else
        warn "not a GNOME/Mutter session — skipping monitor-watch/layout services (timer still active)."
      fi
    else
      say "installed units but did NOT enable them (--no-enable)."
    fi
  fi
else
  [ "$USE_SYSTEMD" -eq 1 ] && [ "$REFRESH" = 0 ] && warn "no systemd --user here — skipping units. Schedule mosaic-wallpaper.py via cron or your DE."
fi

# --- summary ---------------------------------------------------------------
if [ "$REFRESH" = 1 ]; then
  say "refreshed."
  exit 0
fi
echo
"$BIN/mosaic-wallpaper.py" --detect 2>/dev/null || warn "monitor detection returned nothing yet (fine on a headless install)."
echo
say "Done. Next steps:"
echo "  1. Point it at your images:   \$EDITOR $CFGDIR/config.ini   ([source] directories = ...)"
echo "  2. Paint once now:            $BIN/mosaic-wallpaper.py"
echo "  3. (GNOME, optional) arrange your monitors in Settings, then remember it:"
echo "     $BIN/monitor-layout.py --save"
echo "  4. (optional) keep it current automatically:  $BIN/mosaic-wallpaper-update.sh --enable-auto"
