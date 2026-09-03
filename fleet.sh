#!/usr/bin/env bash
#
# fleet.sh — what fleetkit commands does THIS machine have, and what does each one do.
#
#   fleet              # the list
#   fleet <name>       # the full help for one command
#
# WHY IT LISTS WHAT IS INSTALLED, NOT WHAT THE REPO CONTAINS
#
# The question is never "what does fleetkit ship". It is "what can I run here, right now".
# A Mac has one command, a guest has eight, a hypervisor thirteen, and a machine installed
# months ago has whatever it had then. So this walks /usr/local/bin and reports the symlinks
# that actually point into the repo.
#
# The descriptions are read from each script's own header, so a new script appears here the
# moment it is installed and nobody has to remember to update a list. A list maintained by
# hand is a list that is wrong.
#
set -euo pipefail

REPO="${FLEET_DEST:-/opt/fleetkit}"
BIN=/usr/local/bin

resolve_self() {
  local self="$1" target
  while [ -L "$self" ]; do
    target="$(readlink "$self")"
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
  done
  printf '%s\n' "$self"
}

# Line 3 of every script is "# name.sh — what it does". Take the half after the dash.
describe() {
  sed -n '3p' "$1" 2>/dev/null \
    | sed -e 's/^# *//' -e 's/^[A-Za-z0-9._-]* *[—-] *//' -e 's/\.$//'
}

# One command's full help, for `fleet <name>`.
if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
  esac
  CMD="$(command -v "$1" 2>/dev/null || true)"
  [ -n "$CMD" ] || { echo "no such command: $1" >&2; exit 1; }
  exec "$CMD" --help
fi

echo
if [ -d "$REPO/.git" ]; then
  echo "fleetkit at $REPO"
  echo "   version: $(git -C "$REPO" log -1 --format='%h %cs %s' 2>/dev/null | cut -c1-78)"
  BEHIND="$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "${BEHIND:-0}" -gt 0 ]; then
    echo "   $BEHIND commit(s) behind origin. Take them with:  sudo fleet-update"
  else
    echo "   up to date as of the last fetch. Update with:  sudo fleet-update"
  fi
else
  echo "fleetkit repo not found at $REPO"
  echo "   install it with:  sudo fleet-install --apply"
fi

echo
echo "Commands on this machine:"
FOUND=0
for f in "$BIN"/*; do
  [ -L "$f" ] || continue
  target="$(resolve_self "$f")"
  case "$target" in "$REPO"/*) ;; *) continue ;; esac
  [ -f "$target" ] || { printf '   %-20s BROKEN LINK -> %s\n' "$(basename "$f")" "$target"; continue; }
  printf '   %-20s %s\n' "$(basename "$f")" "$(describe "$target")"
  FOUND=$((FOUND + 1))
done
[ "$FOUND" -gt 0 ] || echo "   none. Install them with:  sudo fleet-install --apply"

cat <<'TAIL'

   fleet <command>      the full help for one of them
   <command> --help     the same thing, directly

Two that are easy to forget:
   sudo fleet-update    pull the repo and re-link every command at once
   sudo fleet-install --apply
                        first install on a machine, or repair after a link goes missing
TAIL
echo
