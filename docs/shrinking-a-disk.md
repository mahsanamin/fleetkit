# Shrinking a Proxmox VM disk

Proxmox grows a virtual disk and **never shrinks one**. A clone inherits the source's size
whatever you pass at clone time. `proxmox/desk-shrink.sh` does it by hand, in the only safe order:

```
1. shrink the ext4 filesystem   (smallest, leaves slack)
2. shrink the partition         (must still contain the filesystem)
3. shrink the LVM volume        (must still contain the partition table)
4. update the VM config         (qm rescan)
```

Reverse that order, or get the sector arithmetic wrong, and the disk is gone. The script
defaults to a dry run and verifies the filesystem between every step.

**Do it on a disposable clone, and before templating.** A failed shrink then costs
`qm destroy --purge` and a re-clone. After templating you would be repeating a risky
operation per instance instead of once.

## Three traps, all hit for real

### `partx` cannot read a Proxmox disk

Every LVM-thin volume is a device-mapper device, and kernel partition scanning is disabled on
those: `partx -a` returns `error adding partitions 1-2`. `kpartx` works but is not on a stock
PVE host. Use `losetup` with an offset, which is util-linux and installs nothing:

```bash
losetup --find --show --offset $((START*512)) --sizelimit $((SECTORS*512)) /dev/vg/lv
```

### Two warnings that are just noise

- `Re-reading the partition table failed: Invalid argument` — same DM limitation. The guest
  reads the table fresh at boot.
- `lvreduce`: `No file system found` — it is looking for a filesystem on a volume that holds a
  partition table.

### The GPT backup header — the one that destroys data

`sfdisk` writes the GPT backup header at the end of the device **as it is at that moment**.
After `lvreduce` that header is past the end of the volume, and the GPT is half valid.

> **Never fix it with `sfdisk --dump | sfdisk`.** With an invalid backup header, `sfdisk`
> cannot validate the GPT, silently falls back to reading the **protective MBR**, and dumps a
> single `0xee` entry. Writing that back creates a DOS label and **wipes the GPT**.
>
> `sfdisk --relocate gpt-bak-hdr` is the documented fix and PVE 9's util-linux answers
> `unsupported relocation operation`.

The script instead saves the table **before** any modification, while the GPT is still valid,
and rebuilds it explicitly with a `label: gpt` header after `lvreduce`.

### Recovering a wiped table

Only the first 34 sectors are involved, so **the filesystem is untouched**. Rebuild from known
geometry — for a standard Ubuntu install that is an EFI partition and one ext4 root:

```bash
printf '%s\n' 'label: gpt' 'unit: sectors' \
  'start=2048, size=2201600, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' \
  "start=2203648, size=<sectors>, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4" \
  > /root/rebuild.sfdisk
sfdisk --force /dev/vg/lv < /root/rebuild.sfdisk
```

The script leaves its pre-change table at `/root/desk-shrink-<vmid>-table.<epoch>` so the real
geometry is always on hand.
