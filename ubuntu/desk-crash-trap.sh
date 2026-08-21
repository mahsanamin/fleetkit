#!/usr/bin/env bash
#
# desk-crash-trap.sh — make a guest that freezes leave evidence, and recover by itself.
#
# Runs INSIDE the guest, as root.
#
#   ./desk-crash-trap.sh                    # report current state, change nothing
#   sudo ./desk-crash-trap.sh --apply       # arm the trap
#   sudo ./desk-crash-trap.sh --apply --no-panic-on-hang
#   sudo ./desk-crash-trap.sh --revert
#
# WHY THIS EXISTS
#
# A desktop guest froze: powered on, qemu alive and burning CPU, but no network at layer 2,
# no guest agent, no console update, and NOTHING in the journal. It had to be hard stopped.
#
# The last sysstat sample, 17 seconds before it died, showed the machine 99.76% idle, 2.4 GB
# of 24 GB used, zero swap, 1.3 tps of disk. An idle, healthy machine that stops instantly
# does not do that to itself, so the cause is almost certainly below the guest: the
# hypervisor, the host's storage, or a virtio/KVM fault.
#
# We could not tell which, and that is the point of this script. The machine was configured
# so a hang leaves NO trace:
#
#   kernel.nmi_watchdog    = 0   hard-lockup detector off, a wedged CPU prints nothing
#   kernel.hung_task_panic = 0   a task stuck >120s is logged, never panics
#   kernel.panic           = 0   on panic it hangs forever instead of rebooting
#   no serial console            nothing escapes if disk I/O is dead
#   kdump armed, /var/crash EMPTY -> it never panicked, it HUNG
#
# Silence was not missing evidence. It was what that configuration produces.
#
# WHAT THIS CHANGES
#
#   1. Serial console. The highest-value item by far: kernel output leaves over a virtual
#      serial port, so it survives a guest that cannot write to its own disk. Needs ONE
#      command on the hypervisor too, printed at the end.
#   2. Detectors on. nmi_watchdog catches hard lockups. hung_task_panic turns a 120s hang
#      into a real panic, which kdump then captures. Silence becomes a dump.
#   3. Self-recovery. kernel.panic=30 reboots 30s after a panic, so a freeze costs minutes
#      rather than a morning and a hand restart.
#   4. Finer sysstat. 10-minute samples are why our closest reading was 17 seconds out.
#      1-minute samples show the final minute.
#
# THE ONE TRADE-OFF, STATED PLAINLY
#
# --panic-on-hang (the default) reboots the machine on ANY 120-second uninterruptible hang,
# including a merely slow disk rather than a real fault. On a remote desktop that is usually
# the right trade, because a hung desktop is already unusable. Pass --no-panic-on-hang to
# keep the diagnostics and drop the automatic reboot.
#
set -euo pipefail

SYSCTL_FILE=/etc/sysctl.d/60-desk-crash-trap.conf
GRUB_FILE=/etc/default/grub
SYSSTAT_DROPIN=/etc/systemd/system/sysstat-collect.timer.d/60-desk-crash-trap.conf
CONSOLE_ARGS="console=tty1 console=ttyS0,115200"
PANIC_ON_HANG=1
MODE=check

while [ $# -gt 0 ]; do
  case "$1" in
    --check)             MODE=check; shift ;;
    --apply)             MODE=apply; shift ;;
    --revert)            MODE=revert; shift ;;
    --no-panic-on-hang)  PANIC_ON_HANG=0; shift ;;
    -h|--help)           sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
  esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
note() { echo "   $*"; }

[ "$MODE" = check ] || [ "$(id -u)" -eq 0 ] || die "$MODE needs root — re-run with sudo"
command -v qm >/dev/null 2>&1 && die "this is the hypervisor host, not the guest"

# ---------------------------------------------------------------- report
show_state() {
  step "current state"
  local v
  for k in kernel.nmi_watchdog kernel.hung_task_panic kernel.hung_task_timeout_secs \
           kernel.panic kernel.panic_on_oops; do
    v="$(sysctl -n "$k" 2>/dev/null || echo '?')"
    printf "   %-34s %s\n" "$k" "$v"
  done
  grep -q "console=ttyS0" /proc/cmdline \
    && note "serial console                      ACTIVE on this boot" \
    || note "serial console                      absent (nothing escapes a dead disk)"
  if systemctl is-enabled kdump-tools >/dev/null 2>&1; then
    local n; n=$(find /var/crash -maxdepth 1 -type d -name '2*' 2>/dev/null | wc -l)
    note "kdump                               enabled, $n kernel dump(s) in /var/crash"
  else
    note "kdump                               NOT enabled"
  fi
  [ -d /var/log/journal ] && note "persistent journal                  yes" \
                          || note "persistent journal                  NO — logs die with the boot"
  # Ask systemd for the EFFECTIVE schedule. Reading `systemctl cat` picks the vendor unit's
  # line and ignores the drop-in, which reports the old interval after this script changed it.
  local iv
  iv="$(systemctl show sysstat-collect.timer -p TimersCalendar --value 2>/dev/null \
        | sed -n 's/.*OnCalendar=\([^;]*\);.*/\1/p' | head -1)"
  note "sysstat interval                   ${iv:-not installed}"
}

