#!/usr/bin/env bash
#
# fleet-install.sh — install fleetkit itself, system-wide, as commands.
#
#   ./fleet-install.sh                   # report what it would do, change nothing (no sudo)
#   ./fleet-install.sh --check           # the same, explicitly
#   sudo ./fleet-install.sh --apply      # install
#   sudo ./fleet-install.sh --update     # git pull, then re-apply
#   sudo ./fleet-install.sh --uninstall  # remove the commands, keep the repo
#
# WHY THIS EXISTS
#
# The README tells you to run `sudo desk-claim ali`, as if it were a command. Until this
# script, nothing reliably made it one: it only appeared because desk-golden-prep copied it out
# of /tmp. So the honest answer to "which version of desk-claim is this machine running" was
# "whatever was scp'd to it, some time ago". That is how copies drift apart.
#
# THE REPO IS THE INSTALL. The commands are SYMLINKS into $REPO, not copies:
#
#   /usr/local/bin/desk-claim -> /opt/fleetkit/ubuntu/desk-claim.sh
#
# so `git pull` updates every command at once, and `readlink -f $(command -v desk-claim)`
# answers the provenance question. The cost is that removing $REPO breaks the commands, which
# is the right trade: a broken symlink is loud, while a stale copy is silent.
#
# WHY /opt AND NOT A HOME DIRECTORY
#
# desk-golden-prep DELETES the seed account and its home — that is the step keeping one
# person's data out of everyone else's machine. A checkout inside that home is destroyed with
# it, and clones inherit no fleetkit at all. /opt survives, so /opt is canonical. Working from
# a checkout in your home is fine; this script still installs from /opt.
#
# Both halves, detected rather than configured: the ubuntu/ commands always, and the proxmox/
# ones only where `qm` exists. The scripts keep fleetkit's separation — ubuntu/ still knows
# nothing about Proxmox. Only this installer looks at both.
#
set -euo pipefail

REPO="${FLEET_DEST:-/opt/fleetkit}"
URL="${FLEET_URL:-https://github.com/mahsanamin/fleetkit.git}"
BIN=/usr/local/bin
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$REPO"   # where files are READ for planning; links always point at $REPO

# command name -> path inside the repo
GUEST_CMDS="
desk-claim:ubuntu/desk-claim.sh
desk-passwd:ubuntu/desk-passwd.sh
desk-golden-prep:ubuntu/desk-golden-prep.sh
desk-rdp-watchdog:ubuntu/desk-rdp-watchdog.sh
desk-crash-trap:ubuntu/desk-crash-trap.sh
fleet-update:fleet-install.sh
guest-setup:ubuntu/guest-setup.sh
fleet-install:fleet-install.sh
"
HOST_CMDS="
desk-image:proxmox/desk-image.sh
desk-instance:proxmox/desk-instance.sh
desk-shrink:proxmox/desk-shrink.sh
pve-halt:proxmox/pve-halt.sh
"
# assets that are not commands: name -> repo path : destination
ASSETS="
desk-hint.sh:ubuntu/desk-hint.sh:/etc/profile.d/desk-hint.sh
desk-passwd.desktop:ubuntu/desk-passwd.desktop:/usr/share/applications/desk-passwd.desktop
"

# Invoked as `fleet-update`, act like --update. One script, two names, so the thing you run
# weekly is one word you can remember rather than a flag you have to look up.
case "$(basename "$0")" in
  fleet-update) MODE=update ;;
  *)            MODE=check ;;
esac
[ $# -eq 0 ] && [ "$MODE" = update ] && set -- --update

case "${1:-}" in
  "")          : ;;
  --check)     MODE=check ;;
  --apply)     MODE=apply ;;
  --update)    MODE=update ;;
  --uninstall) MODE=uninstall ;;
  *) echo "ERROR: unknown option '$1' — use --check, --apply, --update or --uninstall" >&2; exit 1 ;;
esac

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
note() { echo "   $*"; }

# A dry run changes nothing, so it does not need root — and being able to run --check without
# sudo is what makes it worth running before you commit to anything.
case "$MODE" in
  apply|update|uninstall) [ "$(id -u)" -eq 0 ] || die "$MODE needs root — re-run with sudo" ;;
esac

is_host() { command -v qm >/dev/null 2>&1; }
acting()  { [ "$MODE" = apply ] || [ "$MODE" = update ]; }

