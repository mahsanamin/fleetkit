#!/usr/bin/env bash
#
# guest-setup.sh — a standard build for a new Ubuntu guest.
#
# Runs INSIDE the guest, as your normal user (it uses sudo itself).
#
#   ./guest-setup.sh                          # base + shell, green prompt (VM convention)
#   ./guest-setup.sh --colour cyan            # any colour you like, see --help
#   ./guest-setup.sh --label BUILD-BOX-01     # show a name instead of the hostname
#   ./guest-setup.sh --docker                 # ...and Docker
#   ./guest-setup.sh --docker --mise          # ...and the runtime manager
#   ./guest-setup.sh --check                  # say what it would do, change nothing
#
#   sudo ./guest-setup.sh --for-user ubuntu   # provision ANOTHER account, as root
#
# --for-user exists for unattended golden builds: a hypervisor's guest agent runs as root, so
# there is no interactive user and no way to answer a sudo prompt. It provisions that user's
# shell and home rather than root's.
#
# Idempotent: re-run it after a pull, it updates and skips what is already there.
#
# What "base" means, and why:
#   vim               Ubuntu ships vim-tiny in COMPATIBLE mode, where arrow keys insert
#                     ABCD instead of moving. Full vim loads defaults.vim and behaves.
#   qemu-guest-agent  without it the host cannot report the guest's IP or shut it down
#                     cleanly, and `qm reboot` fails outright. Missing it cost real time.
#   fd-find / bat     installed as `fdfind` and `batcat` on Ubuntu; aliased below.
#   keychain          Linux has no macOS Keychain, so a passphrase-protected SSH key is
#                     re-prompted on EVERY git pull. keychain keeps one agent alive across
#                     logins: unlock once per boot, not once per command.
#
set -euo pipefail

COLOUR=green
LABEL=""
FOR_USER=""
DOCKER=0
MISE=0
CHECK=0

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
note() { echo "   $*"; }
run()  { if [ "$CHECK" -eq 1 ]; then echo "   would: $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --colour|--color) COLOUR="${2:?}"; shift 2 ;;
    --label) LABEL="${2:?}"; shift 2 ;;
    --for-user) FOR_USER="${2:?}"; shift 2 ;;
    --docker) DOCKER=1; shift ;;
    --mise)   MISE=1; shift ;;
    --check)  CHECK=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Starship's palette. An unknown name is not an error to starship — it silently renders
# unstyled, which looks like the colour flag did nothing. 'magenta' is the classic trap:
# starship calls it 'purple'.
valid_colour() {
  case "$1" in
    black|red|green|yellow|blue|purple|cyan|white) return 0 ;;
    bright-black|bright-red|bright-green|bright-yellow) return 0 ;;
    bright-blue|bright-purple|bright-cyan|bright-white) return 0 ;;
    '#'*) return 0 ;;              # hex
    [0-9]|[0-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) return 0 ;;   # 256-colour index
    *) return 1 ;;
  esac
}
for c in "$COLOUR"; do
  valid_colour "$c" || die "'$c' is not a starship colour. Use one of:
       black red green yellow blue purple cyan white, a bright- variant,
       a hex like '#ff8800', or a 0-255 index. (starship calls magenta 'purple')"
done

# Normally you run this as yourself and it sudos. With --for-user, root provisions someone
# else's account — the unattended path, where there is nobody to answer a sudo prompt.
if [ -n "$FOR_USER" ]; then
  [ "$(id -u)" -eq 0 ] || die "--for-user requires root"
  id "$FOR_USER" >/dev/null 2>&1 || die "no such user: $FOR_USER"
  TUSER="$FOR_USER"; SUDO=""
