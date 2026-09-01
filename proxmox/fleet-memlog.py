#!/usr/bin/env python3
"""
fleet-memlog - sample the WORKING SET of every Proxmox guest, not its consumption.

Runs on the Proxmox host. No arguments samples once and appends to the CSV;
--report reads the CSV back and tells you what each guest could safely be sized to.

WHY THIS EXISTS

Once a guest has `balloon` = `memory` there is no reclaim, so its page cache expands
until it fills the whole allocation. Linux treats free RAM as wasted RAM. That means
`free`, `qm status`, and the QEMU process RSS all trend towards the allocation for
every guest, whether it needs 4 GB or 16 GB, and a snapshot of "used" tells you
nothing about what could be given back.

What does not lie is MemAvailable: the kernel's own estimate of what could be handed
to a new process without swapping. The complement of it,

    working set = MemTotal - MemAvailable

is memory that genuinely cannot be reclaimed. That is the number to size against, and
its PEAK over days is what matters, so this samples on a timer and keeps the history.

Swap used is the cross-check: a guest that never swaps was never actually short.

USAGE

    fleet-memlog                 # one sample, appends a row per guest
    fleet-memlog --report        # summarise the CSV, recommend sizes
    fleet-memlog --report --days 7
    fleet-memlog --install       # systemd timer, every 15 minutes
    fleet-memlog --uninstall

The CSV is /var/log/fleet-memlog.csv unless $FLEET_MEMLOG_CSV says otherwise.
"""

import csv
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta

CSV_PATH = os.environ.get("FLEET_MEMLOG_CSV", "/var/log/fleet-memlog.csv")
FIELDS = [
    "ts", "vmid", "name", "kind", "alloc_mb", "mem_total_kb", "mem_available_kb",
    "working_set_kb", "committed_kb", "anon_kb", "swap_used_kb", "load1",
]
# Headroom applied to the observed peak when recommending a size, and the floor
# below which we do not recommend shrinking a guest at all.
SAFETY = 1.5
FLOOR_MB = {"lxc": 512, "qemu": 2048}


