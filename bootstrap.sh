#!/usr/bin/env bash
#
# bootstrap.sh — set a fresh Ubuntu guest up with ONE command and no credentials.
#
#   curl -fsSL https://raw.githubusercontent.com/mahsanamin/fleetkit/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- --colour cyan --label MY-BOX --docker
#
# It downloads this repo as a tarball (no git, no SSH key, no login), drops it in
# /opt/fleetkit, and runs ubuntu/guest-setup.sh with whatever arguments you passed.
#
# Everything here is public on purpose: a machine you are about to hand to someone else is
# the last place you want your GitHub credentials.
#
set -euo pipefail

REPO="${FLEET_REPO:-mahsanamin/fleetkit}"
REF="${FLEET_REF:-main}"
DEST="${FLEET_DEST:-/opt/fleetkit}"

echo "== fetching $REPO@$REF"
command -v curl >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
sudo mkdir -p "$DEST"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" \
  | sudo tar -xz -C "$DEST" --strip-components=1
sudo chmod +x "$DEST"/ubuntu/*.sh "$DEST"/proxmox/*.sh 2>/dev/null || true
echo "   unpacked into $DEST"

echo "== running guest-setup"
exec "$DEST/ubuntu/guest-setup.sh" "$@"
