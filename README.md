# fleetkit

Set one Ubuntu machine up properly, then turn it into as many as you need.

Small, idempotent bash scripts in two halves that are useful separately:

- **[`ubuntu/`](#ubuntu--run-on-the-machine-itself-as-your-normal-user)** works on **any Ubuntu
  box** — laptop, bare metal, VM, container, any hypervisor or none. One command gives you the
  standard build: base packages, zsh + Starship with a prompt that tells you which machine you
  are on, optional Docker and mise, and working remote desktop on Wayland.
- **[`proxmox/`](#proxmox--run-on-the-proxmox-host-as-root)** is for turning one such machine
  into many: image it, sysprep the copy into a template, clone it per person, and stamp each
  clone with its own identity.

If you only ever set up one machine, the first half is the whole point and you can ignore the
second.

No framework, no agent, no state file — bash and the tools already on the box.

## Why this exists

Setting up an Ubuntu desktop for remote use takes a day, mostly spent discovering that xrdp no
longer works on Wayland, that GNOME Remote Desktop needs credentials that are a real Unix
account, and that its TLS certificate must be owned by the daemon or the service reports
healthy while listening to nothing.

Doing that per colleague takes a day each. This does it once.

The [`docs/`](docs/) directory is half the value — every trap in there cost hours to find.

## Quickstart

**A fresh guest, one command, no credentials needed:**

```bash
curl -fsSL https://raw.githubusercontent.com/mahsanamin/fleetkit/main/bootstrap.sh \
  | bash -s -- --colour green --label MY-BOX --docker
```

**Or clone and run it:**

```bash
git clone https://github.com/mahsanamin/fleetkit.git
cd fleetkit
ubuntu/guest-setup.sh --colour green --docker
```

Every script takes `--check` or defaults to a dry run, and re-running is safe.

## What's here

### `proxmox/` — run on the Proxmox host, as root

| Script | Does |
|---|---|
| `desk-image.sh` | Clean `vzdump` of a VM, restarts it afterwards, tells you to get the dump off the box |
| `desk-instance.sh` | Create a VM from a template (`--template`) or a dump (`--from-dump`). Refuses an occupied VMID |
| `desk-shrink.sh` | Actually shrink a disk — filesystem, partition, LVM, config. Dry run by default |
| `pve-halt.sh` | Stop every guest cleanly, then power off. Reports by default, `--halt` to act |

### `ubuntu/` — run on the machine itself, as your normal user

Nothing here knows or cares about Proxmox.

| Script | Does |
|---|---|
| `guest-setup.sh` | The standard build: base packages, zsh + Starship, optional Docker and mise, keychain |
| `desk-golden-prep.sh` | Turn a copy into a reusable template: shared account, delete the original, sysprep, credential sweep |
| `desk-claim.sh` | Give a clone its own identity: hostname, certificate, machine-id, host keys, password. Also how you rename one later |
| `desk-passwd.sh` | Change a password **and** the remote-desktop credentials together, so they cannot drift apart |
| `desk-hint.sh` | Login hint pointing users at `desk-passwd`, quiet once they have used it |
| `desk-passwd.desktop` | The same thing as an app-grid entry, for people who never open a terminal |

### `docs/`

| Doc | Read it if |
|---|---|
| [remote-desktop-on-wayland.md](docs/remote-desktop-on-wayland.md) | You are setting up RDP into GNOME. **Start here** — it will save you a day |
| [golden-images.md](docs/golden-images.md) | You want one machine to become many, without shipping your credentials to all of them |
| [shrinking-a-disk.md](docs/shrinking-a-disk.md) | You need a disk smaller, and would rather not destroy the partition table |
| [conventions.md](docs/conventions.md) | You want to know why the defaults are what they are |
| [gotchas.md](docs/gotchas.md) | Something small is behaving strangely |

## Assumptions

- **Ubuntu 24.04 or 26.04** for `ubuntu/`. No hypervisor assumed — bare metal is fine
- **Proxmox VE 8 or 9** for `proxmox/`, which is the only half that assumes anything
- Where guests are VMs, they run `qemu-guest-agent` — several things simply do not work without it
- Remote desktop means **GNOME Remote Desktop over RDP**, not xrdp or VNC
- LVM-thin storage for the shrink script; it refuses layouts it does not recognise

## Design rules

- **Idempotent.** Re-running updates rather than duplicating, because you will run these again
  after a pull.
- **Verify, don't claim.** Scripts check the socket, re-parse the config they wrote, and print
  what actually resolved rather than reporting success.
- **Refuse rather than guess.** An occupied VMID, a running VM, a layout that isn't ext4, a
  colour Starship doesn't know — stop and say why.
- **The harmless thing is the default.** Bare invocation reports; acting takes a flag.
- **Say what a step costs.** Where a command needs a reboot, a full logout, or takes the guest
  down, it says so at the point you run it.

## Contributing

Bug reports welcome, especially "this trap cost me hours" ones — those are what `docs/` is for.

MIT licensed.
