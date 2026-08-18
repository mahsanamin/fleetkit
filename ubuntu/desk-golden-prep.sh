#!/usr/bin/env bash
#
# desk-golden-prep.sh — turn a restored copy of a working machine into a reusable golden.
#
# Runs INSIDE the copy, as root. Two phases, because you cannot delete the account you are
# logged in as:
#
#   sudo bash /tmp/desk-golden-prep.sh --seed <olduser>   # phase 1: create 'ubuntu', move toolchain
#   # log out, reconnect AS ubuntu, then:
#   sudo bash /tmp/desk-golden-prep.sh --finish           # phase 2: delete the seed, sysprep
#
#   sudo bash /tmp/desk-golden-prep.sh --reseal   # turn an already-claimed clone back into
#                                                 # a golden (better base: right size, no seed)
#
# Then, on the host:  qm shutdown <vmid> && qm template <vmid>
#
# Phase 1 copies the seed account's toolchain instead of reinstalling it: mise and its
# runtimes are already on this disk, and a local copy takes seconds where a fresh
# `mise use -g` re-downloads gigabytes.
#
set -euo pipefail

STD_USER=ubuntu
SEED=""                 # the original account to migrate away from, then delete
GRD_DIR=/etc/gnome-remote-desktop
GRD_OWNER=gnome-remote-desktop

MODE=setup
[ "${1:-}" = "--finish" ] && MODE=finish
[ "${1:-}" = "--reseal" ] && MODE=reseal

# --seed <user> / --user <user> may appear in any position
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    --seed) SEED="${args[$((i+1))]:-}" ;;
    --user) STD_USER="${args[$((i+1))]:-}" ;;
  esac
done
[ "$MODE" = setup ] && [ -z "$SEED" ] && { echo "ERROR: --seed <existing-user> is required for phase 1" >&2; exit 1; }

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v qm >/dev/null 2>&1 && die "this is the Proxmox host, not the guest"