def run(cmd, timeout=25):
    """Run a command, return stdout or None. Never raises."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def parse_meminfo(text):
    """/proc/meminfo -> {key: kB}. Values without kB (HugePages_*) are skipped."""
    out = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        parts = v.split()
        if parts and parts[0].isdigit():
            out[k.strip()] = int(parts[0])
    return out


def guest_meminfo(vmid, kind):
    """Read /proc/meminfo from inside a guest. None if it cannot be reached."""
    if kind == "lxc":
        text = run(["pct", "exec", str(vmid), "--", "cat", "/proc/meminfo"])
        return parse_meminfo(text) if text else None

    raw = run(["qm", "guest-exec", str(vmid), "--timeout", "10", "--",
               "/bin/cat", "/proc/meminfo"])
    if raw is None:
        raw = run(["qm", "guest", "exec", str(vmid), "--timeout", "10", "--",
                   "/bin/cat", "/proc/meminfo"])
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if data.get("exitcode") not in (0, None):
        return None
    return parse_meminfo(data.get("out-data", ""))


def running_guests():
    """[(vmid, name, kind, alloc_mb)] for everything currently running."""
    guests = []
    for kind, lister, cfg in (("qemu", "qm", "qm"), ("lxc", "pct", "pct")):
        out = run([lister, "list"])
        if not out:
            continue
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) < 3:
                continue
            vmid, name, status = f[0], f[1], f[2]
            if kind == "lxc":
                vmid, status, name = f[0], f[1], f[-1]
            if status != "running" or not vmid.isdigit():
                continue
            alloc = 0
            conf = run([cfg, "config", vmid])
            if conf:
                for cl in conf.splitlines():
                    if cl.startswith("memory:"):
                        alloc = int(cl.split(":", 1)[1].strip())
                    elif cl.startswith("name:") or cl.startswith("hostname:"):
                        name = cl.split(":", 1)[1].strip()
            guests.append((int(vmid), name, kind, alloc))
    return sorted(guests)


def sample():
    ts = datetime.now().replace(microsecond=0).isoformat()
    try:
        load1 = open("/proc/loadavg").read().split()[0]
    except OSError:
        load1 = ""

    rows = []
    host = parse_meminfo(open("/proc/meminfo").read())
    rows.append(host_row(ts, host, load1))

    for vmid, name, kind, alloc in running_guests():
        mi = guest_meminfo(vmid, kind)
        if not mi:
            rows.append({"ts": ts, "vmid": vmid, "name": name, "kind": kind,
                         "alloc_mb": alloc, "load1": load1})
            continue
        rows.append(row_from(ts, vmid, name, kind, alloc, mi, ""))

    write(rows)
    return rows


def row_from(ts, vmid, name, kind, alloc, mi, load1):
    total = mi.get("MemTotal", 0)
    avail = mi.get("MemAvailable", 0)
    return {
        "ts": ts, "vmid": vmid, "name": name, "kind": kind, "alloc_mb": alloc,
        "mem_total_kb": total,
        "mem_available_kb": avail,
        "working_set_kb": max(total - avail, 0),
        "committed_kb": mi.get("Committed_AS", 0),
        "anon_kb": mi.get("AnonPages", 0),
        "swap_used_kb": max(mi.get("SwapTotal", 0) - mi.get("SwapFree", 0), 0),
        "load1": load1,
    }


def host_row(ts, mi, load1):
    r = row_from(ts, 0, "HOST", "host", mi.get("MemTotal", 0) // 1024, mi, load1)
    return r


def write(rows):
    new = not os.path.exists(CSV_PATH) or os.path.getsize(CSV_PATH) == 0
    with open(CSV_PATH, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, extrasaction="ignore")
        if new:
            w.writeheader()
        for r in rows:
            w.writerow(r)


def pct(values, p):
    if not values:
        return 0
    s = sorted(values)
    i = min(int(round((p / 100.0) * (len(s) - 1))), len(s) - 1)
    return s[i]


def report(days):
    if not os.path.exists(CSV_PATH):
        sys.exit(f"no data yet at {CSV_PATH} - run 'fleet-memlog --install' first")
    cutoff = datetime.now() - timedelta(days=days)
    by = {}
    with open(CSV_PATH) as fh:
        for r in csv.DictReader(fh):
            if not r.get("working_set_kb"):
                continue
            try:
                if datetime.fromisoformat(r["ts"]) < cutoff:
                    continue
            except ValueError:
                continue
            key = (r["vmid"], r["name"], r["kind"])
            by.setdefault(key, []).append(r)

    if not by:
        sys.exit(f"no samples in the last {days} days")

    span = "?"
    hours = 0.0
    n_max = max(len(rs) for rs in by.values())
    all_ts = [r["ts"] for rs in by.values() for r in rs]
    if all_ts:
        span = f"{min(all_ts)} -> {max(all_ts)}"
        try:
            hours = (datetime.fromisoformat(max(all_ts))
                     - datetime.fromisoformat(min(all_ts))).total_seconds() / 3600
        except ValueError:
            pass
    print(f"fleet-memlog report   window: last {days}d   samples span: {span}")
    print(f"                      {n_max} samples per guest, covering {hours:.1f} hours\n")

    # A handful of samples over a few hours is not evidence. Say so loudly rather
    # than printing numbers that look authoritative.
    if hours < 120 or n_max < 200:
        print("!! NOT YET ACTIONABLE " + "!" * 56)
        print("!! Too little history. Peaks are what matter, and they arrive when")
        print("!! people actually work: a build, a browser session, a container start.")
        print(f"!! Have: {hours:.1f}h / {n_max} samples.  Want: 120h+ / 200+ samples.")
        print("!! Numbers below are a preview. Do not resize on them.")
        print("!" * 78 + "\n")
    hdr = (f"{'VMID':<6}{'NAME':<16}{'ALLOC':>8}{'PEAK WS':>9}{'P95':>8}"
           f"{'MEDIAN':>8}{'SWAP':>7}{'N':>5}  SUGGESTED")
    print(hdr)
    print("-" * len(hdr))

    total_alloc = total_sugg = 0
    for (vmid, name, kind), rs in sorted(by.items(), key=lambda k: int(k[0][0])):
        # Real demand = what is resident AND what was pushed to swap. A guest that
        # swapped has moved anonymous pages to disk, so its in-RAM working set
        # UNDERSTATES what it actually wanted. Ignoring swap here would recommend
        # shrinking the one guest that is already short, which is backwards.
        dem = [int(r["working_set_kb"]) + int(r["swap_used_kb"] or 0) for r in rs]
        sw = max((int(r["swap_used_kb"] or 0) for r in rs), default=0)
        alloc = int(rs[-1]["alloc_mb"] or 0)
        peak, p95, med = max(dem), pct(dem, 95), pct(dem, 50)

        if kind == "host":
            note = "(host, not resizable)"
            print(f"{vmid:<6}{name:<16}{alloc:>7}M{peak//1024:>8}M{p95//1024:>7}M"
                  f"{med//1024:>7}M{sw//1024:>6}M{len(dem):>5}  {note}")
            continue

        want = int((peak / 1024) * SAFETY)
        want = max(want, FLOOR_MB.get(kind, 2048))
        want = int(round(want / 1024.0)) * 1024 or 1024   # round to whole GB
        # Swapping is hard evidence of shortage: never recommend shrinking such a
        # guest, and give it at least one step up from where it is now.
        if sw > 0:
            want = max(want, alloc + 1024)
        total_alloc += alloc
        total_sugg += want

        if sw > 0:
            verdict = f"{want}M  ** RAISE - it SWAPPED {sw//1024}M, it is short **"
        elif want < alloc:
            verdict = f"{want}M  (could free {alloc - want}M)"
        elif want > alloc:
            verdict = f"{want}M  ** RAISE, peak is close to the limit **"
        else:
            verdict = f"{want}M  (about right)"
        print(f"{vmid:<6}{name:<16}{alloc:>7}M{peak//1024:>8}M{p95//1024:>7}M"
              f"{med//1024:>7}M{sw//1024:>6}M{len(dem):>5}  {verdict}")

    print("-" * len(hdr))
    print(f"guest allocation now {total_alloc}M ({total_alloc/1024:.0f}G),"
          f" suggested {total_sugg}M ({total_sugg/1024:.0f}G),"
          f" difference {total_alloc - total_sugg}M")
    print(f"\nSUGGESTED = peak working set x {SAFETY}, rounded to whole GB,"
          f" floor {FLOOR_MB['qemu']}M for VMs / {FLOOR_MB['lxc']}M for containers.")
    print("Working set = MemTotal - MemAvailable, so page cache is excluded. A guest")
    print("whose SWAP column is 0 was never genuinely short of memory.")
    print("\nSample for at least a full working week before acting: a desktop that")
    print("nobody logged into is not evidence that it can be shrunk.")


UNIT = """[Unit]
Description=Sample working-set memory of every Proxmox guest

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fleet-memlog
"""

TIMER = """[Unit]
Description=Run fleet-memlog every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
"""


def install():
    if os.geteuid() != 0:
        sys.exit("--install needs root")
    open("/etc/systemd/system/fleet-memlog.service", "w").write(UNIT)
    open("/etc/systemd/system/fleet-memlog.timer", "w").write(TIMER)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", "fleet-memlog.timer"], check=True)
    print("installed. timer:")
    subprocess.run(["systemctl", "list-timers", "fleet-memlog.timer", "--no-pager"])
    print(f"\ncsv: {CSV_PATH}\nreport later with:  fleet-memlog --report")


def uninstall():
    if os.geteuid() != 0:
        sys.exit("--uninstall needs root")
    subprocess.run(["systemctl", "disable", "--now", "fleet-memlog.timer"])
    for f in ("/etc/systemd/system/fleet-memlog.timer",
              "/etc/systemd/system/fleet-memlog.service"):
        try:
            os.remove(f)
        except OSError:
            pass
    subprocess.run(["systemctl", "daemon-reload"])
    print(f"removed. {CSV_PATH} left in place.")


if __name__ == "__main__":
    a = sys.argv[1:]
    if "--install" in a:
        install()
    elif "--uninstall" in a:
        uninstall()
    elif "--report" in a:
        d = 7
        if "--days" in a:
            d = int(a[a.index("--days") + 1])
        report(d)
    else:
        rows = sample()
        got = [r for r in rows if r.get("working_set_kb")]
        print(f"{datetime.now().replace(microsecond=0).isoformat()}  "
              f"sampled {len(got)}/{len(rows)} -> {CSV_PATH}")
        for r in rows:
            if not r.get("working_set_kb"):
                print(f"  ! {r['vmid']} {r['name']}: no agent, row left blank")
