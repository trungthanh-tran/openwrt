# COMPLETE GUIDE — sbproxy on GL-MT6000

**Language:** [Tiếng Việt](GUIDE.md) | English

Examples use the GL-MT6000 GL.iNet management default, `192.168.8.1`. OpenWrt vanilla and U-Boot/failsafe may use `192.168.1.1`; confirm the active mode before connecting.

## Deployment flow

1. Back up the existing router configuration to another computer.
2. Confirm the router is a GL-MT6000 and identify whether it runs official OpenWrt or GL.iNet OEM firmware.
3. Copy the repository and configure `wifi-socks.conf` plus `settings.sh`.
4. Set the correct radio mapping and mandatory country code.
5. Run preflight and install dependencies.
6. Run dry-run, inspect generated UCI/sing-box/nftables output, then apply.
7. Complete every check in [TESTING.en.md](TESTING.en.md).
8. Install the optional local LAN agent only after command-line operation is stable.

## Daily operations

```sh
# Change one upstream without reloading Wi-Fi
sh scripts/set-sock.sh IDX HOST PORT [USER] [PASS]

# Apply SSID additions, edits, or removals
sh scripts/apply.sh

# Back up and restore
sh scripts/backup.sh manual
sh scripts/rollback.sh --list
sh scripts/rollback.sh SNAPSHOT
```

Changing an upstream restarts sing-box, so established sessions can disconnect even though Wi-Fi association and DHCP remain intact.

## Known limitations

- IPv4 only; managed SSIDs have IPv6 services disabled.
- DNS on proxied SSIDs is hijacked into sing-box fake-IP (`198.18.0.0/15` by default), so upstream SOCKS servers receive hostnames (remote resolve). Clients using DoH/DoT bypass the port-53 hijack; TLS SNI sniffing is the fallback for that traffic.
- UDP requires an upstream SOCKS5 server that supports UDP ASSOCIATE.
- Real BSSID capacity depends on the driver, firmware, and other radio interfaces.
- GL.iNet OEM firmware requires separate real-device validation.

## Local control

Install `agent/install-agent.sh` and open `http://<router>/sbproxy/`. The token grants full router control and must remain on a trusted management LAN. Remote access is outside project scope; use a self-managed VPN instead of exposing router services to the WAN.

See [installation](INSTALL.en.md), [testing](TESTING.en.md), [rollback](ROLLBACK.en.md), and the [administrator guide](admin-guide.en.md).
