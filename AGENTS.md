# AGENTS.md

The brief for this repo. Read it before changing anything here.

## What this is

Plain bash for setting up Ubuntu machines and, on Proxmox, turning one into many. Two halves,
useful separately:

- **`ubuntu/`** — runs on the machine itself. Knows nothing about Proxmox and must stay that
  way: it has to work on a laptop, a container and bare metal.
- **`proxmox/`** — runs on the hypervisor as root. The only half allowed to assume `qm`,
  `vzdump`, `pvesm` or LVM.

`docs/` is not an afterthought. Every trap in there cost hours to find, and it is the reason
someone else will use this repo.

## Layout

```
ubuntu/     guest-setup.sh  desk-golden-prep.sh  desk-claim.sh
            desk-passwd.sh  desk-hint.sh  desk-passwd.desktop
proxmox/    desk-image.sh  desk-instance.sh  desk-shrink.sh  pve-halt.sh
docs/       remote-desktop-on-wayland.md  golden-images.md  shrinking-a-disk.md
            conventions.md  gotchas.md
bootstrap.sh   one-command entry point: fetches this repo as a tarball, runs guest-setup.sh
```

`bootstrap.sh` is fetched by `curl` on machines with **no credentials of any kind**. That is
the whole reason this repo is public — never add a step to it that needs a login.

## This repo is public. Keep it generic.

It was split out of a private homelab repo. The test for anything new:

- Would it make sense to a stranger with a different network? → belongs here.
- Does it encode specific addresses, hostnames, MACs, storage IDs, VMIDs, people's names or
  one site's history? → belongs in the private repo, not here.

Examples of what that rules out: `192.168.50.x`, `trans1T_lvm`, real colleague names, a fixed
VMID as anything other than an illustration in a comment.

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