else
  [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root — it sudos where needed.
       To provision another account non-interactively, use: sudo $0 --for-user <name>"
  TUSER="$(id -un)"; SUDO="sudo"
fi
THOME="$(getent passwd "$TUSER" | cut -d: -f6)"
[ -d "$THOME" ] || die "$TUSER has no home directory at $THOME"
command -v apt-get >/dev/null || die "not a Debian/Ubuntu system"
. /etc/os-release 2>/dev/null || true
note "on $(hostname) — ${PRETTY_NAME:-unknown release}"

# ---------------------------------------------------------------- base
step "base packages"
run $SUDO apt-get update -qq
run $SUDO apt-get install -y -qq \
  vim git curl wget ca-certificates gnupg \
  zsh htop jq unzip tree net-tools \
  ripgrep fd-find bat fzf keychain \
  qemu-guest-agent
if [ "$CHECK" -ne 1 ]; then
  $SUDO systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
  note "installed; guest agent enabled"
fi

# ---------------------------------------------------------------- shell
step "zsh + starship"
if command -v starship >/dev/null 2>&1; then
  note "starship already present: $(starship --version | head -1)"
elif [ "$CHECK" -eq 1 ]; then
  note "would install starship to /usr/local/bin"
else
  curl -fsSL https://starship.rs/install.sh | $SUDO sh -s -- -y >/dev/null
  note "starship $(starship --version | head -1)"
fi

if [ "$CHECK" -ne 1 ]; then
  mkdir -p "$THOME/.config"
  # plain-text-symbols, not the default: the default needs a Nerd Font on whichever machine
  # DRAWS the text — the Mac over SSH, the guest over RDP — and that is a per-device install
  # nobody does. Plain text keeps branch, dirty state and versions, loses only icons. (see docs/conventions.md)
  #
  # Only lay the preset down when there is no config yet. `starship preset -o` refuses to
  # overwrite, which aborted the whole script on a re-run, and forcing it would discard any
  # edits made since. The merge below runs either way, so the colour still updates.
  if [ ! -f "$THOME/.config/starship.toml" ]; then
    starship preset plain-text-symbols -o "$THOME/.config/starship.toml"
    note "wrote the plain-text-symbols preset"
  else
    note "keeping the existing starship.toml, updating colours only"
  fi

  python3 - "$THOME/.config/starship.toml" "$COLOUR" "$LABEL" <<'PYEOF'
import sys, pathlib, re

path, colour, label = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
lines = p.read_text().splitlines()

# The preset ships its own [hostname] table, so a prepended second one would be invalid
# TOML and starship would fall back to defaults. Merge into the existing tables instead:
# set our keys inside them, and create a table only when it is genuinely absent.
def set_in_table(lines, table, keys):
    try:
        i = lines.index(f"[{table}]")
    except ValueError:
        lines += ["", f"[{table}]"] + [f"{k} = {v}" for k, v in keys.items()]
        return lines
    j = i + 1
    while j < len(lines) and not lines[j].startswith("["):
        j += 1
    body = lines[i+1:j]
    for k, v in keys.items():
        body = [b for b in body if not re.match(rf"\s*{k}\s*=", b)]
        body.append(f"{k} = {v}")
    return lines[:i+1] + body + lines[j:]

# A label replaces the hostname text entirely — literal text in the format string. Useful
# when the real hostname is not what you want to read at a glance.
host_fmt = f'"[{label}]($style) "' if label else '"[@$hostname]($style) "'
lines = set_in_table(lines, "hostname", {
    "ssh_only": "false",
    "style":    f'"bold {colour}"',
    "format":   host_fmt,
})
# No username: you are always the same user on these boxes, so it is noise. The machine is
# what matters, and the label carries that.
lines = set_in_table(lines, "username", {"disabled": "true"})

# Path and branch share one colour, distinct from the machine colour, so the prompt reads as
# two things: WHERE you are, then WHAT you are looking at.
for table in ("directory", "git_branch", "git_status"):
    lines = set_in_table(lines, table, {"style": '"bold bright-blue"'})

# A top-level format must come before any table. Strip ONLY the top-level one — a blanket
# filter also eats the format= keys inside [hostname] and [username], which is how the first
# attempt silently produced a config with no formats at all.
first_table = next((n for n, l in enumerate(lines) if l.startswith("[")), len(lines))
head = [l for l in lines[:first_table] if not l.startswith("format =")]
lines = ['format = "$hostname$directory$git_branch$git_status$cmd_duration$character"'] + head + lines[first_table:]

p.write_text("\n".join(lines) + "\n")
print(f"   prompt: {colour}" + (f", shown as {label}" if label else ""))
PYEOF

  # Per-machine aliases and secrets, sourced if present. Kept OUT of .zshrc itself so the
  # shell config stays identical everywhere and only these two files differ per machine.
  if [ ! -f "$THOME/.a_aliases" ]; then
    cat > "$THOME/.a_aliases" <<'ALIASES'
# Per-machine aliases. This file is yours — guest-setup creates it once and never overwrites.
# Point these at wherever the directories actually live on THIS machine.

alias cd_w='cd ~/Work'          # work
alias cd_p='cd ~/Personal'      # personal
alias cd_g='cd ~/Global'        # global / shared
ALIASES
    note "created ~/.a_aliases (edit the paths)"
  else
    note "~/.a_aliases exists, left alone"
  fi

  if [ ! -f "$THOME/.a_secs" ]; then
    cat > "$THOME/.a_secs" <<'SECS'
# Secrets for this machine: export VAR=value, one per line.
# Never commit this file, and remember it travels into any image or clone of this machine —
# the golden's sysprep sweeps for it for that reason.
SECS
    chmod 600 "$THOME/.a_secs"
    note "created ~/.a_secs (mode 600)"
  else
    chmod 600 "$THOME/.a_secs"
    note "~/.a_secs exists, permissions enforced"
  fi

  ZRC="$THOME/.zshrc"; touch "$ZRC"
  add() { grep -qF "$1" "$ZRC" || printf '%s\n' "$1" >> "$ZRC"; }
  add 'eval "$(starship init zsh)"'
  add '[ -x "$HOME/.local/bin/mise" ] && eval "$($HOME/.local/bin/mise activate zsh)"'
  add '[ -f "$THOME/.a_aliases" ] && source "$THOME/.a_aliases"'
  add '[ -f "$THOME/.a_secs" ] && source "$THOME/.a_secs"'
  add 'alias fd=fdfind'
  add 'alias bat=batcat'
  # Unlock any SSH keys once per boot rather than once per git command. This has to decide at
  # RUNTIME, not now: a golden image has no keys yet, and a clone of it may gain them later.
  # Deciding here would bake "there are no keys" into every machine built from this one.
  if ! grep -q 'keychain --eval' "$ZRC"; then
    cat >> "$ZRC" <<'KEYCHAIN'

# Unlock SSH keys once per boot (keychain keeps one agent alive across logins).
if command -v keychain >/dev/null 2>&1; then
  _ak=()
  for _f in ~/.ssh/*github* ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
    [ -f "$_f" ] && [[ "$_f" != *.pub ]] && _ak+=("$_f")
  done
  (( ${#_ak} )) && eval "$(keychain --eval --quiet "${_ak[@]}")"
  unset _ak _f
fi
KEYCHAIN
    note "keychain wired into ~/.zshrc (resolves keys at login, not now)"
  else
    note "keychain already wired into ~/.zshrc"
  fi
  note "~/.zshrc updated"

  if [ "$(getent passwd "$TUSER" | cut -d: -f7)" = "/usr/bin/zsh" ]; then
    note "login shell already zsh"
  else
    $SUDO chsh -s /usr/bin/zsh "$TUSER"
    note "login shell set to zsh — applies at your NEXT login"
  fi
fi

# ---------------------------------------------------------------- docker
if [ "$DOCKER" -eq 1 ]; then
  step "docker"
  if command -v docker >/dev/null 2>&1; then
    note "already installed: $(docker --version)"
  elif [ "$CHECK" -eq 1 ]; then
    note "would add the docker repo and install docker-ce"
  else
    CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}"
    # Check the repo exists for this release BEFORE adding it — worth doing on a new Ubuntu.
    U=https://download.docker.com/linux/ubuntu
    curl -fsI "$U/dists/$CODENAME/Release" >/dev/null \
      || die "Docker publishes nothing for '$CODENAME' yet. Stop and check."
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL "$U/gpg" -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [signed-by=/etc/apt/keyrings/docker.asc] $U $CODENAME stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    $SUDO usermod -aG docker "$TUSER"
    note "installed: $(docker --version)"
    note "group 'docker' needs a FULL LOGOUT, not a reconnect, before it applies"
  fi
fi

# ---------------------------------------------------------------- mise
if [ "$MISE" -eq 1 ]; then
  step "mise"
  if [ -x "$THOME/.local/bin/mise" ]; then
    note "already installed: $("$THOME/.local/bin/mise" --version | head -1)"
  elif [ "$CHECK" -eq 1 ]; then
    note "would install mise into ~/.local/bin"
  else
    if [ -n "$SUDO" ]; then curl -fsSL https://mise.run | sh >/dev/null;
    else runuser -u "$TUSER" -- sh -c "curl -fsSL https://mise.run | sh" >/dev/null; fi
    note "installed: $("$THOME/.local/bin/mise" --version | head -1)"
    note "add runtimes yourself, e.g. mise use -g node@lts python@3.13"
  fi
fi

# ---------------------------------------------------------------- done
# Under --for-user everything above ran as root, so fix ownership of what landed in the home.
if [ -z "$SUDO" ]; then
  chown -R "$TUSER":"$TUSER" "$THOME/.zshrc" "$THOME/.config" "$THOME/.a_aliases" "$THOME/.a_secs" 2>/dev/null || true
  note "ownership of $THOME files set to $TUSER"
fi

cat <<NEXT

Done on $(hostname) for user $TUSER.

Log out and back in for the shell and any group changes. To try the prompt now:  zsh

The prompt is coloured so a glance tells you which machine you are on before you run
something you cannot undo. What each colour MEANS is yours to decide: by machine type, by
owner, by environment. Pick one axis and keep it, and give the machines where a mistake is
unrecoverable the colour you will not miss.
NEXT
