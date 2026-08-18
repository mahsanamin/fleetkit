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
