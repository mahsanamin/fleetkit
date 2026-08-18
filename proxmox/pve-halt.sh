#!/usr/bin/env bash
#
# pve-halt.sh — shut every guest down cleanly, then halt the host.
#
# Runs on the PROXMOX HOST, as root. Installed as /usr/local/bin/pve-halt.
#
#   pve-halt            # REPORT only. Changes nothing.
#   pve-halt --guests   # stop the guests, leave the host up
#   pve-halt --halt     # stop the guests, then power the host off
#   pve-halt --halt --force   # power off even if a guest refused to stop
#
# Reporting is the default deliberately: running it bare used to stop every guest, which
# takes the proxy container with it and so removes the SSH path you were using. That is a
# surprise you only get to have once, in the office car park.
#
# It enumerates what is actually running rather than hardcoding VMIDs, so it stays correct as
# the fleet grows. Nothing here is backed up off-box, so it refuses to halt while a guest is
# still up unless you insist — a guest killed by a power cut is a guest with a dirty
# filesystem, and there is no restore to fall back on.
#
set -euo pipefail

HALT=0
FORCE=0
GUESTS=0
WAIT=60

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --halt)   HALT=1; GUESTS=1; shift ;;
    --guests) GUESTS=1; shift ;;
    --force) FORCE=1; shift ;;
    --wait)  WAIT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v qm >/dev/null 2>&1 || die "no qm — this must run on the Proxmox host"

VMS="$(qm list | awk '$3=="running"{print $1}')"
CTS="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')"

step "running guests"
[ -n "$VMS$CTS" ] || echo "   none"
for v in $VMS; do echo "   VM  $v  $(qm config "$v" | awk -F': ' '/^name:/{print $2}')"; done
for c in $CTS; do echo "   CT  $c  $(pct config "$c" | awk -F': ' '/^hostname:/{print $2}')"; done

if [ "$GUESTS" -ne 1 ]; then
  echo
  echo "Report only. Nothing was changed."
  echo "  --guests   stop these, leave the host up"
  echo "  --halt     stop these, then power off"
  exit 0
fi

# VMs first, then containers: the proxy container is usually the way in, so it goes last.
step "shutting down"
for v in $VMS; do echo "   qm shutdown $v"; qm shutdown "$v" --timeout "$WAIT" >/dev/null 2>&1 || echo "      refused or timed out"; done
for c in $CTS; do echo "   pct shutdown $c"; pct shutdown "$c" --timeout "$WAIT" >/dev/null 2>&1 || echo "      refused or timed out"; done

step "state"
STILL=""
for v in $VMS; do [ "$(qm status "$v" | awk '{print $2}')" = "running" ] && STILL="$STILL VM:$v"; done
for c in $CTS; do [ "$(pct status "$c" | awk '{print $2}')" = "running" ] && STILL="$STILL CT:$c"; done

if [ -n "$STILL" ]; then
  echo "   STILL RUNNING:$STILL"
  echo "   A guest that ignores ACPI usually has no qemu-guest-agent installed."
else
  echo "   all guests stopped"
fi

if [ "$HALT" -ne 1 ]; then
  echo
  echo "Not halting (no --halt). Host is still up."
  exit 0
fi

if [ -n "$STILL" ] && [ "$FORCE" -ne 1 ]; then
  die "refusing to halt with guests still running:$STILL
       Stop them by hand, or re-run with --force if you accept the dirty shutdown."
fi

step "powering off the host"
# 'shutdown -h now' HALTS: on this board that left the fans spinning and a cursor on the
# screen, needing the power button held. 'poweroff' asks for an actual ACPI power-off.
echo "   your SSH session will drop now — that is the success case"
sleep 2
poweroff
