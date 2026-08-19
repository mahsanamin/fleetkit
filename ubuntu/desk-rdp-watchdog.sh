#!/usr/bin/env bash
#
# desk-rdp-watchdog.sh — keep GNOME Remote Desktop actually answering on :3389.
#
# Runs INSIDE the guest, as root.
#
#   sudo ./desk-rdp-watchdog.sh              # probe once and report, change nothing
#   sudo ./desk-rdp-watchdog.sh --check      # the same, explicitly
#   sudo ./desk-rdp-watchdog.sh --install    # install as a command + a 2-minute timer
#   sudo ./desk-rdp-watchdog.sh --run        # one watchdog pass: probe, and heal if dead
#   sudo ./desk-rdp-watchdog.sh --uninstall
#
# Idempotent: re-run --install after a pull and it replaces the copy and the units.
#
# WHY THIS EXISTS
#
# GRD Remote Login is a three-process chain with NO supervisor:
#
#   system daemon (owns :3389)  --D-Bus-->  GDM greeter session
#                                             `--starts--> gnome-remote-desktop-handover.service
#                                           a logged-in session's --handover daemon
#
# Nothing in that chain watches anything else. If the greeter's shell dies, or a session is
# orphaned by an unclean disconnect, the system daemon keeps a stale reference and never
# recovers. It then accepts your TCP connection, has nowhere to hand it, and closes it with
# your bytes still unread — which on the wire is a reset. RDP is dead until a human notices.
#
# Two properties make this expensive, and they are why a watchdog is the only real answer:
#
#   - systemd CANNOT see it. The unit stays `active (running)`. Nothing crashed, so nothing
#     gets restarted and no unit is in a failed state.
#   - the failure path logs NOTHING. Measured: three RDP probes, zero journal lines. Both
#     `systemctl status` and `journalctl` look clean while RDP is 100% dead.
#
# So the health check has to speak real RDP. Nothing cheaper is evidence.
# Background: docs/remote-desktop-on-wayland.md.
#
# WHAT IT DOES WHEN IT FINDS RDP DEAD
#
#   1. restart gnome-remote-desktop            — cheap, and keeps live sessions
#   2. still dead? restart gdm, wait, THEN restart gnome-remote-desktop
#
# That order is not a preference. Restarting gdm ALONE does not fix it: the stale system
# daemon stays paired with the greeter that was just replaced, so gnome-remote-desktop has to
# be restarted AFTER the new greeter has registered. Confirmed on a real failure.
#
# COST: step 2 restarts the display manager, which ends any graphical session on the machine.
# It only runs when the probe has failed repeatedly AND nobody is connected.
#
set -euo pipefail

PORT=3389
ATTEMPTS=3               # consecutive failed probes before acting
GAP=20                   # seconds between probes
COOLDOWN=600             # never act more than once per this many seconds
STATE=/var/lib/desk-rdp-watchdog
STAMP="$STATE/last-action"
INSTALL_PATH=/usr/local/sbin/desk-rdp-watchdog
TAG=desk-rdp-watchdog

log()  { logger -t "$TAG" -- "$*" 2>/dev/null || true; echo "[$TAG] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

MODE=check
case "${1:-}" in
  ""|--check)  MODE=check ;;
  --install)   MODE=install ;;
  --uninstall) MODE=uninstall ;;
  --run)       MODE=run ;;
  *) die "unknown option '$1' — use --check, --install, --run or --uninstall" ;;
esac

[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v qm >/dev/null 2>&1 && die "this is the hypervisor host, not the guest"

# --- the probe -------------------------------------------------------------------------
# A real RDP client's first packet: TPKT + X.224 Connection Request carrying an mstshash
# cookie and an RDP_NEG_REQ. A healthy GRD replies with an X.224 NEG_RSP (type 0x02).
# Anything else — reset, timeout, garbage — is a failure.
probe() {
  python3 - "$PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
cookie = b"Cookie: mstshash=watchdog\r\n"
neg    = bytes([0x01, 0x00, 0x08, 0x00]) + (0x00000003).to_bytes(4, "little")
body   = bytes([0xE0, 0x00, 0x00, 0x00, 0x00, 0x00]) + cookie + neg
x224   = bytes([len(body)]) + body
pkt    = bytes([0x03, 0x00]) + (4 + len(x224)).to_bytes(2, "big") + x224
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=8)
    s.sendall(pkt)
    r = s.recv(64)
    s.close()
except Exception as e:
    print("FAIL %s: %s" % (type(e).__name__, e)); sys.exit(1)
if len(r) >= 12 and r[0] == 0x03 and r[11] == 0x02:
    print("OK NEG_RSP"); sys.exit(0)
print("FAIL unexpected reply: %s" % r.hex()); sys.exit(1)
PY
}