# --- 1. the repo ------------------------------------------------------------------------
ensure_repo() {
  step "repo at $REPO"

  if [ -d "$REPO/.git" ]; then
    if [ "$MODE" = update ]; then
      git -C "$REPO" pull --ff-only 2>&1 | sed 's/^/   /' || note "pull failed — installing the checkout as it stands"
    else
      note "present"
    fi
  elif [ -e "$REPO" ] && [ ! -d "$REPO/.git" ]; then
    die "$REPO exists but is not a git checkout — move it aside first"
  else
    if ! acting; then note "would clone $URL -> $REPO"; return 0; fi
    if git clone -q --depth 1 "$URL" "$REPO" 2>/dev/null; then
      note "cloned $URL"
    elif [ -f "$SELF_DIR/fleet-install.sh" ]; then
      # No network, but we are running from a checkout — use it rather than failing.
      note "clone failed (offline?) — copying this checkout instead"
      mkdir -p "$REPO"; cp -a "$SELF_DIR/." "$REPO/"
    else
      die "cannot reach $URL and not running from a checkout"
    fi
  fi

  # $REPO is root-owned, so git refuses to run there as a normal user ("dubious ownership").
  # Register it system-wide so anyone can INSPECT it - git log, git status, git diff - to answer
  # "which version is this machine running". Writing still needs root, because the files are
  # still root-owned; this only stops git from refusing to look.
  if acting && [ -d "$REPO/.git" ]; then
    if ! git config --system --get-all safe.directory 2>/dev/null | grep -qx "$REPO"; then
      git config --system --add safe.directory "$REPO" && note "registered $REPO as a safe.directory (read access for all users)"
    fi
  fi

  [ -d "$REPO" ] || return 0
  local head
  head="$(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo 'not a checkout')"
  note "version: $head"
  if [ "$SELF_DIR" != "$REPO" ] && [ -d "$REPO" ]; then
    note "note: running from $SELF_DIR, but installing from $REPO (canonical — see the header)"
  fi
}

# --- 2. commands ------------------------------------------------------------------------
# Replace a stale COPY as well as a stale symlink. A leftover regular file shadowing the
# symlink is exactly the silent drift this script exists to end, so it is reported loudly.
link_cmd() {
  local name="$1" rel="$2" src="$REPO/$2" dest="$BIN/$1" cur=""

  if [ ! -f "$SRC_ROOT/$rel" ]; then note "SKIP $name — $rel not in the repo"; return 0; fi

  if [ -L "$dest" ]; then
    cur="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ "$cur" = "$(readlink -f "$src")" ]; then note "ok      $name"; return 0; fi
    if acting; then ln -sfn "$src" "$dest"; note "relink  $name (was -> ${cur:-broken})"
    else note "would relink $name (was -> ${cur:-broken})"; fi
  elif [ -e "$dest" ]; then
    if acting; then rm -f "$dest"; ln -sfn "$src" "$dest"; note "REPLACED COPY  $name -> $rel"
    else note "would REPLACE A STALE COPY at $dest with a symlink to $rel"; fi
  else
    if acting; then ln -sfn "$src" "$dest"; note "linked  $name -> $rel"
    else note "would link $name -> $rel"; fi
  fi

  # A copy of the same command in sbin would shadow or confuse; say so.
  [ -f "/usr/local/sbin/$name" ] && note "   WARNING: /usr/local/sbin/$name also exists — remove it, it will drift"
  return 0
}

install_cmds() {
  step "guest commands in $BIN"
  for e in $GUEST_CMDS; do link_cmd "${e%%:*}" "${e##*:}"; done

  if is_host; then
    step "hypervisor commands in $BIN (qm found)"
    for e in $HOST_CMDS; do link_cmd "${e%%:*}" "${e##*:}"; done
  else
    step "hypervisor commands"
    note "skipped — no 'qm' on this machine, so this is a guest"
  fi

  step "assets"
  for e in $ASSETS; do
    local rel dest src
    rel="$(echo "$e" | cut -d: -f2)"; dest="$(echo "$e" | cut -d: -f3)"; src="$REPO/$rel"
    if [ ! -f "$SRC_ROOT/$rel" ]; then note "SKIP $rel — not in the repo"; continue; fi
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
      note "ok      $dest"
    elif acting; then
      mkdir -p "$(dirname "$dest")"; ln -sfn "$src" "$dest"; note "linked  $dest -> $rel"
    else
      note "would link $dest -> $rel"
    fi
  done
}

