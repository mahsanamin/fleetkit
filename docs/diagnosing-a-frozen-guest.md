# When a guest freezes and leaves nothing behind

A desktop VM stopped: powered on, qemu alive and burning CPU, but unreachable on every path
and silent in every log. It had to be hard stopped. This is what that looks like, how to tell
it apart from the remote-desktop faults it resembles, and how to make the next one
diagnosable.

## Recognising it

| Check | A frozen guest |
|---|---|
| Hypervisor | `running`. Uptime keeps counting - that is the **qemu process**, not the guest |
| Guest agent | `qga command 'guest-ping' failed - got timeout` |
| Shutdown | Times out. Shutdown asks the guest politely and a hung guest cannot answer |
| Network | Nothing. Not just a service - no ping, no SSH, and **no VPN address either** |
| Console | A frozen frame. Check its clock: if it is hours old, it is stale, not live |
| Journal | Stops mid-line. No shutdown sequence, no panic, no OOM |

**The VPN address is the fastest discriminator.** A VPN follows the machine across a DHCP
change, so if the LAN address *and* the VPN address are both dead, the guest is not merely at
a new address.

**Prove the address question rather than assuming it.** Sweep the subnet and look for the
guest's MAC. Absent from ARP entirely means it is not on the network at any address:

```bash
for i in $(seq 1 254); do (ping -c1 -W300 192.168.1.$i >/dev/null 2>&1 &); done; sleep 5
arp -an | grep -i <mac-prefix>
```

Docs go stale. In one real case a *healthy* guest had moved address, the documented address
was pinged, and that produced a confident wrong conclusion that two machines had died
together. Static reservations are worth the ten minutes.

## Do not confuse it with the remote-desktop faults

Three different faults present as "I cannot connect", and the fix for one does nothing for the
others. See [remote-desktop-on-wayland.md](remote-desktop-on-wayland.md) for the first two.

| Symptom | Fault |
|---|---|
| RDP refuses/resets, **SSH works** | The greeter died. Restart gdm, then gnome-remote-desktop |
| RDP resets **from one client only**, fine from another machine | Stale per-client state in GRD. Restart gnome-remote-desktop |
| **Nothing** answers, including SSH and the VPN | The guest is frozen. This document |

A loopback health check passes during the second and third of those, so never treat "the
service looks fine on the box" as proof a client can reach it.

## Before you hard stop it, read the console

`Stop` destroys the only live evidence. Look first, then:

```bash
qm stop <VMID> && qm start <VMID>
```

Prefer stop+start over `reset`: it gives a fresh qemu process, reattaches the guest agent and
clears a stale console framebuffer. Expect an unclean boot and a journal replay afterwards.

## After it is back, the evidence is in the previous boot

```bash
journalctl --list-boots | tail -5
journalctl -k -b -1 --no-pager | tail -60
journalctl -b -1 -p err --no-pager | tail -40
```

Compare the **last lines of the dead boot against a healthy one**. A clean shutdown ends with
`Syncing filesystems … Journal stopped`. A freeze just stops mid-line. That difference tells
you it was a freeze and not something rebooting the machine, and `--list-boots` gives you the
minute it died.

Then read `sysstat`, which most people forget is already running:

```bash
sar   -f /var/log/sysstat/sa<DD> -s 15:30:00 -e 16:45:00    # CPU and iowait
sar -r -f /var/log/sysstat/sa<DD> -s 15:30:00 -e 16:45:00   # memory
sar -b -f /var/log/sysstat/sa<DD>                           # disk
```

In the case that prompted this document, the last sample before death showed **99.76% idle,
2.4 GB of 24 GB used, zero swap, 1.3 tps**. An idle, healthy machine that stops instantly did
not do it to itself, which pointed the investigation at the host rather than the guest and
ruled out OOM, runaway processes and I/O saturation in one step.

## Why there was no evidence, and how to fix that

A stock desktop is configured so a hang leaves nothing:

| Setting | Stock | Effect |
|---|---|---|
| `kernel.nmi_watchdog` | 0 | Hard-lockup detector off. A wedged CPU prints nothing |
| `kernel.hung_task_panic` | 0 | A task stuck >120s is logged, never panics |
| `kernel.panic` | 0 | On panic it hangs forever instead of rebooting |
| serial console | absent | Nothing escapes if disk I/O is dead |
| kdump | armed | Only fires on a **panic**. A hang is not a panic |

kdump armed with `/var/crash` empty is itself a finding: **it never panicked, it hung.**

And if the hang is storage-related the kernel physically cannot write a log, so the silence is
not missing evidence - it is what this configuration produces.

`ubuntu/desk-crash-trap.sh` changes all of it:

```bash
sudo ./desk-crash-trap.sh              # report, change nothing
sudo ./desk-crash-trap.sh --apply
qm set <VMID> --serial0 socket         # on the HYPERVISOR
sudo reboot                            # so the console argument takes effect
```

**The serial console is the highest-value part.** Kernel output leaves over a virtual serial
port, so it survives a guest that cannot write to its own disk - exactly the case that
produced silence. Read it with `qm terminal <VMID>`.

The rest turns a hang into a panic (which kdump captures), reboots 30 seconds later so a
freeze costs minutes instead of a morning, and samples sysstat every minute instead of every
ten.

One trade-off, stated plainly: `hung_task_panic` reboots on **any** 120-second uninterruptible
hang, including a merely slow disk. On a remote desktop that is usually right, because a hung
desktop is already unusable. `--no-panic-on-hang` keeps the diagnostics without the reboot.

`nmi_watchdog` may not arm in a VM at all - the hard-lockup detector needs a PMU the guest may
not have. The script reads the value back and tells you rather than assuming.

## If it is not the guest

An idle guest that stops instantly usually points below itself. On the host, around the minute
the journal stopped:

```bash
journalctl --since "<date> 16:20" --until "<date> 17:00" --no-pager \
  | grep -iE "error|nvme|i/o|lvm|kvm|oom|blk"
dmesg -T | grep -iE "nvme|i/o error|ata|md/raid" | tail -30
```

Storage that stalls under a guest produces precisely this signature: alive as a process,
spinning CPU, unable to log, unable to answer.
