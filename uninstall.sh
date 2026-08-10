#!/usr/bin/env bash
# mosaic-wallpaper uninstaller. Removes the scripts and systemd units.
# Your config (and any saved layout) is kept unless you ask otherwise.
#
#   ./uninstall.sh                remove scripts + units, keep config
#   ./uninstall.sh --purge        also delete ~/.config/mosaic-wallpaper + the cache
#   ./uninstall.sh --delete-repo  also delete the cloned repo folder
#   ./uninstall.sh --nuke         everything: units, scripts, config, cache AND the repo (no trace, no prompts)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/mosaic-wallpaper"
CACHEDIR="${XDG_CACHE_HOME:-$HOME/.cache}/mosaic-wallpaper"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

PURGE=0; DELREPO=0
for a in "$@"; do case "$a" in
  --purge)       PURGE=1 ;;
  --delete-repo) DELREPO=1 ;;
  --nuke)        PURGE=1; DELREPO=1 ;;
  -h|--help) awk 'NR>1{if($0~/^#/){sub(/^# ?/,"");print}else exit}' "$0"; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }

# Work out where the repo lives BEFORE we delete config (install.env records it).
REPO=""
if [ -f "$HERE/mosaic-wallpaper.py" ] && [ -f "$HERE/setup.sh" ] && [ -d "$HERE/systemd" ]; then
  REPO="$HERE"
elif [ -f "$CFGDIR/install.env" ]; then
  REPO="$(. "$CFGDIR/install.env" 2>/dev/null; printf '%s' "${REPO_DIR:-}")"
fi
# A path is only safe to rm -rf if it really is a mosaic-wallpaper checkout (never / or $HOME).
safe_repo() { [ -n "$1" ] && [ "$1" != "/" ] && [ "$1" != "$HOME" ] \
              && [ -f "$1/mosaic-wallpaper.py" ] && [ -f "$1/setup.sh" ] && [ -d "$1/systemd" ]; }

# --- systemd units ---------------------------------------------------------
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  for u in mosaic-wallpaper.timer mosaic-wallpaper-watch.service monitor-layout.service \
           mosaic-wallpaper-update.timer mosaic-wallpaper-update.service; do
    systemctl --user disable --now "$u" >/dev/null 2>&1 || true
  done
  rm -f "$UNITS"/mosaic-wallpaper@.service "$UNITS"/mosaic-wallpaper.timer \
        "$UNITS"/mosaic-wallpaper-watch.service "$UNITS"/monitor-layout.service \
        "$UNITS"/mosaic-wallpaper-update.service "$UNITS"/mosaic-wallpaper-update.timer
  rm -rf "$UNITS/mosaic-wallpaper.timer.d"
  systemctl --user daemon-reload || true
  say "removed systemd --user units (incl. auto-update)"
fi

# --- scripts ---------------------------------------------------------------
rm -f "$BIN/mosaic-wallpaper.py" "$BIN/monitor-layout.py" \
      "$BIN/mosaic-wallpaper-watch.py" "$BIN/mosaic-wallpaper-update.sh"
say "removed scripts from $BIN"

# --- config + cache --------------------------------------------------------
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$CFGDIR" "$CACHEDIR"
  say "purged config + cache"
else
  say "kept your config at $CFGDIR (use --purge to delete it)"
fi

# --- the repo clone --------------------------------------------------------
if [ "$DELREPO" -eq 1 ]; then
  if safe_repo "$REPO"; then
    cd "$HOME"                       # step out of it before removing
    rm -rf -- "$REPO"
    say "deleted the repo: $REPO"
  else
    warn "couldn't safely locate the repo to delete (looked at '$REPO') — remove it by hand if needed."
  fi
fi

say "Done.$([ "$DELREPO" -eq 1 ] && echo ' Fully removed.') (Linger, if enabled, is left as-is — 'loginctl disable-linger $USER' to undo.)"
