#!/usr/bin/env bash
#
# mac-setup.sh — the macOS half of the standard build.
#
#   ./mac-setup.sh --colour orange     # colour this machine's prompt
#   ./mac-setup.sh --colour orange --brew   # ...and install the base packages
#   ./mac-setup.sh --label BUILD-BOX   # show a name instead of the hostname
#   ./mac-setup.sh --colours           # list every colour name
#   ./mac-setup.sh --check             # say what it would do, change nothing
#
# WHY THIS EXISTS, AND WHAT IT DELIBERATELY DOES NOT DO
#
# The point is one command and one vocabulary everywhere: `--colour orange` means the same
# orange on a Mac as on an Ubuntu guest. It does NOT try to make a Mac look like a guest.
# Your prompt stays whatever it already is — oh-my-zsh, pure, powerlevel10k, hand-rolled —
# and only its colour changes. A tool that replaces someone's prompt to standardise it is
# not saving them from remembering things, it is taking their setup away.
#
# So: no starship, no theme, no shell change. Compare ubuntu/guest-setup.sh, which DOES set
# all of that, because a fresh guest has nothing to preserve.
#
# Idempotent: re-run after a pull and it updates in place rather than stacking another line.
#
set -euo pipefail

# $0 is the SYMLINK when run as an installed command (/usr/local/bin/guest-setup), so a bare
# dirname gives /usr/local and ../lib misses by a mile. Walk the links to the real file first.
# readlink -f would do it on Linux but not on macOS, and lib/ is shared with the macOS half.
resolve_self() {
  local self="$1" target
  while [ -L "$self" ]; do
    target="$(readlink "$self")"
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
  done
  cd "$(dirname "$self")" && pwd
}
HERE="$(resolve_self "$0")"
[ -f "$HERE/../lib/colours.sh" ] || { echo "ERROR: missing $HERE/../lib/colours.sh — this script needs the repo around it, not a lone copy." >&2; exit 1; }
. "$HERE/../lib/colours.sh"

COLOUR=""
LABEL=""
BREW=0
CHECK=0
LIST=0
ZSHRC="$HOME/.zshrc"
MARK="# fleetkit prompt colour"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
note() { echo "   $*"; }
run()  { if [ "$CHECK" -eq 1 ]; then echo "   would run: $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --colour|--color) COLOUR="${2:?}"; shift 2 ;;
    --label)          LABEL="${2:?}"; shift 2 ;;
    --brew)           BREW=1; shift ;;
    --check)          CHECK=1; shift ;;
    --colours|--colors|--list-colours) LIST=1; shift ;;
    -h|--help)        sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$LIST" -eq 1 ] && { list_colours; exit 0; }
[ "$(uname)" = "Darwin" ] || die "this is the macOS half — on Ubuntu use ubuntu/guest-setup.sh"
[ -n "$COLOUR" ] || [ "$BREW" -eq 1 ] || die "nothing to do. Pass --colour <name>, --brew, or both.
       Run: $0 --colours     to see the names."

if [ -n "$COLOUR" ]; then
  valid_colour "$COLOUR" || die "'$COLOUR' is not a colour this script knows.
       Run: $0 --colours     to see every name, including orange, teal and coral."
  resolve_colour "$COLOUR"
  [ -n "$COLOUR_INDEX" ] || die "'$COLOUR' has no zsh form. zsh %F{} takes a name or a 0-255
       index, not a bare hex on every terminal. Use a name from --colours, or an index."
fi

note "on $(scutil --get ComputerName 2>/dev/null || hostname -s) — macOS $(sw_vers -productVersion)"

# ---------------------------------------------------------------- packages
if [ "$BREW" -eq 1 ]; then
  step "base packages"
  command -v brew >/dev/null || die "no brew. Install it first: https://brew.sh"
  # The macOS equivalents of ubuntu/guest-setup.sh's base set. Two are deliberately absent:
  # qemu-guest-agent (there is no hypervisor under a Mac) and keychain (macOS has its own
  # Keychain, which is what --apple-use-keychain talks to).
  for pkg in vim git curl wget gnupg jq htop tree unzip ripgrep fd bat fzf; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      note "$pkg already installed"
    else
      run brew install "$pkg"
    fi
  done
  note "fd and bat keep their real names here — the fdfind/batcat aliases are Ubuntu's problem"
fi

# ---------------------------------------------------------------- aliases
step "per-machine aliases"
if [ -f "$HOME/.a_aliases" ]; then
  note "~/.a_aliases exists — never overwritten, it is yours"
elif [ "$CHECK" -eq 1 ]; then
  note "would create ~/.a_aliases"
else
  cat > "$HOME/.a_aliases" <<'ALIASES'
