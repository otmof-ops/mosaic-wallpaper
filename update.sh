#!/usr/bin/env bash
# mosaic-wallpaper updater — pull the latest and refresh the install in place.
# Safe: fast-forward only, never clobbers local edits; keeps your config and
# whatever you had enabled. Also manages the optional weekly auto-update timer.
#
#   ./update.sh                 update now (no-op if already current)
#   ./update.sh --check         say whether an update is available; change nothing
#   ./update.sh --enable-auto   turn ON weekly automatic updates
#   ./update.sh --disable-auto  turn OFF automatic updates
#   ./update.sh --auto          quiet mode for the timer (acts only if there's a new version)
set -euo pipefail

BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
CFGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/mosaic-wallpaper"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ENVFILE="$CFGDIR/install.env"

MODE=update
case "${1:-}" in
  ""|--update)    MODE=update ;;
  --check)        MODE=check ;;
  --enable-auto)  MODE=enable-auto ;;
  --disable-auto) MODE=disable-auto ;;
  --auto)         MODE=auto ;;
  -h|--help) awk 'NR>1{if($0~/^#/){sub(/^# ?/,"");print}else exit}' "$0"; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
AUTO=0; [ "$MODE" = auto ] && { AUTO=1; MODE=update; }

say()  { [ "$AUTO" = 1 ] && return 0; printf '\033[1;36m==>\033[0m %s\n' "$*"; }
note() { printf '==> %s\n' "$*"; }   # always prints (lands in the journal under --auto)
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Locate the repo checkout: this script's own dir if it's one, else the path install.sh recorded.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=""
if [ -d "$HERE/.git" ] && [ -f "$HERE/mosaic-wallpaper.py" ]; then
  REPO="$HERE"
elif [ -f "$ENVFILE" ]; then
  REPO="$(. "$ENVFILE" 2>/dev/null; printf '%s' "${REPO_DIR:-}")"
fi

have_systemd() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
ensure_update_units() {
  [ -n "$REPO" ] && [ -d "$REPO/systemd" ] || return 0
  mkdir -p "$UNITS"
  cp "$REPO"/systemd/mosaic-wallpaper-update.service "$REPO"/systemd/mosaic-wallpaper-update.timer "$UNITS"/ 2>/dev/null || true
}

case "$MODE" in
enable-auto)
  have_systemd || die "no systemd --user here — auto-update needs it."
  [ -n "$REPO" ] || die "can't find the repo checkout (clone it and run ./install.sh once first)."
  ensure_update_units
  systemctl --user daemon-reload
  systemctl --user enable --now mosaic-wallpaper-update.timer >/dev/null
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  say "automatic updates ON — checks weekly. Next run:"
  [ "$AUTO" = 1 ] || systemctl --user list-timers mosaic-wallpaper-update.timer --no-legend 2>/dev/null | sed 's/^/    /'
  exit 0 ;;
disable-auto)
  have_systemd || exit 0
  systemctl --user disable --now mosaic-wallpaper-update.timer >/dev/null 2>&1 || true
  say "automatic updates OFF."
  exit 0 ;;
esac

# ---- update / check / auto ----
[ -n "$REPO" ]                 || { [ "$AUTO" = 1 ] && exit 0; die "can't find the repo checkout (looked in this script's dir and $ENVFILE)."; }
command -v git >/dev/null 2>&1 || { [ "$AUTO" = 1 ] && exit 0; die "git not found — needed to update."; }
[ -d "$REPO/.git" ]            || { [ "$AUTO" = 1 ] && exit 0; die "$REPO is not a git checkout — update it the way you obtained it."; }

cd "$REPO"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
git fetch --quiet origin "$BRANCH" 2>/dev/null || { [ "$AUTO" = 1 ] && exit 0; die "couldn't reach the git remote."; }
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse '@{u}' 2>/dev/null || git rev-parse "origin/$BRANCH" 2>/dev/null || echo "$LOCAL")"

if [ "$LOCAL" = "$REMOTE" ]; then
  say "already up to date ($(git rev-parse --short HEAD))."
  exit 0
fi
if [ "$MODE" = check ]; then
  n="$(git rev-list --count "HEAD..$REMOTE" 2>/dev/null || echo '?')"
  say "update available: $n new commit(s), $(git rev-parse --short HEAD) → $(git rev-parse --short "$REMOTE"). Run ./update.sh to apply."
  exit 0
fi

# Never overwrite local work: require a clean, fast-forwardable checkout.
if ! git merge-base --is-ancestor "$LOCAL" "$REMOTE" 2>/dev/null; then
  [ "$AUTO" = 1 ] && { warn "local history diverges from origin; skipping auto-update."; exit 0; }
  die "your checkout has diverged from origin (local commits). Resolve by hand; refusing to overwrite."
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  [ "$AUTO" = 1 ] && { warn "uncommitted local changes in $REPO; skipping auto-update."; exit 0; }
  die "you have uncommitted changes in $REPO — commit or stash them first."
fi

OLD="$(git rev-parse --short HEAD)"
git merge --ff-only --quiet "$REMOTE"
NEW="$(git rev-parse --short HEAD)"
note "mosaic-wallpaper updated $OLD → $NEW; refreshing installed files."

# Re-lay the scripts/units and restart whatever's running — config & enable-state untouched.
"$REPO/install.sh" --refresh $([ "$AUTO" = 1 ] && echo --quiet)
note "update complete ($NEW)."
