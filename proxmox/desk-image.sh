#!/usr/bin/env bash
#
# desk-image.sh — take a clean, restorable image of a VM.
#
# Runs on the PROXMOX HOST, as root.
#
# Uses --mode stop deliberately. snapshot mode is fine for routine backups when
# qemu-guest-agent is installed, since it can freeze the filesystem. stop is right for a
# MASTER image that other machines get built from: a stopped guest removes every
# consistency question instead of answering it. The guest is restarted afterwards if it was
# running before.
#
# Without the agent installed IN the guest, snapshot mode cannot freeze anything and you get
# a crash-consistent image. See docs/gotchas.md.
#
#   ./desk-image.sh --vmid 150                    # image VM 150 to 'local'
#   ./desk-image.sh --vmid 150 --storage backups
#   ./desk-image.sh --vmid 150 --keep-stopped     # leave the guest down afterwards
#
set -euo pipefail

VMID=""
STORAGE=local
KEEP_STOPPED=0
ASSUME_YES=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid)         VMID="${2:?}"; shift 2 ;;
    --storage)      STORAGE="${2:?}"; shift 2 ;;
    --keep-stopped) KEEP_STOPPED=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -n "$VMID" ] || die "--vmid is required"
command -v qm >/dev/null      || die "no qm — this must run on the Proxmox host, not in a guest"
command -v vzdump >/dev/null  || die "no vzdump"
qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist"

# Does the target storage actually accept backups?
pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "storage '$STORAGE' not found"
if ! pvesm status --content backup 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  die "storage '$STORAGE' does not hold backups (LVM-thin cannot). Use a dir or NFS storage."
fi

PRE_STATE="$(qm status "$VMID" | awk '{print $2}')"

echo "== source"
qm config "$VMID" | grep -E '^(name|memory|cores|scsi0|net0|agent):' || true
echo "   state: $PRE_STATE"
echo
echo "== target storage '$STORAGE'"
pvesm status --storage "$STORAGE"
echo
echo "The dump is roughly the guest's USED space, zstd-compressed — not its provisioned"
echo "size. If the storage above looks tight, stop before you fill the root filesystem."
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Shut down VM %s and image it to %s? [y/N] ' "$VMID" "$STORAGE"
  read -r reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; exit 1 ;; esac
fi

echo "== vzdump (this stops the guest)"
vzdump "$VMID" --mode stop --compress zstd --storage "$STORAGE"

# vzdump's stop mode restarts a guest that was running, but do not rely on it.
POST_STATE="$(qm status "$VMID" | awk '{print $2}')"
if [ "$PRE_STATE" = "running" ] && [ "$POST_STATE" != "running" ] && [ "$KEEP_STOPPED" -ne 1 ]; then
  echo "== guest did not come back on its own, starting it"
  qm start "$VMID"
fi
echo "   state now: $(qm status "$VMID" | awk '{print $2}')"

echo
echo "== newest dumps for VM $VMID"
pvesm list "$STORAGE" --content backup 2>/dev/null | grep -E "(^|/)vzdump-qemu-${VMID}-" | tail -3 || \
  echo "   (none listed — check 'pvesm list $STORAGE')"

cat <<'NEXT'

NEXT, and do not skip it:
  1. Copy the dump OFF this host. A backup on the machine it backs up is not a backup.
  2. Verify RDP into the source VM still works.
  3. Build the golden from this dump:
       ./desk-instance.sh --from-dump <file> --vmid 9000 --name golden
NEXT