# Per-machine aliases. fleetkit creates this once and never overwrites it.
# Point these at wherever the directories actually live on THIS machine.

alias cd_w='cd ~/Work'          # work
alias cd_p='cd ~/Personal'      # personal
alias cd_g='cd ~/Global'        # global / shared
ALIASES
  note "created ~/.a_aliases (edit the paths)"
fi
if grep -q '\.a_aliases' "$ZSHRC" 2>/dev/null; then
  note "~/.zshrc already sources it"
else
  run_append() { printf '\n[ -f ~/.a_aliases ] && source ~/.a_aliases\n' >> "$ZSHRC"; }
  if [ "$CHECK" -eq 1 ]; then note "would add the source line to ~/.zshrc"; else run_append; note "added the source line to ~/.zshrc"; fi
fi

# ---------------------------------------------------------------- prompt colour
if [ -n "$COLOUR" ]; then
  step "prompt colour"
  [ -f "$ZSHRC" ] || die "no $ZSHRC to edit"

  # If a PROMPT line is already there, keep the label text it uses. Someone wrote "wego-mini"
  # rather than the full hostname on purpose, and silently expanding it on the first run would
  # be exactly the kind of surprise this script is supposed to avoid. --label still overrides.
  EXISTING_LABEL="$(grep -E '^PROMPT=.*\$PROMPT' "$ZSHRC" 2>/dev/null | head -1 \
                    | sed -n 's/.*%F{[^}]*}\(.*\)%f.*/\1/p')"
  MACHINE="${LABEL:-${EXISTING_LABEL:-$(scutil --get ComputerName 2>/dev/null || hostname -s)}}"
  [ -n "$LABEL" ] || [ -z "$EXISTING_LABEL" ] || note "keeping the label already in your .zshrc: $EXISTING_LABEL"
  # %B bold, italic on/off around the name, %F{n}/%f colour on/off. Prepended to whatever
  # $PROMPT already is, so the existing theme is preserved and only gains a coloured label.
  LINE="PROMPT=\"%B%{\$(printf '\\033[3m')%}%F{$COLOUR_INDEX}$MACHINE%f%{\$(printf '\\033[23m')%}%b \$PROMPT\"  $MARK"

  if grep -q "$MARK" "$ZSHRC"; then
    ACTION="update the line fleetkit already added"
  elif grep -qE '^PROMPT=.*\$PROMPT' "$ZSHRC"; then
    ACTION="ADOPT the PROMPT line already in your .zshrc, and mark it as fleetkit's"
  else
    ACTION="append a new PROMPT line"
  fi
  note "$ACTION"
  note "colour: ${COLOUR_NAME:-$COLOUR} -> zsh %F{$COLOUR_INDEX}${COLOUR_HEX:+, $COLOUR_HEX on starship machines}"
  note "label:  $MACHINE"

  if [ "$CHECK" -eq 1 ]; then
    note "would write: $LINE"
  else
    cp "$ZSHRC" "$ZSHRC.bak.$(date +%s)"
    TMP="$(mktemp)"
    # Replace a line we own, or an unmarked PROMPT=...$PROMPT line (adopting it once), or
    # append. Only ONE line can match, so a re-run never stacks a second copy.
    if grep -q "$MARK" "$ZSHRC"; then
      awk -v mark="$MARK" -v line="$LINE" '{ if (index($0, mark)) print line; else print }' "$ZSHRC" > "$TMP"
    elif grep -qE '^PROMPT=.*\$PROMPT' "$ZSHRC"; then
      awk -v line="$LINE" 'BEGIN{done=0}
        /^PROMPT=.*\$PROMPT/ && !done { print line; done=1; next } { print }' "$ZSHRC" > "$TMP"
    else
      cp "$ZSHRC" "$TMP"; printf '\n%s\n' "$LINE" >> "$TMP"
    fi
    mv "$TMP" "$ZSHRC"
    note "written — backup alongside. Run: exec zsh"
  fi
fi

# ---------------------------------------------------------------- ssh agent, reported only
step "ssh agent"
if grep -qE 'UseKeychain|AddKeysToAgent' "$HOME/.ssh/config" 2>/dev/null; then
  note "~/.ssh/config already uses the Keychain, so a passphrase is asked once"
else
  note "~/.ssh/config has no UseKeychain / AddKeysToAgent."
  note "Without them a passphrase-protected key is re-prompted constantly. Add per host:"
  note "    UseKeychain yes"
  note "    AddKeysToAgent yes"
  note "Then once per key:  ssh-add --apple-use-keychain ~/.ssh/<key>"
  note "Reported, not changed — SSH config and keys are yours."
fi

echo
echo "Done."
