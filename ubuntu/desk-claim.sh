#!/usr/bin/env bash
#
# desk-claim.sh — turn a fresh clone into a named person's machine.
#
# Runs INSIDE the clone, as root. Installed as /usr/local/bin/desk-claim.
#
#   sudo desk-claim <person>                        # hostname becomes desk-<person>
#   sudo desk-claim <person> --hostname <hostname>  # if the two should differ
#   sudo desk-claim <person> --prefix srv-          # or change just the prefix
#
# DESKTOP OR SERVER: the remote-desktop half runs only where grdctl exists. On a server there
# is no GNOME, so this sets the hostname, identity and password and stops there. The name is
# historical — it claims any clone, not only a desktop.
#
# Every instance uses the SAME login account (default 'ubuntu'), set up once in the golden
# with its runtimes and dotfiles already in place. The isolation boundary is the VM, not the
# username: one person per machine, each with their own password. So this script does not
# create users or provision a home at all — it gives the machine its own identity and its
# own password.
#
# Idempotent: irreversible steps leave a marker in /var/lib/desk-claim and are skipped on a
# re-run, so a half-finished run can simply be run again. Re-running it is also how you
# RENAME a machine: it rewrites the hostname, the certificate CN and — critically — the GRD
# credentials, which must be re-set after a rename or remote desktop breaks.
#
set -euo pipefail

PERSON=""
NEWHOST=""
STD_USER="ubuntu"
PREFIX="${DESK_PREFIX:-desk-}"   # hostname becomes <prefix><person>; override with --prefix or $DESK_PREFIX
NO_REBOOT=0

MARKERS=/var/lib/desk-claim
GRD_DIR=/etc/gnome-remote-desktop
CERT="$GRD_DIR/rdp-tls.crt"
KEY="$GRD_DIR/rdp-tls.key"
GRD_OWNER=gnome-remote-desktop

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
skip() { echo "   already done, skipping ($1)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)  NEWHOST="${2:?}"; shift 2 ;;
    --user)      STD_USER="${2:?}"; shift 2 ;;
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           [ -z "$PERSON" ] && PERSON="$1" || die "unexpected argument: $1"; shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$PERSON" ]     || die "usage: desk-claim <person> [--hostname NAME] [--user NAME]"

command -v qm >/dev/null 2>&1 && die "this is the Proxmox host, not a guest. Wrong machine."

# The daily driver carries this marker so an accidental run cannot rename it.
if [ -f /etc/desk-no-claim ]; then
  die "/etc/desk-no-claim exists — this machine is marked never-to-be-claimed.
       Put that file on any machine you must not rename (your daily driver).
       Remove it only if you truly mean it."
fi

# Detect, do not configure: a server has no grdctl and needs none of the RDP steps below.
has_rdp() { command -v grdctl >/dev/null 2>&1; }
if has_rdp; then
  command -v openssl >/dev/null 2>&1 || die "no openssl — needed for the RDP certificate"
fi

case "$PERSON" in
  [a-z]*) : ;;
  *) die "name must start with a lowercase letter" ;;
esac
case "$PERSON" in
  *[!a-z0-9_-]*) die "name may only contain a-z 0-9 _ -" ;;
esac

id "$STD_USER" >/dev/null 2>&1 || die "user '$STD_USER' does not exist.
       This image was not prepared as a golden — see docs/golden-images.md."

[ -n "$NEWHOST" ] || NEWHOST="$PREFIX$PERSON"
mkdir -p "$MARKERS"

echo "desk-claim"
echo "   machine   $(hostname) -> $NEWHOST"
echo "   login     $STD_USER (existing account, password will be reset)"
printf '\nProceed? [y/N] '
read -r reply
case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; exit 1 ;; esac

# ---------------------------------------------------------------- hostname

step "hostname -> $NEWHOST"
if [ "$(hostname)" = "$NEWHOST" ]; then
  skip "already set"
else
  hostnamectl set-hostname "$NEWHOST"
fi

if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEWHOST/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NEWHOST" >> /etc/hosts
fi
grep -E '^127\.0\.(0\.1|1\.1)' /etc/hosts | sed 's/^/   /'

# ---------------------------------------------------------------- identity

step "machine-id"
if [ -s /etc/machine-id ]; then
  echo "   already set: $(cat /etc/machine-id)"
  echo "   (a sysprepped template leaves this EMPTY so each clone derives its own)"
else
  systemd-machine-id-setup >/dev/null
  [ -d /var/lib/dbus ] && ln -sf /etc/machine-id /var/lib/dbus/machine-id
  echo "   generated: $(cat /etc/machine-id)"
fi

