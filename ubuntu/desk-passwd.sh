#!/usr/bin/env bash
#
# desk-passwd.sh — change your desktop password WITHOUT breaking remote desktop.
#
# Installed as /usr/local/bin/desk-passwd. Hand this to the person using the machine:
#
#   desk-passwd
#
# It re-runs itself with sudo, asks for the new password ONCE, and applies it to both
# places that need it.
#
# Why it exists: GNOME Remote Desktop keeps its OWN copy of your credentials, separate
# from the system password file. Changing your password with plain `passwd` leaves GRD
# holding the old one, remote login can then no longer start a session, and RDP fails with
# an endless "connecting" loop that looks like a network fault. Asking once and writing
# both makes them impossible to get out of step. See docs/remote-desktop-on-wayland.md.
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET="${1:-}"

# Re-exec under sudo: setting the system-wide GRD credentials needs root.
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "run this as root"
  echo "== elevating (your CURRENT password, the new one comes later)"
  exec sudo -- "$0" "${TARGET:-$(id -un)}"
fi

# Default to whoever invoked sudo, so plain `desk-passwd` does the right thing.
[ -n "$TARGET" ] || TARGET="${SUDO_USER:-}"
[ -n "$TARGET" ] || die "cannot tell which user to change — pass a username"

id "$TARGET" >/dev/null 2>&1 || die "no such user: $TARGET"
command -v grdctl >/dev/null 2>&1 || die "no grdctl — gnome-remote-desktop is not installed"

echo "Changing the password for '$TARGET' (login AND remote desktop)."
echo

read -r -s -p "New password: " P1; echo
read -r -s -p "Repeat it:    " P2; echo
echo

[ -n "$P1" ]        || die "empty passwords are not allowed — remote login cannot use one"
[ "$P1" = "$P2" ]   || die "the two entries do not match, nothing was changed"
[ ${#P1} -ge 8 ]    || die "use at least 8 characters"

echo "== 1/2  system password"
printf '%s:%s\n' "$TARGET" "$P1" | chpasswd
echo "   done"

echo "== 2/2  remote desktop credentials"
# Prefer non-interactive; fall back to prompting if this grdctl wants it that way.
if grdctl --system rdp set-credentials "$TARGET" "$P1" >/dev/null 2>&1; then
  echo "   done"
else
  echo "   this grdctl needs them typed — enter '$TARGET' and the SAME password"
  grdctl --system rdp set-credentials
fi

unset P1 P2

# Silence the login hint for this user — they have done the thing it asks for.
TARGET_HOME="$(getent passwd "$TARGET" | cut -d: -f6)"
if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
  install -d -o "$TARGET" -g "$TARGET" -m 700 "$TARGET_HOME/.config"
  : > "$TARGET_HOME/.config/desk-passwd-done"
  chown "$TARGET:$TARGET" "$TARGET_HOME/.config/desk-passwd-done"
fi

systemctl restart gnome-remote-desktop.service

echo
echo "== verify"
if ss -tlnp | grep -q ':3389'; then
  ss -tlnp | grep ':3389' | sed 's/^/   /'
else
  echo "   NOTHING LISTENING ON 3389"
  echo "   check: journalctl -u gnome-remote-desktop -n 30 --no-pager"
fi

cat <<NEXT

Password changed for $TARGET. Use it for BOTH the desktop login and the RDP connection.

If you are connected right now, your current session keeps working, so reconnect once to
confirm the new password really works before you rely on it.
NEXT
