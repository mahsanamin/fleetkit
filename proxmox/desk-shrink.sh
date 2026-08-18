#!/usr/bin/env bash
#
# desk-shrink.sh — shrink a desktop VM's disk, for real, from 400G down to a cap.
#
# Runs on the PROXMOX HOST, as root, with the VM SHUT DOWN.
#
#   ./desk-shrink.sh --vmid 201                 # DRY RUN: prints the plan, changes nothing
#   ./desk-shrink.sh --vmid 201 --apply         # actually does it
#   ./desk-shrink.sh --vmid 201 --size 200 --apply
#
# Set PROTECT below to the VMIDs that must never be shrunk (your daily driver).
#
# Proxmox can grow a virtual disk and never shrink one, so this does the four steps by hand,
# in the only order that is safe:
#
#   1. shrink the ext4 filesystem   (smallest, leaves slack)
#   2. shrink the partition         (must still contain the filesystem)
#   3. shrink the LVM volume        (must still contain the partition table)
#   4. update the VM config         (qm rescan)
#
# Reversing that order destroys data. So does getting the arithmetic wrong, which is why the
# default is a dry run and every step is verified before the next begins.
#
# ONLY works on the simple layout these desktops actually have: GPT, an EFI partition, and a
# plain ext4 root as the LAST partition. It refuses anything else — notably LVM inside the
# guest, which would need its own shrink first.
#
# Uses only tools already on a PVE host (util-linux, e2fsprogs, lvm2). Installs nothing.
#
set -euo pipefail

VMID=""
TARGET_GB=200
FS_SLACK_GB=12          # filesystem stays this far below the target, for the table and slack
APPLY=0
PROTECT=""            # space-separated VMIDs this script must never touch

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
note() { echo "   $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid)  VMID="${2:?}"; shift 2 ;;
    --size)  TARGET_GB="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v qm >/dev/null 2>&1 || die "no qm — this must run on the Proxmox host"
[ -n "$VMID" ] || die "--vmid is required"
case "$VMID" in *[!0-9]*) die "--vmid must be numeric" ;; esac

# Hard guards. This script destroys data if pointed at the wrong thing.
# Refuse anything listed in PROTECT. Put your daily driver's VMID here.
for pv in $PROTECT; do
  [ "$VMID" = "$pv" ] && die "VM $VMID is in PROTECT — refusing. Edit PROTECT if you mean it."
done
qm status "$VMID" >/dev/null 2>&1 || die "VM $VMID does not exist"
[ "$(qm status "$VMID" | awk '{print $2}')" = "stopped" ] \
  || die "VM $VMID is running. Shut it down first: qm shutdown $VMID"

step "disk"
DISK_SPEC="$(qm config "$VMID" | awk -F': ' '/^scsi0:/{print $2}')"
[ -n "$DISK_SPEC" ] || die "VM $VMID has no scsi0"
VOLID="${DISK_SPEC%%,*}"
LVPATH="$(pvesm path "$VOLID")" || die "cannot resolve $VOLID"
[ -b "$LVPATH" ] || die "$LVPATH is not a block device"
note "volume  $VOLID"
note "path    $LVPATH"

CUR_BYTES="$(blockdev --getsize64 "$LVPATH")"
CUR_GB=$(( CUR_BYTES / 1024 / 1024 / 1024 ))
note "current ${CUR_GB}G"
note "target  ${TARGET_GB}G"
[ "$TARGET_GB" -lt "$CUR_GB" ] || die "target ${TARGET_GB}G is not smaller than current ${CUR_GB}G"

step "partitions"
# NOTE: partx/kpartx do not work here. A Proxmox LVM-thin disk is a device-mapper volume,
# and kernel partition scanning is disabled on those. losetup with an offset exposes the
# partition directly and is part of util-linux, so nothing has to be installed on the host.
command -v losetup >/dev/null 2>&1 || die "no losetup (util-linux)"
command -v sfdisk  >/dev/null 2>&1 || die "no sfdisk (util-linux)"

sfdisk --dump "$LVPATH" >/tmp/.ds-table.$$ 2>/dev/null || die "cannot read the partition table"
grep -q '^label: gpt' /tmp/.ds-table.$$ || die "not a GPT disk — this script only handles the desktop layout"

read -r PART_NUM START_SECTOR PART_SECTORS <<EOF
$(awk '/start=/{gsub(/,/,""); s=""; z="";
        for(i=1;i<=NF;i++){ if($i=="start=") s=$(i+1); if($i=="size=") z=$(i+1) }
        dev=$1; n=dev; sub(/.*[^0-9]/,"",n);
        ln=n; ls=s; lz=z }
      END{ print ln, ls, lz }' /tmp/.ds-table.$$)
EOF
rm -f /tmp/.ds-table.$$

[ -n "${PART_NUM:-}" ] && [ -n "${START_SECTOR:-}" ] && [ -n "${PART_SECTORS:-}" ] \
  || die "could not parse the partition table"
note "last partition is #$PART_NUM, starts at sector $START_SECTOR, $PART_SECTORS sectors"

SECTOR=512
LOOP="$(losetup --find --show --offset $(( START_SECTOR * SECTOR )) \
        --sizelimit $(( PART_SECTORS * SECTOR )) "$LVPATH")" \
  || die "losetup failed"
