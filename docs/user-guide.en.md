# sbproxy Console — User guide

**Language:** [Tiếng Việt](user-guide.md) | English

The console manages SSIDs, their SOCKS5 upstreams, proxy health, and router snapshots without requiring a command line.

## Open the console

1. Connect through the trusted management LAN.
2. Open `http://<router>/sbproxy/`.
3. Select **Connect router**, leave Base URL empty, and paste the administrator-provided token.
4. A successful connection shows Live status and starts health polling.

## Common operations

- Add or edit an SSID, band, Wi-Fi password, SOCKS endpoint, isolation, and WebRTC setting.
- Use the lightning action to change one SOCKS endpoint without reloading Wi-Fi. Active network sessions may still be interrupted.
- Use full Apply after adding, deleting, or changing multiple SSIDs. Wi-Fi reloads briefly.
- Load the active router configuration before editing from another computer.

## Health display

- Green latency: responsive proxy.
- Yellow latency: slow proxy; monitor or replace it.
- Red failure: endpoint or authentication failed.

## Backup and rollback

Create a snapshot before large changes and download important snapshots to your computer. Router-side snapshots are not sufficient for recovery after erased storage or severe hardware failure.

Rollback overwrites active configuration and reloads services. Create a new snapshot first when possible.

## Token safety

The agent has no per-user accounts. Anyone with the token has full router control. Keep it on a trusted LAN/VPN, never paste it into external websites, and ask the administrator to rotate it if exposure is suspected.
