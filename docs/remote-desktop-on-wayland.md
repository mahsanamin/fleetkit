# Remote desktop on Ubuntu with GNOME/Wayland

Everything here was learned by losing two days to it. If you are setting up RDP into an
Ubuntu desktop running GNOME 46 or newer, read this before you start.

## xrdp cannot work

**GNOME on Wayland ships no X11 session.** `/usr/share/xsessions/` does not exist, so xrdp's
Xorg backend has nothing to start. It connects, goes black, and disconnects. Every xrdp
tutorial online predates this and is now wrong.

```bash
ls /usr/share/xsessions/     # No such file or directory  -> X11 is gone
gnome-shell --version        # 46+ -> Wayland only
```

Dead ends, so you don't repeat them:

| Tried | Why it cannot work |
|---|---|
| `WaylandEnable=false` in `/etc/gdm3/custom.conf` | There is no X11 GNOME session to fall back to |
| Stopping `gdm3` and reconnecting | No change |
| `loginctl terminate-session` | The session was already gone and it still failed |

**Use GNOME Remote Desktop** (`gnome-remote-desktop`), which speaks RDP natively over Wayland.

## The credentials MUST be a real Unix account and password

This is the one that costs a whole evening.

```bash
sudo grdctl --system rdp set-credentials    # username = a REAL user, password = its REAL password
```

GRD has two modes and only one of them tolerates invented credentials:

- **Desktop Sharing** shares an already-running session. Arbitrary credentials are fine.
- **Remote Login** (headless, the system daemon) has to **create a login session** after the
  RDP handshake. The credentials must satisfy PAM, or no session is ever created.

With wrong credentials you get authentication, then a redirect to a session that does not
exist, then an endless "connecting" loop:

```
[RDP] Sending server redirection
[ERROR] transport_read_layer: BIO_read retries exceeded
... every 5s: Failed to peek routing token: Cancelled
```

**The tell:** `journalctl --user -u gnome-remote-desktop` is completely empty. That service
never ran, because no session was ever built.

### Test with a cold boot, never a reconnect

A machine with broken RDP credentials **still serves an existing session perfectly**. The
fault only appears when the machine has to build a session from nothing. So:

> Any RDP change is unverified until it has survived a **reboot**.

A reconnect produces a false negative and sends you chasing the wrong thing.

### A password change breaks RDP

GRD stores its **own copy** of the credentials, separate from `/etc/shadow`. Change the Unix
password with `passwd` alone and GRD keeps the old one — remote login stops being able to
create a session. `ubuntu/desk-passwd.sh` exists to change both together, and
`Settings → Users → Password` is the button that will do this to you.

## RDP dies silently and never comes back — install the watchdog

Different fault from the credentials one above, **same "stuck at connecting" symptom**, so it
is easy to misdiagnose as a repeat. Tell them apart by where it fails:

| | Bad credentials | Greeter died |
|---|---|---|
| Log signature | `Sending server redirection`, then routing-token errors | **nothing at all** |
| `journalctl --user -u gnome-remote-desktop` | empty | empty |
| Fails at | after the handshake, creating the session | the **first RDP packet** |
| A raw RDP probe gets | a negotiation reply | **TCP reset** |

### How to tell in one step

Send a real RDP `X.224 Connection Request` and see whether you get a negotiation reply. A
healthy server answers; a stranded one resets the connection:

```bash
sudo desk-rdp-watchdog --check      # "RDP is answering on :3389 — OK NEG_RSP"
```

Run it against a machine you know is working too. Comparing a broken box to a good one is
worth more than an evening of reasoning about either.

### Why it happens

Remote Login is a three-process chain with **no supervisor**:

```
system daemon (owns :3389)  --D-Bus-->  GDM greeter session
                                          `--starts--> gnome-remote-desktop-handover.service
                                        a logged-in session's --handover daemon
