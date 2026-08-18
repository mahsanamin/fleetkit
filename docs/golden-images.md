# One machine → a golden image → many machines

The workflow these scripts implement. It exists because setting a desktop up by hand takes a
day, and doing it per colleague takes a day each.

```
your working machine  --image-->  a copy  --prep-->  template  --clone-->  instances
   (never templated)               (surgery here)                          (claim each)
```

## Never template the machine you use

Every identity change — hostname, machine-id, SSH host keys, deleting the original account —
happens on a **copy**, not on your daily driver. A copy is rebuildable in seconds; your daily
driver is not.

```bash
proxmox/desk-image.sh --vmid <live>            # vzdump, ~1 min, seconds of downtime
proxmox/desk-instance.sh --from-dump <file> --vmid 9000 --name golden
```

`--mode stop` is deliberate: a stopped guest removes every consistency question rather than
answering it. In practice the guest is down for **seconds**, not the length of the backup —
Proxmox stops it, starts a backup-only process against the frozen disk, and resumes it.

## Prepare the copy, in two phases

```bash
sudo ubuntu/desk-golden-prep.sh --seed <original-user>   # create the shared account, move the toolchain
# log out, reconnect AS the new account, then:
sudo ubuntu/desk-golden-prep.sh --finish                 # delete the original, sysprep
```

Two phases because you cannot delete the account you are logged in as. Phase 1 **copies** the
original's toolchain rather than reinstalling it — the runtimes are already on the disk, so a
local copy takes seconds where a fresh install re-downloads gigabytes.

### One shared login account, not one per person

Every instance uses the same account (default `ubuntu`), set up once here. The isolation
boundary is the **machine**, not the username: one person per instance, each with their own
password.

This also removes the hardest problem in the whole exercise. A *new* user inherits nothing
from the original's home — no runtimes, no dotfiles — so per-person accounts mean provisioning
each one. Inherit the account and the toolchain comes with it.

## Credentials travel into every copy. All of them.

The lesson that matters most here. A cloned home directory carries:

| What | Why it is dangerous |
|---|---|
| `~/.local/share/keyrings/` | The GNOME login keyring, **encrypted with the original owner's password**. On a clone, their password unlocks it — and everything in it |
| `~/.config/gh`, `~/.ssh`, `~/.aws` | Tokens and keys with no passphrase |
| Browser profiles | A logged-in session is a credential |
| Your own secrets file | Whatever you keep exported in the shell |
| GRD credentials + `/etc/shadow` | The original owner's password, recoverable by anyone with root on their own instance — which every user has |

`--finish` purges and then **sweeps** for these, printing anything it finds. The sweep exists
because "I'll remember to check" does not survive a 1am build.

> Found the hard way: Chrome on a colleague's clone asked for a keyring password, and the
> **original owner's** old password was the one that opened it.

The cheapest moment to take an image is **before** you sign into anything on the source.

## Sysprep: leave machine-id EMPTY, not regenerated

`/etc/machine-id` is derived from the VM's SMBIOS UUID, which the hypervisor makes unique per
VM. So:

- A file **with a value** is copied verbatim to every clone — they all share an identity, and
  DHCP fights over one lease.
- An **empty** file makes each clone derive its own on first boot. No per-clone work.

Also verify your hypervisor gives clones a fresh SMBIOS UUID:

```bash
qm config <template> | grep smbios; qm config <clone> | grep smbios
```

## SSH host keys need a first-boot unit

Sysprep removes `/etc/ssh/ssh_host_*`, and on a non-cloud-init image **nothing regenerates
them** — Ubuntu creates host keys at package-install time. So `sshd` refuses to start and the
clone is only reachable through the console. `--finish` installs a one-shot unit that runs
`ssh-keygen -A` when the keys are missing.

## Then each instance is two commands

```bash
qm clone <template> <vmid> --name <name> --full --storage <storage>
qm start <vmid>
# in the guest:
sudo ubuntu/desk-claim.sh <person>
```

`desk-claim` sets the hostname, regenerates the RDP certificate with the matching CN, resets
machine-id and host keys if needed, and sets the password on **both** the Unix account and the
remote-desktop credentials. Re-running it is also how you **rename** a machine later, which
matters because a rename without re-setting the GRD credentials breaks remote desktop.

Put `/etc/desk-no-claim` on any machine that must never be claimed — the script refuses when
it sees that file.