# ---------------------------------------------------------------- apply
apply_sysctl() {
  step "kernel detectors + self-recovery"
  {
    echo "# Written by desk-crash-trap.sh. See fleetkit docs/diagnosing-a-frozen-guest.md"
    echo "kernel.nmi_watchdog = 1"
    echo "kernel.panic_on_oops = 1"
    echo "kernel.panic = 30"
    echo "kernel.hung_task_timeout_secs = 120"
    if [ "$PANIC_ON_HANG" -eq 1 ]; then
      echo "kernel.hung_task_panic = 1"
      echo "kernel.softlockup_panic = 1"
    else
      echo "# hung_task_panic left off (--no-panic-on-hang): hangs are logged, not captured"
      echo "kernel.hung_task_panic = 0"
    fi
  } > "$SYSCTL_FILE"
  sysctl -q --system 2>/dev/null || true
  note "wrote $SYSCTL_FILE"

  # Verify rather than claim. nmi_watchdog needs a PMU, which a KVM guest may not have.
  local got; got="$(sysctl -n kernel.nmi_watchdog 2>/dev/null || echo '?')"
  if [ "$got" = "1" ]; then
    note "nmi_watchdog active — hard lockups will now print"
  else
    note "nmi_watchdog reads back '$got', NOT 1."
    note "   A KVM guest often has no PMU, so the hard-lockup detector cannot arm."
    note "   The serial console and hung_task_panic still work; this one may not."
  fi
}

apply_serial() {
  step "serial console"
  if grep -q "console=ttyS0" "$GRUB_FILE"; then
    note "already in $GRUB_FILE"
  else
    cp -a "$GRUB_FILE" "$GRUB_FILE.desk-crash-trap.bak"
    # Append inside the existing quoted value rather than replacing it.
    sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $CONSOLE_ARGS\"/" "$GRUB_FILE"
    grep -q "console=ttyS0" "$GRUB_FILE" \
      || { cp -a "$GRUB_FILE.desk-crash-trap.bak" "$GRUB_FILE"; die "could not edit GRUB_CMDLINE_LINUX_DEFAULT, restored backup"; }
    note "added '$CONSOLE_ARGS' (backup: $GRUB_FILE.desk-crash-trap.bak)"
  fi
  if update-grub >/dev/null 2>&1 || update-grub2 >/dev/null 2>&1; then
    note "grub updated"
  else
    note "WARNING: update-grub failed — the console will not be active after reboot"
  fi
  grep -q "console=ttyS0" /proc/cmdline \
    && note "active on THIS boot" \
    || note "NEEDS A REBOOT to take effect"
}

apply_sysstat() {
  step "sysstat resolution"
  if ! systemctl list-unit-files sysstat-collect.timer >/dev/null 2>&1; then
    note "sysstat not installed — skipping (install it: apt install sysstat)"; return 0
  fi
  mkdir -p "$(dirname "$SYSSTAT_DROPIN")"
  printf '[Timer]\nOnCalendar=\nOnCalendar=*:00/01\n' > "$SYSSTAT_DROPIN"
  systemctl daemon-reload
  systemctl restart sysstat-collect.timer 2>/dev/null || true
  note "sampling every 1 minute (was 10) — $SYSSTAT_DROPIN"
}

do_apply() {
  apply_sysctl
  apply_serial
  apply_sysstat
  show_state
  cat <<'NEXT'

== one command on the HYPERVISOR, or the serial console goes nowhere

   qm set <VMID> --serial0 socket

   Then, when the guest freezes, read what the disk never saw:

   qm terminal <VMID>

== then reboot the guest so the console argument takes effect

   sudo reboot

NEXT
}

do_revert() {
  step "reverting"
  rm -f "$SYSCTL_FILE" "$SYSSTAT_DROPIN"
  if [ -f "$GRUB_FILE.desk-crash-trap.bak" ]; then
    mv "$GRUB_FILE.desk-crash-trap.bak" "$GRUB_FILE"; update-grub >/dev/null 2>&1 || true
    note "restored $GRUB_FILE"
  fi
  systemctl daemon-reload 2>/dev/null || true
  sysctl -q --system 2>/dev/null || true
  note "reverted. Reboot to drop the serial console argument."
}

case "$MODE" in
  check)  show_state; echo; echo "Report only. Arm it with: sudo $0 --apply" ;;
  apply)  do_apply ;;
  revert) do_revert ;;
esac
