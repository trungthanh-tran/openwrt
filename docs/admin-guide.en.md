# sbproxy — Administrator guide

**Language:** [Tiếng Việt](admin-guide.md) | English

## Safety baseline

- Keep a wired LAN recovery connection while changing firmware or networking.
- Download backups off-device before firmware upgrades.
- Test one or two SSIDs before scaling up.
- Keep LuCI, SSH, uhttpd, and the agent off the WAN.
- Treat `wifi-socks.conf`, generated sing-box config, backups, and the agent token as secrets.

## Script coverage by guide step

| Step | Script | Scope |
|---|---|---|
| 1, 5 | `scripts/inventory.sh` | Read-only release, board, radio, storage, and address inventory. |
| 2 | `pc/verify-firmware.ps1` or `pc/verify-firmware.sh` | Compare the firmware SHA-256 with the vendor-published value. Image selection remains manual. |
| 3 | `pc/backup.ps1` / `pc/backup.sh`, `scripts/backup.sh` | Create and download off-device backups. |
| 4 | — | Flashing and U-Boot recovery are physical, high-risk operations and are intentionally not automated. |
| 6 | `scripts/preflight.sh`, `scripts/install-deps.sh` | Inspect hardware and install dependencies. |
| 7, 8 | `scripts/apply.sh`, `scripts/uninstall.sh` | Validate/apply or remove project-managed configuration. |
| 9 | `agent/install-agent.sh`, `scripts/rotate-token.sh` | Install the local agent and rotate its token. |
| 10 | `scripts/verify.sh` | Router-side acceptance checks; browser leak tests remain client-side. |
| 11 | `scripts/set-sock.sh`, `scripts/backup.sh` | Routine SOCKS changes and snapshots. |
| 12 | `scripts/rollback.sh`, `pc/restore.ps1` / `pc/restore.sh` | Roll back or restore snapshots; failsafe/U-Boot remains manual. |
| 13 | `scripts/diagnose.sh` | Collect diagnostic evidence without restarts or mutations. |
| 14 | `agent/cgi/sbproxy` | Implements the LAN API used by the UI. |
| 15 | `scripts/security-audit.sh` | Read-only secret-permission, SSH, and management-exposure audit. |

Run router scripts from `/root/sbproxy`. Inventory and audit helpers intentionally do not apply automatic fixes that could lock an administrator out.

## Installation and acceptance

Follow [INSTALL.en.md](INSTALL.en.md), then complete [TESTING.en.md](TESTING.en.md). Do not bypass preflight, staged validation, or the first dry-run. Set `WIFI_COUNTRY` to the router's real operating country and verify radio mapping with `iw`/UCI rather than assuming `radio0` is 2.4 GHz.

## Local agent

```sh
cd /root/sbproxy
sh agent/install-agent.sh
```

Open `http://<router>/sbproxy/`, leave Base URL empty, and supply `/etc/sbproxy/token`. The token is a shared bearer secret with full control; there are no per-user accounts or roles.

Rotate a suspected token by deleting it and reinstalling the agent:

```sh
rm /etc/sbproxy/token
sh agent/install-agent.sh
```

Or rotate only the token with `sh scripts/rotate-token.sh`.

## Operations and recovery

- Use full apply for SSID topology changes.
- Use `set-sock.sh` for a single upstream change.
- Keep off-device snapshots with the PC scripts.
- Follow [ROLLBACK.en.md](ROLLBACK.en.md) when apply or firmware changes fail.
- Run `sh scripts/verify.sh` for router-side acceptance and `sh scripts/diagnose.sh` to collect troubleshooting evidence.

## Privacy checklist

- IPv6: disabled on managed SSIDs because v0.2 proxies IPv4 only.
- DNS: still a known leak risk through dnsmasq.
- WebRTC: port-based STUN/TURN blocking is optional and not a universal guarantee.
- Fail-closed: guest zones must never receive a direct guest-to-WAN forwarding rule.
- Logs: never print tokens, Wi-Fi passwords, or SOCKS credentials.

Run `sh scripts/security-audit.sh` for a read-only local-management audit. It reports findings but does not alter SSH or firewall policy.

For access from outside the site, connect to the management LAN through a VPN you control. Do not publish the local agent directly.