# Somebody actively connected? Then the daemon is demonstrably working. Never touch it.
in_use() {
  ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | grep -q .
}

cooling_down() {
  [ -f "$STAMP" ] || return 1
  local last now
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -lt "$COOLDOWN" ]
}

healthy_within() {   # wait up to $1 seconds for the probe to pass
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    probe >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# --- modes -----------------------------------------------------------------------------
do_check() {
  local out
  if out=$(probe 2>&1); then
    echo "RDP is answering on :$PORT — $out"
    in_use && echo "   (a client is connected right now)"
    return 0
  fi
  echo "RDP is NOT answering on :$PORT — $out"
  echo "   Note: 'systemctl status gnome-remote-desktop' will still say active (running)."
  echo "   Heal it with: $0 --run"
  return 1
}

do_run() {
  mkdir -p "$STATE"

  local i out=""
  for i in $(seq 1 "$ATTEMPTS"); do
    if out=$(probe 2>&1); then
      [ "$i" -gt 1 ] && log "recovered on its own after $(( i - 1 )) failed probe(s)"
      return 0
    fi
    [ "$i" -lt "$ATTEMPTS" ] && sleep "$GAP"
  done

  if in_use; then
    log "probe failing ($out) but a client is connected — leaving it alone"
    return 0
  fi
  if cooling_down; then
    log "probe failing ($out) but acted less than ${COOLDOWN}s ago — not thrashing"
    return 0
  fi

  date +%s > "$STAMP"
  log "RDP dead after $ATTEMPTS probes ($out) — step 1: restarting gnome-remote-desktop"
  systemctl daemon-reload || true
  systemctl restart gnome-remote-desktop.service || true
  if healthy_within 30; then log "recovered after gnome-remote-desktop restart"; return 0; fi

  log "still dead — step 2: restarting gdm, then gnome-remote-desktop (ends graphical sessions)"
  systemctl restart gdm.service || true
  sleep 15                                    # let the new greeter register with GDM
  systemctl restart gnome-remote-desktop.service || true
  if healthy_within 45; then log "recovered after gdm + gnome-remote-desktop restart"; return 0; fi

  log "STILL DEAD after both escalations — needs a human. Look at: journalctl -u gdm -u gnome-remote-desktop, and coredumpctl for a gnome-shell SEGV"
  return 1
}

do_install() {
  command -v python3 >/dev/null || die "python3 is required for the probe"
  command -v ss      >/dev/null || die "ss is required (iproute2)"
  systemctl list-unit-files gnome-remote-desktop.service >/dev/null 2>&1 \
    || die "gnome-remote-desktop is not installed — nothing to watch"

  install -m 755 "$0" "$INSTALL_PATH"
  mkdir -p "$STATE"

  cat > /etc/systemd/system/desk-rdp-watchdog.service <<EOF
[Unit]
Description=Verify GNOME Remote Desktop is answering on :$PORT, and heal it if not
After=gnome-remote-desktop.service gdm.service
Documentation=https://github.com/mahsanamin/fleetkit/blob/main/docs/remote-desktop-on-wayland.md

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --run
EOF

  cat > /etc/systemd/system/desk-rdp-watchdog.timer <<'EOF'
[Unit]
Description=Periodic GNOME Remote Desktop health check

[Timer]
OnBootSec=3min
OnUnitInactiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now desk-rdp-watchdog.timer

  # Verify, don't claim.
  echo
  echo "installed as $INSTALL_PATH, timer enabled"
  local out
  if out=$(probe 2>&1); then echo "   probe now: $out"
  else echo "   probe now: $out  (the timer will attempt a heal within ~2 min)"; fi
  systemctl is-enabled desk-rdp-watchdog.timer >/dev/null \
    && echo "   timer: enabled" || echo "   timer: NOT enabled — check systemctl status"
  echo
  echo "Prove it heals rather than trusting it:"
  echo "   sudo systemctl stop gnome-remote-desktop && journalctl -t $TAG -f"
}

do_uninstall() {
  systemctl disable --now desk-rdp-watchdog.timer 2>/dev/null || true
  rm -f /etc/systemd/system/desk-rdp-watchdog.service \
        /etc/systemd/system/desk-rdp-watchdog.timer \
        "$INSTALL_PATH"
  systemctl daemon-reload
  echo "uninstalled (state kept in $STATE)"
}

case "$MODE" in
  check)     do_check ;;
  install)   do_install ;;
  run)       do_run ;;
  uninstall) do_uninstall ;;
esac
