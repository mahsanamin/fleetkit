# AGENTS.md

The brief for this repo. Read it before changing anything here.

## What this is

Plain bash for setting up Ubuntu machines and, on Proxmox, turning one into many. Two halves,
useful separately:

- **`ubuntu/`** — runs on the machine itself. Knows nothing about Proxmox and must stay that
  way: it has to work on a laptop, a container and bare metal.
- **`macos/`** — runs on a Mac. Deliberately small: a Mac already has a shell someone set up
  and cares about, so this half colours and extends it rather than replacing it. Nothing in
  `ubuntu/` runs here, every script there calls `apt-get`, `systemctl` or `grdctl`.
- **`proxmox/`** — runs on the hypervisor as root. The only half allowed to assume `qm`,
  `vzdump`, `pvesm` or LVM.
- **`lib/`** — sourced, never run. Only for things two halves must agree on, today the colour
  palette. If only one half needs it, it belongs in that half.

`docs/` is not an afterthought. Every trap in there cost hours to find, and it is the reason
someone else will use this repo.

## Layout

```
ubuntu/     guest-setup.sh  desk-golden-prep.sh  desk-claim.sh
            desk-passwd.sh  desk-hint.sh  desk-passwd.desktop
            desk-rdp-watchdog.sh  desk-crash-trap.sh
macos/      mac-setup.sh
lib/        colours.sh        <- sourced by both, so a colour name means one thing
proxmox/    desk-image.sh  desk-instance.sh  desk-shrink.sh  pve-halt.sh
            fleet-memlog.py   <- the one Python script here, see below
docs/       remote-desktop-on-wayland.md  diagnosing-a-frozen-guest.md
            golden-images.md  shrinking-a-disk.md  sizing-guest-memory.md
            conventions.md  gotchas.md
fleet.sh         the index: what commands THIS machine has, and what each one does
bootstrap.sh     one-command entry point: fetches this repo as a tarball, runs guest-setup.sh
fleet-install.sh installs THIS REPO as system commands, on a guest or a hypervisor
```

`bootstrap.sh` is fetched by `curl` on machines with **no credentials of any kind**. That is
the whole reason this repo is public — never add a step to it that needs a login.

## One script is Python, and why

Everything here is bash except **`proxmox/fleet-memlog.py`**. It reads `/proc/meminfo` back out
of every guest through `qm guest exec`, which returns **JSON**, and it computes percentiles over
a CSV history. Parsing JSON in bash without `jq` (not installed on a stock Proxmox host) is
fragile in exactly the way that produces wrong numbers quietly, and wrong numbers are the whole
failure mode this script exists to avoid. `python3` is present on a Proxmox host.

If you add another script, default to bash. Reach for Python only when the input is structured
and getting it wrong would be silent.

## This repo is public. Keep it generic.

It was split out of a private homelab repo. The test for anything new:

- Would it make sense to a stranger with a different network? → belongs here.
- Does it encode specific addresses, hostnames, MACs, storage IDs, VMIDs, people's names or
  one site's history? → belongs in the private repo, not here.

Examples of what that rules out: `192.168.50.x`, `trans1T_lvm`, real colleague names, a fixed
VMID as anything other than an illustration in a comment.

## The repo IS the install

`fleet-install.sh` puts the repo at **`/opt/fleetkit`** and links the commands to it:

```
/usr/local/bin/desk-claim -> /opt/fleetkit/ubuntu/desk-claim.sh
```

**Symlinks, never copies.** A pull then updates every command at once, and
`readlink -f $(command -v desk-claim)` answers "which version is this machine running" — the
question a scp'd copy can never answer. A broken symlink is loud; a stale copy is silent.

So: **if you add a script people run as a command, add it to `fleet-install.sh`.** A script the
README calls by bare name, with nothing installing it, is a promise the repo does not keep.

**Keep line 3 of every script in the form `# name.sh — what it does`.** `fleet` builds its
index by reading that line out of each installed command, so a new script lists itself and
there is no second list to fall out of step. Change the shape of that line and the command
appears with a blank description.

`/opt` and not a home directory, because `desk-golden-prep` deletes the seed account *and its
home* — a checkout inside it is destroyed and no clone inherits fleetkit.

## Rules for changing a script

- **Idempotent.** Re-running updates rather than duplicating. People will re-run these after a
  pull.
- **The harmless thing is the default.** A bare invocation reports; acting takes a flag.
  `pve-halt.sh` is the cautionary tale: it once stopped every guest on a bare run, which
  severed the only way back into the host.
- **Refuse rather than guess.** Occupied VMID, running VM, a disk layout that isn't recognised,
  a colour Starship doesn't know — stop and say why.
- **Verify, don't claim.** Check the socket, re-read the config you wrote, print what actually
  resolved. "Reports healthy while listening to nothing" is a real failure mode here.
- **Say what a step costs** at the point it runs — reboot, full logout, guest downtime.
- **Never set or change a password without being asked to.** Password steps are interactive and
  belong to the human running the script.

## Before you commit

```bash
bash -n <script>              # every script you touched
<script> --check              # where it has a dry run, actually run it
```

Also check nothing points at a doc that doesn't exist:

```bash
grep -rno 'docs/[a-z0-9-]*\.md' --include='*.sh' --include='*.md' . | sort -u \
  | while IFS=: read -r f n ref; do [ -f "$ref" ] || echo "MISSING $ref (in $f:$n)"; done
```

Do not report a change as working unless you ran it. If you could not test it, say so.

## Two things that bite

**A template is a snapshot of these scripts, not a link to them.** Edit a script after sealing
a golden image and every existing clone still carries the old copy. Either re-seal, or push the
new copy into the running machine on purpose.

**Shell quoting corrupts scripts that write scripts.** Pass values through the environment and
keep the inner expression single-quoted, rather than escaping backticks through two shells.

## Commits

Plain, human commit messages that say what changed and why. **No `Co-Authored-By` trailer and
no "generated with" line.**