```

Nothing watches anything else. When the greeter's `gnome-shell` dies — or a session is
orphaned by an unclean disconnect — the system daemon keeps a stale reference and never
recovers. It accepts your TCP connection, has nowhere to hand it, and closes it with your
bytes unread, which on the wire is a reset. A real occurrence, from the journal:

```
18:45:03  [RDP] Network or intentional disconnect, stopping session
18:45:05  GDM launches a fresh remote-login greeter, starts the handover service
18:45:38  gdm3: Gdm: Child process -NNNNN was already dead.      <- never respawned
19:06+    Could not find routing token on remote_clients list
later     Failed to peek routing token: Cancelled   (every 5s, the client retrying)
```

### The two properties that make this expensive

- **systemd cannot see it.** The unit stays `active (running)` the whole time. Nothing
  crashed, so nothing is restarted and no unit is in a failed state.
- **The failure path logs nothing.** Measured: three RDP probes, zero journal lines. Both
  `systemctl status` and `journalctl` look clean while RDP is 100% dead.

> Neither `systemctl status` nor an empty journal is evidence that RDP works. Only a real RDP
> handshake is.

### Fixing it by hand, and the order that matters

```bash
sudo loginctl terminate-session <id>     # optional: drop an orphaned session
sudo systemctl daemon-reload
sudo systemctl restart gdm               # only if the greeter is dead too
sleep 15                                 # let the new greeter register with GDM
sudo systemctl restart gnome-remote-desktop     # MUST come after gdm is up
```

**Restarting `gdm` alone does not fix it.** The stale system daemon stays paired with the
greeter that was just replaced. Confirmed on a real failure by checking `MainPID`: gdm had
restarted minutes ago while the GRD daemon was still the process from the previous boot,
holding `:3389`. Conversely, if the greeter is healthy and only the daemon is stale,
restarting `gnome-remote-desktop` on its own is enough — and it does not end live sessions,
which is why the watchdog tries that first.

### Standing fix

`ubuntu/desk-rdp-watchdog.sh` does the supervising the stack does not:

```bash
sudo ./desk-rdp-watchdog.sh --install    # probe every 2 min, heal when dead
```

It requires three consecutive failed probes, **never acts while a client is connected**, and
has a cooldown so it cannot thrash. `desk-golden-prep.sh` installs it, so clones inherit it —
a template is a snapshot, so a watchdog added later is absent from every existing clone.

Prove it heals rather than trusting it:

```bash
sudo systemctl stop gnome-remote-desktop && journalctl -t desk-rdp-watchdog -f
```

### Still open: why the greeter's shell dies

A `gnome-shell --mode=gdm` **SEGV** (`code=dumped, status=11/SEGV`) was caught during one
repair, but `systemd-coredump` was not installed so the core could not be read. Install it
ahead of time or this stays a symptom-level fix:

```bash
sudo apt install systemd-coredump    # then: coredumpctl list
```

## The TLS certificate must be owned by the daemon

The service reports `active (running)` while **nothing listens on 3389**, and the log says the
certificate is not configured even though both paths are set. `openssl` writes them as
`root:root`; the daemon runs as `gnome-remote-desktop`.

```bash
sudo install -o gnome-remote-desktop -g gnome-remote-desktop -m 644 cert.pem /etc/gnome-remote-desktop/rdp-tls.crt
sudo install -o gnome-remote-desktop -g gnome-remote-desktop -m 600 key.pem  /etc/gnome-remote-desktop/rdp-tls.key
```

**Verify the socket, not the unit.** `systemctl status` lies here:

```bash
sudo ss -tlnp | grep 3389
```

## Clients are not interchangeable

Tested against the same machine, minutes apart:

| Client | Result |
|---|---|
| **Royal TSX** (FreeRDP plugin) | **Works** |
| Microsoft **Windows App** (macOS) | **Black screen, every time** |
| noVNC via the hypervisor console | Works. Clipboard via the sidebar panel |

GRD authenticates, then **redirects** the client to the real session. Royal TSX follows that
redirect; Microsoft's macOS client does not, and renders black while the server logs
`Sending server redirection` followed instantly by `ERRINFO_LOGOFF_BY_USER`.

If you hand these machines to colleagues, tell them which client to use, or they will report
a broken machine.

## Do NOT remap Ctrl/Cmd for Mac users

The tempting "make it feel like a Mac" setting:

```bash
gsettings set org.gnome.desktop.input-sources xkb-options "['ctrl:swap_lwin_lctl']"
```

**Do not.** FreeRDP already sends Mac ⌘ as **Ctrl**. The swap then turns that arriving Ctrl
into **Super**, so ⌘C does nothing, ⌘V opens the calendar and ⌘A opens Activities. With no
remap at all, ⌘C and ⌘V behave exactly as a Mac user expects.

Two things that make this hard to diagnose:

- **The setting exists at two layers.** Per-user `gsettings`, and system-wide `localectl`
  (`/etc/default/keyboard`). Check both — a remote-login session is not a normal login:
  ```bash
  localectl status; gsettings get org.gnome.desktop.input-sources xkb-options
  ```
- **A reconnect keeps the old keymap.** Reboot to test, or you will conclude your change did
  nothing.

## VNC is not an alternative

GNOME dropped VNC from its remote desktop stack, and `x11vnc`/TigerVNC need an X11 session
this OS does not have. TigerVNC can run its own `Xvnc`, but that is a **second, separate**
desktop rather than the real one.
