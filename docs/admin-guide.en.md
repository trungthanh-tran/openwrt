# sbproxy — Administrator guide

**Language:** [Tiếng Việt](admin-guide.md) | English

## Safety baseline

- This guide uses the GL-MT6000 GL.iNet management default, `192.168.8.1`. OpenWrt vanilla and recovery mode may use `192.168.1.1`; verify the active LAN address before running commands.
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

## Per-step script examples

1. **Prepare:** on the router, run `sh scripts/inventory.sh > inventory-before.txt`. Cabling and the recovery path remain manual.
2. **Download and verify firmware:** on Windows run `.\pc\verify-firmware.ps1 -File .\firmware.bin -ExpectedSha256 <PUBLISHED-SHA256>`; on Linux/macOS run `sh pc/verify-firmware.sh ./firmware.bin <PUBLISHED-SHA256>`.
3. **Back up off-device:** run `.\pc\backup.ps1 -Label before-fw-upgrade` or `sh pc/backup.sh before-fw-upgrade`; the PC helper creates the router snapshot and downloads it to `pc/backups/`.
4. **Flash firmware:** no script. Image selection, U-Boot/GUI upload, and recovery are intentionally manual because automating them can brick the router.
5. **Reconnect after upgrade:** after SSH works, run `sh scripts/inventory.sh > inventory-after.txt` and compare it with Step 1.
6. **Install:** run `sh scripts/preflight.sh`, resolve its findings, then run `sh scripts/install-deps.sh`.
7. **Configure:** edit `config/wifi-socks.conf` or use the UI, then validate with `DRYRUN=1 sh scripts/apply.sh`.
8. **Apply:** run `DRYRUN=1 sh scripts/apply.sh` first, then `sh scripts/apply.sh`; use `sh scripts/uninstall.sh` to remove project-managed configuration.
9. **Install the local agent:** run `sh agent/install-agent.sh`; rotate its bearer token with `sh scripts/rotate-token.sh`.
10. **Accept:** run `sh scripts/verify.sh`; for a full read-only status report run `sh scripts/doctor.sh`; if either fails, collect evidence with `sh scripts/diagnose.sh`. Client IP, DNS, and WebRTC tests remain browser-side.
11. **Operate:** use `scripts/set-sock.sh` for one upstream and `scripts/backup.sh` for a router snapshot; use `pc/update.*` and `pc/backup.*` from the administration computer.
12. **Roll back:** use `scripts/rollback.sh` on the router or `pc/restore.ps1` / `pc/restore.sh` from the PC. Failsafe and U-Boot remain manual.
13. **Troubleshoot:** run `sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1` before restarting services.
    `sh scripts/gateway.sh` reports the actual default route, expected `wwan`, link, DNS, and direct HTTP health.
14. **Use the LAN API:** `agent/cgi/sbproxy` implements the API and is not run directly. Test it with `TOKEN=$(cat /etc/sbproxy/token); curl -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1/cgi-bin/sbproxy?action=status'`. Device management: `scripts/clients.sh` lists online clients and offline blocklist entries; `scripts/{kick,ban,unban}.sh <idx> <mac>` deauth/ban/unban a device.
15. **Audit security:** run `sh scripts/security-audit.sh`; a nonzero exit indicates findings that require review. It does not rewrite SSH or firewall policy.

**Console builds:** two independent frontends use the same Agent API: the router-hosted **web** UI and a native Tkinter **Windows desktop** `.exe`. The native app uses no HTML/WebView/WebView2, stores its token with DPAPI, dry-runs before Apply, warns before important mutations, and includes advanced client filters. Build it with `cd console/desktop; .\build.ps1` — see [../console/desktop/README.en.md](../console/desktop/README.en.md).

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
- Run `sh scripts/verify.sh` for router-side acceptance, `sh scripts/doctor.sh` for a full status report, and `sh scripts/diagnose.sh` to collect troubleshooting evidence.
- Run `sh scripts/gateway.sh` or call Agent action `gateway` to inspect the
  actual default route, compare it with expected interface `wwan`, and verify
  link, DNS, and direct HTTP latency.

## Privacy checklist

- IPv6: disabled on managed SSIDs because v0.2 proxies IPv4 only.
- DNS: port-53 traffic on proxied SSIDs is hijacked into sing-box fake-IP, so SOCKS receives hostnames; DoH/DoT clients bypass the hijack and rely on TLS SNI sniffing.
- WebRTC: port-based STUN/TURN blocking is optional and not a universal guarantee.
- Fail-closed: guest zones must never receive a direct guest-to-WAN forwarding rule.
- Logs: never print tokens, Wi-Fi passwords, or SOCKS credentials.

Run `sh scripts/security-audit.sh` for a read-only local-management audit. It reports findings but does not alter SSH or firewall policy.

For access from outside the site, connect to the management LAN through a VPN you control. Do not publish the local agent directly.