step "SSH host keys"
if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  echo "   present, leaving alone"
else
  ssh-keygen -A >/dev/null
  systemctl is-active --quiet ssh && systemctl restart ssh || true
  echo "   generated"
fi

# ---------------------------------------------------------------- password

step "password for $STD_USER"
if has_rdp; then
  echo "   Used for BOTH the desktop login and RDP: GRD performs a real login with it."
else
  echo "   Used for console login and sudo. SSH keys are added per person afterwards."
fi
echo "   $PERSON replaces it later with 'desk-passwd'."
echo
read -r -s -p "   Password: " PW;  echo
read -r -s -p "   Repeat:   " PW2; echo

[ -n "$PW" ]        || die "empty passwords cannot be used — remote login needs a real one"
[ "$PW" = "$PW2" ]  || die "the two entries do not match, nothing was changed"
[ ${#PW} -ge 8 ]    || die "use at least 8 characters"

printf '%s:%s\n' "$STD_USER" "$PW" | chpasswd
echo "   unix password set"

# ---------------------------------------------------------------- RDP

if has_rdp; then
  step "RDP certificate (CN=$NEWHOST)"
  openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -subj "/O=homelab/CN=$NEWHOST" \
    -out /tmp/.dc.crt -keyout /tmp/.dc.key 2>/dev/null

  # install sets owner and mode in one step. GRD reports healthy and silently never listens if
  # the daemon does not own these — see docs/remote-desktop-on-wayland.md.
  install -o "$GRD_OWNER" -g "$GRD_OWNER" -m 644 /tmp/.dc.crt "$CERT"
  install -o "$GRD_OWNER" -g "$GRD_OWNER" -m 600 /tmp/.dc.key "$KEY"
  rm -f /tmp/.dc.crt /tmp/.dc.key
  ls -l "$CERT" "$KEY" | sed 's/^/   /'

  grdctl --system rdp set-tls-cert "$CERT"
  grdctl --system rdp set-tls-key  "$KEY"
  grdctl --system rdp enable

  step "RDP credentials"
  if grdctl --system rdp set-credentials "$STD_USER" "$PW" >/dev/null 2>&1; then
    echo "   set to '$STD_USER', matching the Unix password"
  else
    echo "   this grdctl wants them typed — enter '$STD_USER' and the SAME password"
    grdctl --system rdp set-credentials
  fi

  systemctl enable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
  systemctl restart gnome-remote-desktop.service
else
  step "remote desktop"
  echo "   not installed — server, so no certificate and no RDP credentials"
fi
unset PW PW2

# ---------------------------------------------------------------- verify

step "verification"
if has_rdp; then
  if ss -tlnp | grep -q ':3389'; then
    ss -tlnp | grep ':3389' | sed 's/^/   /'
  else
    echo "   NOTHING LISTENING ON 3389"
    echo "   check: journalctl -u gnome-remote-desktop -n 30 --no-pager"
    echo "   most likely the certificate ownership above"
  fi
else
  # On a server SSH is the only way in, so its absence is the equivalent emergency.
  if ss -tlnp | grep -q ':22 '; then
    ss -tlnp | grep ':22 ' | sed 's/^/   /'
  else
    echo "   NOTHING LISTENING ON 22 — this machine has no way in but the console"
    echo "   check: systemctl status ssh; ls -l /etc/ssh/ssh_host_*"
  fi
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if has_rdp; then
  cat <<SUMMARY

$NEWHOST is ready for $PERSON.
   RDP to     ${IP:-<no address yet>}:3389
   login      $STD_USER + the password just set, for BOTH desktop and RDP

Hand over that address and password, and tell them to run 'desk-passwd' to set their own.
The login hint keeps asking until they do.

REBOOT NOW and verify RDP from cold. A live session works even when credentials are wrong;
the failure only appears when the machine must build a session from nothing.
Then give this machine a static DHCP reservation on your router.
SUMMARY
else
  cat <<SUMMARY

$NEWHOST is ready for $PERSON.
   ssh        $STD_USER@${IP:-<no address yet>}
   login      $STD_USER + the password just set (console and sudo)

Add their SSH key with ssh-copy-id, and tell them to run 'desk-passwd' to set their own
password. Then give this machine a static DHCP reservation on your router.

REBOOT NOW and check it comes back on its own before you rely on it: a clone that boots
once is not the same as a clone that boots.
SUMMARY
fi

if [ "$NO_REBOOT" -eq 1 ]; then
  echo
  echo "not rebooting (--no-reboot). Run 'sudo reboot' before handing over."
else
  printf '\nReboot now? [y/N] '
  read -r reply
  case "$reply" in [yY]|[yY][eE][sS]) systemctl reboot ;; *) echo "remember to reboot" ;; esac
fi
