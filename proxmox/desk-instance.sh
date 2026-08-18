#!/usr/bin/env bash
#
# desk-instance.sh — create a desktop VM, either from the golden template or from a dump.
#
# Runs on the PROXMOX HOST, as root.
#
#   # build a golden once, from the image desk-image.sh produced
#   ./desk-instance.sh --from-dump local:backup/vzdump-qemu-150-....vma.zst \
#                      --vmid 9000 --name golden
#
#   # then one instance per person
#   ./desk-instance.sh --person <person> --vmid <vmid> --template 9000
#
# A convention that works: one live machine you never clone FROM, one sysprepped template,
# and numbered instances above it. Keep the record of who holds which VMID wherever you keep
# notes — this script stays generic.
#
set -euo pipefail

TEMPLATE=9000
FROM_DUMP=""
VMID=""
PERSON=""
NAME=""
CORES=6
MEMORY=10240
BALLOON=4096
STORAGE=local-lvm
START=0
ASSUME_YES=0

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --person)    PERSON="${2:?}"; shift 2 ;;
    --vmid)      VMID="${2:?}"; shift 2 ;;
    --name)      NAME="${2:?}"; shift 2 ;;
    --template)  TEMPLATE="${2:?}"; shift 2 ;;
    --from-dump) FROM_DUMP="${2:?}"; shift 2 ;;
    --cores)     CORES="${2:?}"; shift 2 ;;
    --memory)    MEMORY="${2:?}"; shift 2 ;;
    --balloon)   BALLOON="${2:?}"; shift 2 ;;
    --storage)   STORAGE="${2:?}"; shift 2 ;;
    --start)     START=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v qm >/dev/null || die "no qm — this must run on the Proxmox host, not in a guest"

[ -n "$VMID" ] || die "--vmid is required"
case "$VMID" in *[!0-9]*) die "--vmid must be numeric" ;; esac

[ -n "$NAME" ] || { [ -n "$PERSON" ] || die "give --person or --name"; NAME="desk-$PERSON"; }

# The single most important guard in this script.
if qm status "$VMID" >/dev/null 2>&1; then
  die "VM $VMID already exists ($(qm config "$VMID" | awk -F': ' '/^name:/{print $2}')). Pick a free ID."
fi
if pct status "$VMID" >/dev/null 2>&1; then
  die "CT $VMID already exists. VMIDs are shared between VMs and containers."
fi

pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "storage '$STORAGE' not found"

echo "== plan"
if [ -n "$FROM_DUMP" ]; then
  echo "   restore  $FROM_DUMP"
else
  qm status "$TEMPLATE" >/dev/null 2>&1 || die "template VM $TEMPLATE does not exist"
  if ! qm config "$TEMPLATE" | grep -q '^template: 1'; then
    echo "   WARNING: VM $TEMPLATE is not a template. A full clone of a RUNNING VM will fail,"
    echo "            and a clone of a live VM shares its identity."
  fi
  echo "   clone    VM $TEMPLATE (full)"
fi
echo "   new VM   $VMID  name '$NAME'"
echo "   storage  $STORAGE"
echo "   cores    $CORES     memory ${MEMORY}MB (balloon ${BALLOON}MB)"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Create VM %s? [y/N] ' "$VMID"
  read -r reply
  case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; exit 1 ;; esac
fi

if [ -n "$FROM_DUMP" ]; then
  echo "== qmrestore"
  qmrestore "$FROM_DUMP" "$VMID" --storage "$STORAGE" --unique 1
else
  echo "== qm clone"
  qm clone "$TEMPLATE" "$VMID" --name "$NAME" --full --storage "$STORAGE"
fi

echo "== resources"
qm set "$VMID" --name "$NAME" --cores "$CORES" --memory "$MEMORY" --balloon "$BALLOON" --onboot 1

echo
echo "== result"
qm config "$VMID" | grep -E '^(name|memory|balloon|cores|scsi0|net0|agent|onboot):' || true

if [ "$START" -eq 1 ]; then
  echo "== starting"
  qm start "$VMID"
fi

cat <<NEXT

NEXT:
  qm start $VMID                      # if not started already
  # then, in the guest's console or over RDP once it has an address:
  sudo desk-claim ${PERSON:-<username>} "<Full Name>"

A fresh restore/clone still carries the SOURCE's machine-id, SSH host keys, RDP
credentials and TLS CN. desk-claim resets all of that. Until it has run, do NOT leave
this VM on the LAN alongside its source.
NEXT