cleanup() { losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT
note "mapped as $LOOP"

FSTYPE="$(blkid -o value -s TYPE "$LOOP" || true)"
[ "$FSTYPE" = "ext4" ] || die "last partition is '$FSTYPE', not ext4.
       LVM inside the guest would need its own shrink first — stop here."

USED_KB="$(dumpe2fs -h "$LOOP" 2>/dev/null | awk -F: '/Block count/{bc=$2} /Block size/{bs=$2} END{print int(bc*bs/1024)}')"
USED_GB=$(( USED_KB / 1024 / 1024 ))
note "filesystem is currently ${USED_GB}G"

FS_TARGET_GB=$(( TARGET_GB - FS_SLACK_GB ))
[ "$FS_TARGET_GB" -gt 20 ] || die "target too small to leave slack"

MIN_BLOCKS="$(resize2fs -P "$LOOP" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')"
MIN_GB=$(( (MIN_BLOCKS * 4) / 1024 / 1024 + 1 ))
note "filesystem minimum is about ${MIN_GB}G"
[ "$FS_TARGET_GB" -gt "$MIN_GB" ] \
  || die "cannot fit: filesystem needs ${MIN_GB}G, plan allows ${FS_TARGET_GB}G"

# --- the plan ---------------------------------------------------------------
# leave 2 MiB at the end of the volume for the GPT backup header
NEW_PART_SECTORS=$(( (TARGET_GB * 1024 * 1024 * 1024 / SECTOR) - START_SECTOR - 4096 ))

cat <<PLAN

PLAN for VM $VMID
   1. e2fsck -f            partition $PART_NUM (via $LOOP)
   2. resize2fs            partition $PART_NUM -> ${FS_TARGET_GB}G
   3. sfdisk resize part $PART_NUM  -> $NEW_PART_SECTORS sectors (start stays $START_SECTOR)
   4. lvreduce             $LVPATH -> ${TARGET_GB}G
   5. qm rescan --vmid $VMID

   filesystem now ${USED_GB}G, minimum ${MIN_GB}G, will become ${FS_TARGET_GB}G
   volume     now ${CUR_GB}G,                      will become ${TARGET_GB}G
PLAN

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "DRY RUN — nothing was changed. Re-run with --apply to do it."
  exit 0
fi

echo
echo "This rewrites a partition table and shrinks a logical volume. If VM $VMID matters,"
echo "stop now and snapshot or re-clone it instead."
printf 'Type the VMID (%s) to proceed: ' "$VMID"
read -r confirm
[ "$confirm" = "$VMID" ] || { echo "aborted"; exit 1; }

step "1/5 e2fsck"
e2fsck -fy "$LOOP" || die "e2fsck failed — do not continue"

step "2/5 resize2fs -> ${FS_TARGET_GB}G"
resize2fs "$LOOP" "${FS_TARGET_GB}G" || die "resize2fs failed"
e2fsck -fy "$LOOP" || die "filesystem is not clean after resize — STOP"

step "3/5 partition table"
losetup -d "$LOOP"; trap - EXIT
SAVED_TABLE="/root/desk-shrink-${VMID}-table.$(date +%s)"
sfdisk --dump "$LVPATH" > "$SAVED_TABLE" || die "cannot save the original table"
note "original table saved to $SAVED_TABLE"
echo ",$NEW_PART_SECTORS" | sfdisk --force -N "$PART_NUM" "$LVPATH" || die "sfdisk failed"
LOOP="$(losetup --find --show --offset $(( START_SECTOR * SECTOR )) \
        --sizelimit $(( NEW_PART_SECTORS * SECTOR )) "$LVPATH")" \
  || die "cannot re-map after the edit — STOP, do not lvreduce"
trap cleanup EXIT
e2fsck -fn "$LOOP" >/dev/null || die "filesystem unreadable after partition edit — STOP"
note "partition shrunk and filesystem still intact"
losetup -d "$LOOP"; trap - EXIT

step "4/5 lvreduce -> ${TARGET_GB}G"
lvreduce --yes -L "${TARGET_GB}G" "$LVPATH" || die "lvreduce failed"

# The GPT backup header still sits at the end of the OLD device. Do NOT try to fix that by
# dumping and re-writing the table: with an invalid backup header sfdisk falls back to
# reading the PROTECTIVE MBR, and writing that back destroys the GPT entirely. That happened
# on VM 201, 2026-08-15.
#
# Instead the table is rebuilt from the geometry captured BEFORE anything was touched, which
# writes both headers correctly for the new device size.
step "4b/5 GPT headers"
{
  echo 'label: gpt'
  echo 'unit: sectors'
  awk '/start=/{print}' "$SAVED_TABLE" \
    | sed "s/size=[[:space:]]*$PART_SECTORS/size= $NEW_PART_SECTORS/"
} > /tmp/.ds-newtable.$$
sfdisk --force "$LVPATH" < /tmp/.ds-newtable.$$ >/dev/null 2>&1 \
  || die "could not rebuild the GPT. Table saved at $SAVED_TABLE — rebuild by hand."
rm -f /tmp/.ds-newtable.$$
note "GPT rewritten, both headers placed for a ${TARGET_GB}G volume"
sfdisk --verify "$LVPATH" 2>&1 | sed 's/^/   /' || true

step "5/5 qm rescan"
qm rescan --vmid "$VMID" >/dev/null
qm config "$VMID" | grep '^scsi0:' | sed 's/^/   /'

cat <<NEXT

Done. Verify before handing the machine over:

  qm start $VMID
  # in the guest:
  df -h /            # expect about $(( FS_TARGET_GB ))G
  lsblk

The filesystem is ${FS_TARGET_GB}G inside a ${TARGET_GB}G disk, so a few GB are unused. To
claim them, grow the partition to fill and then the filesystem:

  # in the guest, as root — the partition is already ~199G, only the filesystem is short,
  # so this grows it online with no partition edit and no downtime
  resize2fs /dev/sda$PART_NUM

If anything looks wrong, this VM is disposable: qm destroy $VMID --purge and clone again.
NEXT
