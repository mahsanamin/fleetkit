# Sizing guest memory, when the guests lie to you

How to find out what a guest actually needs, and why the obvious measurement gives an answer
that is confidently wrong.

## The trap

Give a guest `balloon` = `memory` and there is no reclaim, so its page cache expands until it
fills the whole allocation. Linux treats free RAM as wasted RAM. Within a day, `free`,
`qm status`, and the QEMU process RSS all read close to the allocation for **every** guest,
whether it needed 4 GB or 16 GB.

Measure "used" and you conclude nothing can be given back. That conclusion is an artefact of
how you measured.

## What does not lie

`MemAvailable` in `/proc/meminfo` is the kernel's own estimate of what it could hand to a new
process without swapping. Its complement is what genuinely cannot be reclaimed:

```
working set = MemTotal - MemAvailable
```

Two things matter beyond a single reading:

- **The peak, not the average.** Demand arrives when someone works: a build, a browser session,
  a container starting. A quiet Sunday sample is not evidence a machine can be shrunk.
- **Swap.** A guest that has swapped pushed anonymous pages to disk, so its in-RAM working set
  **understates** what it wanted. Real demand is `working set + swap used`. Miss this and you
  will recommend shrinking the one guest that is already short, which is backwards.

`Committed_AS` is worth recording too, but it counts what processes reserved rather than
touched, so it over-states on anything using a garbage-collected runtime or a large heap.

## Doing it

`proxmox/fleet-memlog.py` samples every running guest, VMs through the guest agent and
containers through `pct exec`, and appends a row per guest to a CSV.

```bash
fleet-memlog                 # one sample
fleet-memlog --install       # systemd timer, every 15 minutes
fleet-memlog --report        # summarise, and suggest a size per guest
fleet-memlog --report --days 14
```

The report suggests `peak demand x 1.5`, rounded to whole GB, with a floor. It refuses to look
authoritative until it has **120 hours and 200 samples** per guest, because a handful of
readings over an afternoon is not a working week, and the whole point is catching the peaks.

A guest that swapped is never recommended for a shrink, whatever its working set says.

## Reading the output

| Column | Means |
|---|---|
| `ALLOC` | what the guest is configured for now |
| `PEAK WS` | highest `working set + swap used` seen in the window |
| `P95` / `MEDIAN` | the distribution, so one spike is visible as a spike |
| `SWAP` | high-water swap. **Any non-zero value is real pressure** |
| `N` | samples in the window. Small N means do not act |

## What it is not

It measures demand, not experience. A desktop can be responsive at its peak working set and
still feel slow because its page cache is thrashing, and this will not show that. If someone
says a machine is slow, believe them over the table.

And it cannot see a burst shorter than the sampling interval. Fifteen minutes catches a working
day's shape; it will miss a sixty-second compile spike.
