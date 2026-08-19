# fleetkit

**Set up one Ubuntu machine properly. Then make as many copies as you need.**

Plain bash scripts. No framework, no config files, nothing to learn.

## The problem

Setting up a Linux desktop someone can actually use takes a day — most of it spent finding out
that remote desktop no longer works the old way, and that the fix is three non-obvious steps.

Doing that for five colleagues takes five days.

This makes it one day, then about ten minutes per person.

## Start here

On a fresh Ubuntu machine — laptop, server, VM, anything:

```bash
curl -fsSL https://raw.githubusercontent.com/mahsanamin/fleetkit/main/bootstrap.sh \
  | bash -s -- --docker
```

One command, no login, no GitHub account. You get: sensible packages, zsh with a prompt that
tells you which machine you're on, Docker, and remote desktop that works.

Want to see what it would do first? Add `--check` and it changes nothing.

## Get the commands

`bootstrap.sh` sets a machine up. To also get fleetkit's commands (`desk-claim`, `desk-passwd`,
`desk-rdp-watchdog`, and on a Proxmox host `desk-image` and friends) installed properly:

```bash
sudo /opt/fleetkit/fleet-install.sh --check     # what it would do, changes nothing
sudo /opt/fleetkit/fleet-install.sh --apply
```

It clones the repo to `/opt/fleetkit` if it isn't there, links the commands to it, and installs
the RDP watchdog's timer where there's a remote desktop to watch. On a Proxmox host it also
installs the `proxmox/` commands — detected by whether `qm` exists, not configured.

Because the commands are **symlinks into the repo**, updating everything is one pull:

```bash
sudo fleet-install --update
```

And you can always tell what a machine is running:

```bash
readlink -f $(command -v desk-claim)
```

## The two halves

You can use either one on its own.

| Folder | Use it to | Needs |
|---|---|---|
| **[`ubuntu/`](ubuntu/)** | Set up a machine | Any Ubuntu box. No hypervisor |
| **[`proxmox/`](proxmox/)** | Turn that machine into many | A Proxmox host |

If you only ever set up one machine, `ubuntu/` is the whole point. Ignore the rest.

### Making copies (the `proxmox/` half)

```bash
# 1. image the machine that already works
proxmox/desk-image.sh --vmid 150

# 2. make a copy for someone
proxmox/desk-instance.sh --person ali --vmid 201 --template 200 --start
```

Then inside the copy:

```bash
# 3. give it its own name, certificate and password
sudo desk-claim ali
```

That's a new machine for a new person. Everyone logs in as the same `ubuntu` account with their
own password — the wall between people is the machine, not the username.

## The docs are half the value

Every trap in here cost hours to find.

| Read this | If |
|---|---|
| [remote-desktop-on-wayland.md](docs/remote-desktop-on-wayland.md) | You want RDP into a Linux desktop. **Start here — it saves a day** |
| [golden-images.md](docs/golden-images.md) | You want one machine to become many, without copying your passwords into all of them |
| [shrinking-a-disk.md](docs/shrinking-a-disk.md) | You need a disk smaller and would rather not destroy the partition table |
| [conventions.md](docs/conventions.md) | You want to know why the defaults are what they are |
| [gotchas.md](docs/gotchas.md) | Something small is behaving strangely |

## Good to know

- **Nothing runs by accident.** Bare commands report what they'd do; changing things takes a flag.
- **Safe to re-run.** Every script updates instead of duplicating.
- **It refuses instead of guessing.** Wrong machine, occupied slot, unfamiliar disk layout — it
  stops and tells you why.

Tested on Ubuntu 24.04 and 26.04, and Proxmox VE 8 and 9. Remote desktop means GNOME Remote
Desktop over RDP — not xrdp, which no longer works on modern Ubuntu ([here's why](docs/remote-desktop-on-wayland.md)).

## Contributing

Bug reports welcome, especially "this cost me hours" ones. That's what `docs/` is for.

MIT licensed.
