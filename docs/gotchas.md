# Proxmox and Ubuntu gotchas

Small things that each cost real time.

## `qemu-guest-agent` is two steps, and the flag is the easy one

`--agent enabled=1` only tells the **host** to expect an agent. It does nothing until the
package is installed **inside** the guest. Without it:

- the host cannot report the guest's IP — `qm agent <id> network-get-interfaces` returns nothing
- `qm shutdown` and `qm reboot` fail outright
- backups cannot freeze the filesystem, so `--mode snapshot` is only crash-consistent

**Finding a guest's IP without an agent** — read the MAC from the config and match it in the
neighbour table, provoking an entry first if it is stale:

```bash
qm config <vmid> | grep -o 'virtio=[0-9A-F:]*'
for i in $(seq 1 254); do ping -c1 -W1 192.168.1.$i >/dev/null 2>&1 & done; wait
ip neigh | grep -i <mac>
```

## `qm set --net0` without the MAC regenerates it

```bash
qm set 201 --net0 virtio,bridge=vmbr0                      # NEW random MAC
qm set 201 --net0 virtio=<the:existing:mac>,bridge=vmbr0    # keeps it
```

Silently breaks any DHCP reservation you made against the old address.

## `pct set --features` leaves a `[pve:pending]` section

The change does not apply until the container restarts, and until then the config file ends
with a pending block. **An appended line lands inside that block**, where Proxmox treats it as
pending rather than active config — so a passthrough looks configured and never applies.

Reboot first to flush it, confirm the section is gone, then append. Generally: before
appending to `/etc/pve/lxc/<id>.conf`, check the file does not end in a `[...]` header.
Snapshots create these too.

## `shutdown -h now` halts without powering off

On some boards that leaves the fans spinning and a cursor on screen, needing the power button
held. Use **`poweroff`**, which asks for an actual ACPI power-off.

## Stopping the guests can sever your way in

If your VPN node or jump host is itself a guest, stopping all guests makes the **hypervisor
unreachable** — and you finish the shutdown at the power button. Put the remote-access agent
on the **host** as well, or keep a path that does not depend on what you just stopped.

## Pasted heredocs pick up indentation

Pasting a `cat <<'EOF' … EOF` block into a terminal can indent every line, so the terminator
arrives as `  EOF` and never matches — the shell sits at a continuation prompt. Worse, a
pasted long line can be **split**, leaving a bare `>> file` redirect that quietly reads your
keystrokes into a config file.

Use an editor, or a file, or several short single-line commands. This is why these scripts are
files rather than instructions to paste.

## `curl -I` against the Proxmox API returns 501

`pveproxy` does not implement HEAD. A 501 means your proxy reached Proxmox successfully; a
genuinely broken upstream gives 502. Test with a GET.

## Mixed RAM runs at the slowest module

Four DIMMs where one is rated slower drags **all** of them down. Check per slot rather than
trusting the total:

```bash
dmidecode -t 17 | grep -E 'Locator:|Size:|Configured Memory Speed:|Part Number:'
```

Also watch channel balance: 48 GB on one channel and 16 on the other runs part of the memory
single-channel, whatever the total says. And mixed vendors or ranks is the configuration that
produces garbled output — which on a hypervisor corrupts guests silently, and the corruption
reaches your backups. Run memtest before trusting a new set.
