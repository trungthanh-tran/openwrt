# sbproxy Console — User guide

**Language:** [Tiếng Việt](user-guide.md) | English

The console manages SSIDs, their SOCKS5 upstreams, proxy health, and router snapshots without requiring a command line.

The console ships in two flavors sharing one interface: the **web build**
(`http://<router>/sbproxy/`) and the **desktop build** (`sbproxy-console.exe`,
a Windows app that reaches `http://<router-ip>` over the LAN without the
mixed-content limit).

## Open the console

1. Connect through the trusted management LAN.
2. Open the console — web: `http://<router>/sbproxy/` (GL-MT6000 default
   `http://192.168.8.1/sbproxy/`); desktop: launch `sbproxy-console.exe`.
3. Select **Connect router** and paste the administrator-provided token. Web
   build opened from the router: leave Base URL empty. Desktop build: set Base
   URL to `http://<router-ip>`.
4. A successful connection shows Live status and starts health polling.

## Common operations

- Add or edit an SSID, band, Wi-Fi password, SOCKS endpoint, isolation, WebRTC,
  and the **spoofed MAC vendor** (dropdown of common Wi-Fi brands; the first 3
  MAC bytes match the vendor, the rest are randomized).
- Use the lightning action to change one SOCKS endpoint without reloading Wi-Fi. Active network sessions may still be interrupted.
- Use full Apply after adding, deleting, or changing multiple SSIDs. Wi-Fi reloads briefly.
- Load the active router configuration before editing from another computer.

## Connected devices

The **Devices** panel lists clients per SSID with MAC, IP/hostname, connection
time, in/out traffic, and signal. **Kick** deauthenticates a device (it may
reconnect); **Ban** blocks a MAC persistently from that SSID (which briefly
reloads that band); **Unban** removes the block.

## Health display

- Green latency: responsive proxy.
- Yellow latency: slow proxy; monitor or replace it.
- Red failure: endpoint or authentication failed.

## Backup and rollback

Create a snapshot before large changes and download important snapshots to your computer. Router-side snapshots are not sufficient for recovery after erased storage or severe hardware failure.

Rollback overwrites active configuration and reloads services. Create a new snapshot first when possible.

## Token safety

The agent has no per-user accounts. Anyone with the token has full router control. Keep it on a trusted LAN/VPN, never paste it into external websites, and ask the administrator to rotate it if exposure is suspected.