# A GNOME login keyring is encrypted with the password of whoever created it. Copying a home
# directory carries it along, so the ORIGINAL owner's password unlocks it on the clone and
# their saved secrets travel with it. Found the hard way on VM 201, 2026-08-15: Chrome asked
# for a keyring password and the ORIGINAL owner's password was the one that worked.
purge_keyrings() {
  step "keyrings"
  local found=0
  for d in /home/*/.local/share/keyrings /root/.local/share/keyrings; do
    [ -e "$d" ] || continue
    rm -rf "$d"; echo "   removed $d"; found=1
  done
  [ "$found" -eq 0 ] && echo "   none present"
  # NSS/Chrome certificate and password stores travel the same way
  for d in /home/*/.a_secs; do
    [ -e "$d" ] && { rm -f "$d"; echo "   removed $d (per-machine secrets)"; }
  done
  for d in /home/*/.pki /home/*/.config/google-chrome /home/*/.mozilla; do
    [ -e "$d" ] && { rm -rf "$d"; echo "   removed $d"; }
  done
  return 0
}

# A sysprepped template has no SSH host keys, and nothing on a non-cloud-init image
# regenerates them, so sshd refuses to start on a fresh clone and it can only be reached
# through the console. This unit fixes that for every clone.
install_sshkeygen_unit() {
  step "first-boot SSH host key unit"
  cat >/etc/systemd/system/regenerate-ssh-host-keys.service <<'UNIT'
[Unit]
Description=Regenerate SSH host keys when missing (fresh clone of a template)
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service ssh.socket
DefaultDependencies=no
After=local-fs.target
Requires=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable regenerate-ssh-host-keys.service >/dev/null 2>&1 \
    && echo "   enabled — clones will have SSH on first boot" \
    || echo "   WARNING: could not enable the unit"
}

# ============================================================ reseal
# Turn an ALREADY CLAIMED machine back into a golden. Use this when a clone is a better base
# than the current template: it already has the standard account, no seed account, and the
# right disk size, so clones from it need no shrink.
if [ "$MODE" = reseal ]; then
  id "$STD_USER" >/dev/null 2>&1 || die "no '$STD_USER' account — this is not a desktop clone"
  getent passwd "$SEED" >/dev/null && die "$SEED still exists here. Reseal a machine that has already had it removed."

  echo "This turns $(hostname) into a golden template base."
  echo "It will be renamed, its identity wiped, and its RDP credentials cleared."
  printf 'Proceed? [y/N] '
  read -r r; case "$r" in [yY]|[yY][eE][sS]) ;; *) echo aborted; exit 1 ;; esac

  purge_keyrings
  install_sshkeygen_unit

  step "hostname -> desk-golden"
  hostnamectl set-hostname desk-golden
  sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tdesk-golden/' /etc/hosts

  step "clearing RDP credentials"
  grdctl --system rdp clear-credentials 2>/dev/null || true
  grdctl --system status 2>/dev/null | grep -iE 'username|password' | sed 's/^/   /' || true

  step "sysprep"
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_*
  rm -f /root/.bash_history /root/.zsh_history /home/*/.bash_history /home/*/.zsh_history
  rm -f /var/log/lastlog /var/log/wtmp /var/log/btmp
  rm -f /etc/desk-no-claim
  rm -rf /var/lib/desk-claim
  echo "   machine-id emptied, host keys and histories removed, claim markers cleared"

  step "credential sweep"
  found=0
  for p in /home/*/.config/gh /home/*/.ssh /home/*/.aws /home/*/.git-credentials \
           /home/*/.docker/config.json /home/*/.local/share/keyrings /home/*/.a_secs; do
    [ -e "$p" ] || continue
    # An EMPTY .ssh is created by useradd and carries nothing. Only report paths with
    # something in them, or the sweep cries wolf on every reseal and gets ignored.
    if [ -d "$p" ] && [ -z "$(ls -A "$p" 2>/dev/null)" ]; then continue; fi
    echo "   FOUND: $p"; found=1
  done
  [ "$found" -eq 0 ] && echo "   clean"

  cat <<'NEXT'

Resealed. On the HOST:

  qm shutdown <this vmid>
  qm template <this vmid>

Clones from it need NO shrink and NO console access:

  qm clone <template> <vmid> --name <name> --full --storage <storage>
  qm set <vmid> --cores 6 --memory 10240 --balloon 4096 --onboot 1
  qm start <vmid>
  ssh ubuntu@<ip>            # works on first boot now
  sudo desk-claim <person>
NEXT
  exit 0
fi

# ============================================================ phase 2: finish
if [ "$MODE" = finish ]; then
  [ "${SUDO_USER:-}" != "$SEED" ] || die "you are logged in as $SEED. Reconnect as $STD_USER first."
  id "$STD_USER" >/dev/null 2>&1 || die "phase 1 has not run: no '$STD_USER' account"

  step "removing the seed account '$SEED'"
  if id "$SEED" >/dev/null 2>&1; then
    loginctl terminate-user "$SEED" 2>/dev/null || true
    pkill -KILL -u "$SEED" 2>/dev/null || true
    sleep 2
    deluser --remove-home "$SEED" 2>&1 | tail -2 || die "deluser failed — check for running processes"
    echo "   deleted, home and all"
  else
    echo "   already gone"
  fi
  getent passwd "$SEED" >/dev/null && die "$SEED still exists — stop and investigate" || true

  purge_keyrings
  install_sshkeygen_unit

  step "clearing RDP credentials"
  # A template must not carry a usable login. desk-claim sets these per machine.
  grdctl --system rdp clear-credentials 2>/dev/null || true
  grdctl --system status 2>/dev/null | grep -iE 'username|password' | sed 's/^/   /' || true

  step "sysprep"
  : > /etc/machine-id                       # EMPTY, so each clone derives its own from SMBIOS
  rm -f /var/lib/dbus/machine-id
  echo "   /etc/machine-id emptied"
  rm -f /etc/ssh/ssh_host_*
  echo "   ssh host keys removed (regenerated on first boot)"
  rm -f /root/.bash_history /root/.zsh_history
  rm -f /home/*/.bash_history /home/*/.zsh_history
  echo "   shell histories cleared"
  rm -f /etc/desk-no-claim
  echo "   /etc/desk-no-claim removed, so clones CAN be claimed"

  step "credential sweep — anything found here would ship to colleagues"
  found=0
  for p in /home/*/.config/gh /home/*/.ssh /home/*/.aws /home/*/.git-credentials \
           /home/*/.docker/config.json /home/*/.local/share/keyrings /home/*/.pki \
           /home/*/.a_secs; do
    [ -e "$p" ] && { echo "   FOUND: $p"; found=1; }
  done
  [ "$found" -eq 0 ] && echo "   clean"

  cat <<'NEXT'

Phase 2 done. On the HOST:

  qm shutdown <vmid>
  qm template <vmid>

Then per person:

  qm clone <template> <vmid> --name <name> --full --storage <storage>
  qm set <vmid> --cores 6 --memory 10240 --balloon 4096 --onboot 1
  qm start <vmid>
  # in the clone:  sudo desk-claim <person>
NEXT
  exit 0
fi

# ============================================================ phase 1: setup
step "standard account '$STD_USER'"
SHELL_BIN=/bin/bash
[ -x /usr/bin/zsh ] && SHELL_BIN=/usr/bin/zsh

if id "$STD_USER" >/dev/null 2>&1; then
  echo "   exists already"
else
  useradd --create-home --shell "$SHELL_BIN" --comment "Desktop User" "$STD_USER"
  echo "   created with shell $SHELL_BIN"
fi
for g in sudo docker; do
  getent group "$g" >/dev/null && usermod -aG "$g" "$STD_USER" && echo "   in group $g"
done

step "toolchain from '$SEED' (copy, not reinstall)"
SEED_HOME="$(getent passwd "$SEED" | cut -d: -f6 || true)"
STD_HOME="$(getent passwd "$STD_USER" | cut -d: -f6)"

if [ -n "$SEED_HOME" ] && [ -d "$SEED_HOME" ]; then
  for item in .local .zshrc .bashrc .config/starship.toml .config/mise .default-cargo-crates; do
    if [ -e "$SEED_HOME/$item" ]; then
      mkdir -p "$(dirname "$STD_HOME/$item")"
      cp -a "$SEED_HOME/$item" "$STD_HOME/$item"
      echo "   copied $item"
    fi
  done
  # Installers often write an ABSOLUTE /home/<user> path into .bashrc or .zshrc (mise does),
  # which would silently point at a deleted home after phase 2.
  for f in "$STD_HOME/.zshrc" "$STD_HOME/.bashrc"; do
    [ -f "$f" ] && sed -i "s#$SEED_HOME#$STD_HOME#g" "$f"
  done
  echo "   rewrote absolute $SEED_HOME paths"
  # NEVER carry the seed's keyring, NSS store or browser profile into the shared account.
  rm -rf "$STD_HOME/.local/share/keyrings" "$STD_HOME/.pki" \
         "$STD_HOME/.config/google-chrome" "$STD_HOME/.mozilla"
  echo "   dropped keyrings / browser stores from the copy"
  chown -R "$STD_USER:$STD_USER" "$STD_HOME"
else
  echo "   no seed home found, skipping (set the toolchain up by hand)"
fi

step "verifying the toolchain works as $STD_USER"
sudo -u "$STD_USER" bash -lc 'command -v mise >/dev/null && mise --version' 2>/dev/null \
  | sed 's/^/   mise /' || echo "   WARNING: mise not on PATH for $STD_USER — check .zshrc/.bashrc"

step "RDP certificate for this machine (CN=$(hostname))"
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -subj "/O=homelab/CN=$(hostname)" \
  -out /tmp/.gp.crt -keyout /tmp/.gp.key 2>/dev/null
install -o "$GRD_OWNER" -g "$GRD_OWNER" -m 644 /tmp/.gp.crt "$GRD_DIR/rdp-tls.crt"
install -o "$GRD_OWNER" -g "$GRD_OWNER" -m 600 /tmp/.gp.key "$GRD_DIR/rdp-tls.key"
rm -f /tmp/.gp.crt /tmp/.gp.key
grdctl --system rdp set-tls-cert "$GRD_DIR/rdp-tls.crt"
grdctl --system rdp set-tls-key  "$GRD_DIR/rdp-tls.key"
echo "   replaced — the source machine's private key is no longer on this disk"

step "password for $STD_USER (temporary; the golden is only reachable by you)"
read -r -s -p "   Password: " PW;  echo
read -r -s -p "   Repeat:   " PW2; echo
[ -n "$PW" ]       || die "empty password"
[ "$PW" = "$PW2" ] || die "entries do not match"
[ ${#PW} -ge 8 ]   || die "use at least 8 characters"
printf '%s:%s\n' "$STD_USER" "$PW" | chpasswd
grdctl --system rdp set-credentials "$STD_USER" "$PW" >/dev/null 2>&1 \
  && echo "   unix + RDP credentials set for $STD_USER" \
  || { echo "   type them: username $STD_USER"; grdctl --system rdp set-credentials; }
unset PW PW2
systemctl restart gnome-remote-desktop.service || true

step "desk-claim"
if [ -f /tmp/desk-claim.sh ]; then
  install -m 755 /tmp/desk-claim.sh /usr/local/bin/desk-claim
  echo "   installed to /usr/local/bin/desk-claim"
else
  echo "   /tmp/desk-claim.sh not found — copy it over before templating"
fi

cat <<NEXT

Phase 1 done.

NEXT:
  1. Reconnect to this machine AS $STD_USER:   ssh $STD_USER@$(hostname -I | awk '{print $1}')
  2. Check the shell looks right (zsh, starship, 'mise ls' shows the runtimes)
  3. Then:   sudo bash /tmp/desk-golden-prep.sh --finish

Phase 2 deletes '$SEED' and its home, which is what keeps the original owner's password
and data off every machine built from this image. It refuses to run while you are logged in as $SEED.
NEXT
