# sbproxy Console — User guide

**Language:** [Tiếng Việt](user-guide.md) | English

The console manages SSIDs, their SOCKS5 upstreams, proxy health, and router snapshots without requiring a command line.

The console has two independent frontends over the same Agent API: the **web
build** (`http://<router>/sbproxy/`) and a native Tkinter **desktop build**
(`sbproxy-console.exe`). The desktop app uses no HTML/WebView/WebView2 and
protects the saved token with Windows DPAPI.

## Open the console

1. Connect through the trusted management LAN.
2. Open the console — web: `http://<router>/sbproxy/` (GL-MT6000 default
   `http://192.168.8.1/sbproxy/`); desktop: launch `sbproxy-console.exe`.
3. Paste the administrator-provided token and connect. Web
   build opened from the router: leave Base URL empty. Desktop build: set Base
   URL to `http://<router-ip>`.
4. A successful desktop connection loads configuration, clients, backups, and
   sing-box status from the router.

The **Internet Gateway** card shows the actual egress interface/device, next
hop, source IP, link, DNS, and direct HTTP latency. Use **Check gateway** when
it reports degraded/down or says the route does not use `wwan`.

## Common operations

- Add or edit an SSID, band, Wi-Fi password, SOCKS endpoint, isolation, WebRTC,
  and the **spoofed MAC vendor** (dropdown of common Wi-Fi brands; the first 3
  MAC bytes match the vendor, the rest are randomized).
- Select an SSID and use its edit panel for configuration, SOCKS changes,
  provider-based MAC randomization, or deletion.
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
Selection-dependent actions live only in the edit panel beside the table.
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