# --- 2b. "there is an update" notifier -------------------------------------------------
# Deliberately does NOT auto-update. The commands are symlinks into the repo, so a pull is an
# immediate deploy to every command at once; doing that unattended would push a bad commit
# onto every machine without anyone watching. This only FETCHES (read only) and leaves a
# stamp, then a login hint tells you. Taking the update stays a deliberate `sudo fleet-update`.
install_notifier() {
  step "update notifier"
  if ! acting; then note "would install a daily fetch + login hint"; return 0; fi

  # Expand REPO deliberately on one line, keep the rest single-quoted. Escaping $ through two
  # shells is how scripts that write scripts get corrupted - see AGENTS.md.
  {
    echo '#!/usr/bin/env bash'
    echo '# Written by fleet-install.sh. Fetches only; never changes what is installed.'
    echo 'set -euo pipefail'
    echo "REPO=\"$REPO\""
    cat <<'INNER'
STAMP=/var/lib/fleetkit/behind
mkdir -p /var/lib/fleetkit
git -C "$REPO" fetch -q origin 2>/dev/null || exit 0
n=$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo "$n" > "$STAMP"; else rm -f "$STAMP"; fi
INNER
  } > /usr/local/sbin/fleetkit-check-updates
  chmod 755 /usr/local/sbin/fleetkit-check-updates

  cat > /etc/systemd/system/fleetkit-check-updates.service <<'EOF'
[Unit]
Description=Check whether fleetkit has updates (fetch only, never applies)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fleetkit-check-updates
EOF
  cat > /etc/systemd/system/fleetkit-check-updates.timer <<'EOF'
[Unit]
Description=Daily fleetkit update check
[Timer]
OnBootSec=10min
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30min
[Install]
WantedBy=timers.target
EOF

  cat > /etc/profile.d/fleet-update-hint.sh <<'EOF'
# Written by fleet-install.sh. Reads a stamp file only - no network, no git, no delay.
if [ -s /var/lib/fleetkit/behind ]; then
  printf '\n  fleetkit is %s commit(s) behind. Take it with:  sudo fleet-update\n\n' \
    "$(cat /var/lib/fleetkit/behind 2>/dev/null)"
fi
EOF
  chmod 644 /etc/profile.d/fleet-update-hint.sh

  systemctl daemon-reload
  systemctl enable --now fleetkit-check-updates.timer >/dev/null 2>&1 || true
  /usr/local/sbin/fleetkit-check-updates 2>/dev/null || true
  if [ -s /var/lib/fleetkit/behind ]; then
    note "installed. This machine is $(cat /var/lib/fleetkit/behind) commit(s) behind right now."
  else
    note "installed. Up to date; the hint stays quiet until there is something to take."
  fi
}

# --- 3. the watchdog's timer ------------------------------------------------------------
# Only the systemd units, and only where there is remote desktop to watch. The command itself
# is already symlinked above.
install_watchdog() {
  step "RDP watchdog timer"
  if ! systemctl list-unit-files gnome-remote-desktop.service >/dev/null 2>&1; then
    note "skipped — gnome-remote-desktop is not installed, nothing to watch"
    return 0
  fi
  if ! acting; then note "would run: desk-rdp-watchdog --install"; return 0; fi
  if "$REPO/ubuntu/desk-rdp-watchdog.sh" --install 2>&1 | sed 's/^/   /'; then :; else
    note "WARNING: watchdog install failed — run 'sudo desk-rdp-watchdog --install' by hand"
  fi
}

# --- 4. verify, don't claim -------------------------------------------------------------
verify() {
  step "verify"
  local n=0 bad=0 list="$GUEST_CMDS"
  is_host && list="$GUEST_CMDS $HOST_CMDS"
  for e in $list; do
    local name="${e%%:*}" p
    p="$(command -v "$name" 2>/dev/null || true)"
    if [ -z "$p" ]; then note "MISSING $name"; bad=$((bad+1)); continue; fi
    if [ ! -e "$p" ]; then note "BROKEN  $name -> $(readlink "$p" 2>/dev/null)"; bad=$((bad+1)); continue; fi
    n=$((n+1))
  done
  note "$n command(s) resolve, $bad broken or missing"
  note "provenance: readlink -f \$(command -v desk-claim)"
  [ "$bad" -eq 0 ] || return 1
}

do_uninstall() {
  step "removing commands (the repo at $REPO is left alone)"
  local list="$GUEST_CMDS $HOST_CMDS"
  for e in $list; do
    local name="${e%%:*}" dest="$BIN/${e%%:*}"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$REPO/${e##*:}" ]; then
      rm -f "$dest"; note "removed $name"
    elif [ -e "$dest" ]; then
      note "left    $name — not our symlink, refusing to guess"
    fi
  done
  for e in $ASSETS; do
    local dest; dest="$(echo "$e" | cut -d: -f3)"
    [ -L "$dest" ] && { rm -f "$dest"; note "removed $dest"; }
  done
  systemctl disable --now fleetkit-check-updates.timer 2>/dev/null || true
  rm -f /etc/systemd/system/fleetkit-check-updates.{service,timer} \
        /usr/local/sbin/fleetkit-check-updates /etc/profile.d/fleet-update-hint.sh
  systemctl daemon-reload 2>/dev/null || true
  note "removed the update notifier"
  note "the watchdog timer is separate: sudo desk-rdp-watchdog --uninstall"
}

case "$MODE" in
  uninstall) do_uninstall ;;
  *)
    ensure_repo
    if [ ! -d "$REPO" ]; then
      # Dry run before the clone: plan against the checkout we are running from, so the first
      # --check (the one that matters) still shows what would happen instead of stopping short.
      if [ -f "$SELF_DIR/fleet-install.sh" ]; then
        SRC_ROOT="$SELF_DIR"
        note "planning against $SELF_DIR; links would still point at $REPO once cloned"
      else
        echo; echo "DRY RUN — nothing changed."; exit 0
      fi
    fi
    install_cmds
    install_notifier
    install_watchdog
    if acting; then verify; echo; echo "Done. Update later with: sudo fleet-install --update"
    else echo; echo "DRY RUN — nothing changed. Re-run with --apply."; fi ;;
esac
