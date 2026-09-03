# Conventions these scripts assume

None of this is mandatory. It is written down because the scripts default to it, and because
each one exists for a reason that is easy to forget.

## Prompt colour tells you which machine you are on

```bash
ubuntu/guest-setup.sh --colour red      # whatever you decide red means
ubuntu/guest-setup.sh --colour orange
ubuntu/guest-setup.sh --colour teal
ubuntu/guest-setup.sh --colours         # every name it knows
```

Starship itself knows eight colour names and a `bright-` variant of each. Sixteen is not many
once you have a dozen machines, and those eight are the ones every other tool uses too, so they
read as "a terminal colour" rather than "this machine". So `guest-setup.sh` carries its own
names for hex values on top: orange, amber, gold, lime, mint, teal, sky, azure, indigo, violet,
lavender, magenta, pink, coral, salmon, crimson, brown, slate, grey. `--colours` lists them
with the hex each one resolves to.

They are picked to survive a real terminal, not to look good on a colour wheel: nothing dark
enough to vanish on a dark background, nothing pale enough to vanish on a light one, and
neighbours far apart in hue, because the job is telling two machines apart at a glance.

The same names work on a Mac: `macos/mac-setup.sh --colour orange` recolours the prompt you
already have, without replacing your theme. Both halves read `lib/colours.sh`, which carries a
hex for starship and a 256-colour index for zsh, so one word means one colour everywhere.

A hex like `'#ff8800'` or a 0-255 index like `208` still works. **Quote a hex**, or the shell
takes it as the start of a comment and the flag silently loses its argument.

The point is not decoration. When you have six terminals open and one of them is the
hypervisor, the prompt is what stops you running a destructive command in the wrong place.

**What each colour means is yours, and this repo deliberately does not say.** Machine type
(host / container / VM), owner, environment, and customer are all reasonable axes, and which
one earns its keep depends on how you actually get confused. Two things matter more than the
mapping:

- **Pick one axis and keep it.** A colour that means two things means nothing.
- **Spend your loudest colour where a mistake is unrecoverable**, which is usually the
  hypervisor and whatever host carries your only way back in. Colouring six disposable VMs
  and leaving those two plain is the common mistake, and it inverts the whole point.

An earlier version of this file prescribed red/cyan/green for host/LXC/VM, and the script
printed that on every run. That is one person's preference and it does not belong in a
generic repo.

**Valid colours:** `black red green yellow blue purple cyan white`, their `bright-` variants,
a hex like `"#ff8800"`, or a 0–255 index. Starship calls magenta **`purple`** — an unknown name
is not an error, it silently renders unstyled, so a typo looks exactly like the flag being
broken. The script validates the name for that reason.

## A label instead of the hostname

```bash
ubuntu/guest-setup.sh --label BUILD-BOX-01
```

Display only — the real hostname is untouched, so SSH, certificates and the guest agent are
unaffected. Useful when the hostname was chosen for DNS rather than for reading at a glance.

## Plain-text symbols, not a Nerd Font

The script uses Starship's `plain-text-symbols` preset deliberately. The default preset needs a
Nerd Font installed on **whichever machine draws the text** — your laptop over SSH, the guest
over RDP. Across several machines and colleagues on unknown setups, that is a per-device
install nobody performs. Plain text renders identically everywhere and keeps branch, dirty
state and language versions; it loses only decorative icons.

## Per-machine aliases and secrets live outside the shell config

```
~/.a_aliases   # per-machine aliases: cd_w, cd_p, cd_g, whatever
~/.a_secs      # exported secrets, mode 0600
```

Both sourced from `~/.zshrc` only if present. The point is that the shell config stays
**identical on every machine** and only these two files differ — so the setup script never
needs to know anything machine-specific.

`~/.a_secs` is purged and swept for during sysprep, because a secrets file is exactly the kind
of thing that rides into a clone. See [golden-images.md](golden-images.md).

## Naming: role, then owner

```
<prefix>-<role>-<owner>     e.g.  wdesk-alice, wsrv-build
```

Infrastructure keeps the node's name (`node1`, `node1-proxy`) because it cannot move. Guests
keep machine names, because they can migrate to another node one day and a name containing
`node1` becomes a lie the day they do.

For SSH aliases, let the **prefix say how you arrive**, not what the machine runs:

| Alias | Means |
|---|---|
| `t-thing` | reachable from anywhere (direct over a VPN, or through a jump — your config hides which) |
| `l-thing` | local network only, direct |

Names reached **through a jump** must resolve **on the jump host**; names reached **directly**
must resolve on your laptop. Getting that backwards produces
`channel 0: open failed: connect failed: Name or service not known`, which reads like a
network fault and is a DNS one.
