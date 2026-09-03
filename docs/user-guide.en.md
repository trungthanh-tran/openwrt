# sbproxy Console — User guide

**Language:** English (default) | [Tiếng Việt](user-guide.md)

> Using the **desktop app** instead of the browser?
> See [desktop-user-guide.en.md](desktop-user-guide.en.md).

> The Vietnamese edition ([user-guide.md](user-guide.md)) is the fuller field reference: it keeps the long troubleshooting tables and command transcripts that are summarised here.

> Technical and administration detail: [admin-guide.en.md](admin-guide.en.md).

The console manages SSIDs, their SOCKS5 upstreams, proxy health, and router snapshots without requiring a command line.

The console has two independent frontends over the same Agent API: the **web
build** (`http://<router>/sbproxy/`) and a native Tkinter **desktop build**.
The desktop build is one self-contained file per platform —
`sbproxy-console.exe` on Windows, `sbproxy-console` on Linux/macOS — and uses no
HTML/WebView/WebView2. It protects the saved token with Windows DPAPI, or with
`chmod 600` on Linux/macOS.

## Open the console

1. Connect through the trusted management LAN.
2. Open the console — web: `http://<router>/sbproxy/` (GL-MT6000 default
   `http://192.168.8.1/sbproxy/`); desktop: launch `sbproxy-console.exe`.
3. Log in and connect. Web build: enter the dedicated sbproxy
   **username/password** (created on the first visit — with no account yet the
   page opens the setup form by itself; the raw token moved under *Advanced* —
   see [web-console.en.md](web-console.en.md)); opened from the router, leave
   Base URL empty. Desktop build: set Base URL to `http://<router-ip>` and
   paste the administrator-provided token.
4. A successful desktop connection loads configuration, clients, backups, and
   sing-box status from the router.

If the desktop app shows a yellow **Router not configured** bar, that router has
no agent or token yet. **Check status** says which of the two is missing without
changing anything; the actual setup is an administrator task
([admin-guide.en.md](admin-guide.en.md)).

The **Internet Gateway** card shows the actual egress interface/device, next
hop, source IP, link, DNS, and direct HTTP latency. Use **Check gateway** when
it reports degraded/down or says the route does not use `wwan`.

## Common operations

- Add or edit an SSID, band, Wi-Fi password, SOCKS endpoint, isolation, WebRTC,
  and the **spoofed MAC vendor** (dropdown of common Wi-Fi brands; the first 3
  MAC bytes match the vendor, the rest are randomized).
- Right-click an SSID row for Edit, Change SOCKS, Random MAC, or Delete. A
  right-click first selects that row, so the action always targets the item
  under the pointer. The fixed edit panel keeps only Edit and Delete.
- Full Apply always dry-runs the candidate first, then backs up, saves, and
  reloads Wi-Fi only when validation passes.
- Load the active router configuration before editing from another computer.

Important mutations show their target and impact before running and default to
**No**. This covers Apply, SOCKS changes, MAC randomization, SSID deletion,
kick/ban/unban, and rollback.

## Connected devices

The **Devices** tab lists online clients and offline blocklist entries with
SSID, band, MAC, IP/hostname, connection time, traffic, and RSSI. Filter by
SSID, band, presence, access state, RSSI, traffic, or duration; search, sort,
multi-select, auto-refresh, inspect details, copy addresses, and export CSV.
Device actions live in the edit panel beside the table (the row context menu is a
Wi-Fi-table feature).
**Kick** deauthenticates a device; **Ban** persists a MAC block; **Unban** also
works for offline blocklist entries.

## Health display

- Green latency: responsive proxy.
- Yellow latency: slow proxy; monitor or replace it.
- Red failure: endpoint or authentication failed.

## Backup and rollback

Create a snapshot before large changes and download important snapshots to your computer. Router-side snapshots are not sufficient for recovery after erased storage or severe hardware failure.

Rollback overwrites active configuration and reloads services. Create a new snapshot first when possible.

## Token safety

The agent has no per-user accounts. Anyone with the token has full router
control. Keep it on a trusted LAN/VPN, never paste it into external websites,
and ask the administrator to rotate it if exposure is suspected. The web build
stores its token in browser storage; the native app stores a DPAPI-encrypted
value bound to the current Windows account.
