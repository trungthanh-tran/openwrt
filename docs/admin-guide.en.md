# sbproxy — Administrator guide

**Language:** English (default) | [Tiếng Việt](admin-guide.md)

> The Vietnamese edition ([admin-guide.md](admin-guide.md)) is the fuller field reference: it keeps the long troubleshooting tables and command transcripts that are summarised here.

> Companion documents: [GUIDE.en.md](GUIDE.en.md), [INSTALL.en.md](INSTALL.en.md), [TESTING.en.md](TESTING.en.md), [ROLLBACK.en.md](ROLLBACK.en.md).

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
| 5–10 | `console/desktop` **Post-flash setup** | One SSH-driven sequence that pushes the code, installs dependencies, pushes the configuration, runs preflight/dry-run/apply, installs the agent, and fetches the token — each step reported live in the app. |
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

    > **Steps 6–10 in one pass** (the whole four-step path is in [QUICKSTART.en.md](QUICKSTART.en.md)): the desktop console's **Post-flash setup…** runs the same sequence over SSH — inspect what the router already has, push the code and `wifi-socks.conf`, install dependencies, run `preflight.sh` and the dry-run, run `apply.sh`, install the agent, read `/etc/sbproxy/token`, and verify `?action=status`. Anything already installed is reused, the run stops at the first failure with the router's own error, and the token is stored on success.
    >
    > On a machine with no repository checkout, carry only `sbproxy-console.exe` — it embeds the matching router package — plus a `sbproxy-update-<version>.tar.gz` when a different version must be installed. See the *Field runbook* section of [../console/desktop/README.md](../console/desktop/README.md).
    >
    > The manual steps below remain authoritative and are what the console automates.
6. **Install:** run `sh scripts/preflight.sh`, resolve its findings, then run `sh scripts/install-deps.sh`.
7. **Configure:** edit `config/wifi-socks.conf` or use the UI, then validate with `DRYRUN=1 sh scripts/apply.sh`.
8. **Apply:** run `DRYRUN=1 sh scripts/apply.sh` first, then `sh scripts/apply.sh`; use `sh scripts/uninstall.sh` to remove project-managed configuration.
9. **Install the local agent:** run `sh agent/install-agent.sh`; rotate its bearer token with `sh scripts/rotate-token.sh`.
10. **Accept:** run `sh scripts/verify.sh`; for a full read-only status report run `sh scripts/doctor.sh`; if either fails, collect evidence with `sh scripts/diagnose.sh`. Client IP, DNS, and WebRTC tests remain browser-side.
11. **Operate:** use `scripts/set-sock.sh` for one upstream and `scripts/backup.sh` for a router snapshot; use `pc/update.*` and `pc/backup.*` from the administration computer.
12. **Roll back:** use `scripts/rollback.sh` on the router or `pc/restore.ps1` / `pc/restore.sh` from the PC. Failsafe and U-Boot remain manual.
13. **Troubleshoot:** run `sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1` before restarting services.
    `sh scripts/gateway.sh` reports the actual default route, link, DNS, and direct HTTP health. It accepts whatever uplink the default route uses; set `GATEWAY_EXPECTED_INTERFACE` in `/etc/sbproxy/env` to enforce one.
14. **Use the LAN API:** `agent/cgi/sbproxy` implements the API and is not run directly. Test it with `TOKEN=$(cat /etc/sbproxy/token); curl -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1/cgi-bin/sbproxy?action=status'`. Device management: `scripts/clients.sh` lists online clients and offline blocklist entries; `scripts/{kick,ban,unban}.sh <idx> <mac>` deauth/ban/unban a device.
15. **Audit security:** run `sh scripts/security-audit.sh`; a nonzero exit indicates findings that require review. It does not rewrite SSH or firewall policy.
16. **Update through the console:** build `dist/sbproxy-update-<version>.tar.gz` with `make package` (or `pc/make-package.sh` / `pc\make-package.ps1`), then upload it from the web console's **⬆ Cập nhật** dialog (`POST ?action=update[&force=1]`, 8 MB default cap via `MAX_UPDATE_BYTES`). `scripts/self-update.sh` rejects path traversal and downgrades (unless forced), backs up as `pre-update`, preserves the live `wifi-socks.conf`, `proxy-pools.conf` and `settings.sh` -- appending to the last only the keys this version introduced that the router never had, with their comment blocks, changing no value already set and naming what it added in the update log -- redeploys the CGI/UI/healthd, and never reloads Wi-Fi by itself. The running version is shown in the console header (`meta.version` from `?action=status`).

**Console builds.** Two independent frontends share the Agent API: the
router-hosted **web** UI and the native Tkinter **desktop** console.

- The desktop app uses no HTML/WebView/WebView2. It dry-runs before Apply, warns
  before important mutations, has the advanced client filters, and supports
  English/Vietnamese with Dark/Light modes.
- It ships as two platform-specific artifacts because PyInstaller does not
  cross-compile: `cd console/desktop; .\build.ps1` → `dist\sbproxy-console.exe`,
  or `sh build.sh` → `dist/sbproxy-console`. Each is self-contained — copy the
  single file and run `.\sbproxy-console.exe` or `./sbproxy-console`.
- The token is stored with DPAPI on Windows and `chmod 600` elsewhere. Config,
  logs, cache, and the bundled runtime live under one home (`SBPROXY_HOME` → a
  `data/` folder beside the executable for portable installs →
  `%LOCALAPPDATA%\sbproxy-console-native`); `--where` prints it.
- Both build scripts embed the matching `sbproxy-update-<version>.tar.gz`, so
  the shipped executable runs **Post-flash setup** without a repository checkout.
- Both consoles show the project version next to the agent version from
  `?action=status`. The desktop console acts on the difference: an older agent is
  offered an in-place upgrade that keeps `wifi-socks.conf` and `settings.sh`, and
  a newer agent puts the console in read-only mode until it is updated.
- For field debugging collect `logs/console.log` with the **Log folder** button,
  or rerun with `--verbose`. Beside it, `logs/audit.log` records each connection
  (router, agent version, sing-box state) and every change pushed to a router
  (apply, SOCKS change, MAC rotation, kick/ban/unban, backup, rollback, agent
  update) with the OS user and the result. Both roll over at midnight, keep
  seven days, and have credentials redacted; anything older is deleted at the
  next start.

See [../console/desktop/README.md](../console/desktop/README.md).

## Installation and acceptance

Follow [INSTALL.en.md](INSTALL.en.md), then complete [TESTING.en.md](TESTING.en.md). Do not bypass preflight, staged validation, or the first dry-run. Set `WIFI_COUNTRY` to the router's real operating country -- it is optional for the tooling, but leaving the radios on a wrong country is a regulatory problem of its own -- and verify radio mapping with `iw`/UCI rather than assuming `radio0` is 2.4 GHz.

## Local agent

```sh
cd /root/sbproxy
sh agent/install-agent.sh
```

Open `http://<router>/sbproxy/` and leave Base URL empty. On the first visit
the page asks you to **create the first admin account**; afterwards log in
with it (change the password in the UI via **🔑 Change password**, or with
`sbproxy-webauth set|show|disable` over SSH — see
[web-console.en.md](web-console.en.md)). A raw token still works under
*Advanced* and for the desktop app. The token is a shared bearer secret with
full control; the web account is one login mapped to it, not a role system.

Rotate a suspected token by deleting it and reinstalling the agent:

```sh
rm /etc/sbproxy/token
sh agent/install-agent.sh
```

Or rotate only the token with `sh scripts/rotate-token.sh`.

## Routing rules

Every destination goes through the proxy unless `config/routing-rules.conf`
says otherwise (copy it from `.example`):

```
action|type|value
direct|domain_suffix|vietcombank.com.vn
block|domain_keyword|doubleclick
direct|ip_cidr|103.0.0.0/8
```

`direct` leaves through the WAN — for a domestic bank, a service that rejects
foreign addresses, or a download that would only waste proxy bandwidth. `block`
rejects it at the router, so every device benefits without installing anything.
`proxy` forces the SSID's proxy, and exists only to carve a narrow exception out
of a broader `direct` rule.

Match by `domain`, `domain_suffix`, `domain_keyword` or `ip_cidr`.

File order is the semantic: first match wins, and every rule here is evaluated
before any inbound is mapped to its outbound — otherwise nothing could be taken
away from the proxy. So the narrow rule goes above the broad one:

```
proxy|domain|api.example.com      # this host keeps the proxy
direct|domain_suffix|example.com  # the rest goes direct
```

`domain*` rules depend on sniffing a name from TLS SNI or an HTTP Host header;
use `ip_cidr` for anything that only ever presents an IP. `apply.sh` and
`preflight.sh` validate the file, and the real one is gitignored because it
reveals which domains and ranges a deployment cares about.

`scripts/traffic.sh --suggest` proposes candidates from live byte counts.

## Proxy pools

By default each Wi-Fi uses one proxy, declared in `wifi-socks.conf`. To give one
Wi-Fi several proxies and spread devices across them, add
`config/proxy-pools.conf`:

```
idx|proxy_type|host|port|user|pass|label
1|socks5|1.2.3.4|1080|user1|pass1|VN-01
1|http|5.6.7.8|8080|||US-02
```

An SSID with no row here behaves exactly as before -- byte for byte the same
generated configuration.

A device is pinned to one slot and **keeps that proxy across reconnections**: an
exit IP that moves around breaks logged-in sessions. Pins live in
`/etc/sbproxy.assign` and are baked into the generated nft file, so a restart
does not lose them.

`POOL_UNASSIGNED` decides what a device that is **not pinned yet** gets.
`default` sends it to the `wifi-socks.conf` proxy, which means every unpinned
device on that SSID shares one exit IP — silently. `block` ends the chain in a
drop instead, and the DNS rule follows the pin map too, so an unpinned device
cannot even resolve; letting it resolve would hand it fake IPs it can never
connect to, which looks broken rather than blocked. The local-net return still
precedes the drop, so DHCP and the device's own gateway keep working. An SSID
with no pool is unaffected.

Which slot a new device gets is `POOL_ASSIGN_POLICY`: `random` (default),
`round-robin`, `least-loaded`, or `sticky-hash`. See the settings table in
[admin-guide.md](admin-guide.md) for the full list of `POOL_*` tunables.

Pinning happens the moment dnsmasq hands out a lease, through
`/usr/libexec/sbproxy-dhcp-assign`. `apply.sh` points `dhcpscript` at it but
**never takes over** a `dhcpscript` that belongs to something else. The
`sbproxy-assignd` daemon is the safety net for devices with static addresses,
for routers where `dhcpscript` is already taken, and for a map that drifted from
the state file after a restart.

```sh
sh scripts/pool.sh list 1
sh scripts/pool.sh replace 1 /tmp/new.txt
sh scripts/assign.sh 1 aa:bb:cc:dd:ee:01 3
sh scripts/rebalance.sh 1 --online --dry-run
```

### The main LAN

Only bridges this project creates (`br-w<idx>`) are proxied, so a wired machine
— or an SSID sharing the main subnet — has no way to be given a proxy. Set
`LAN_PROXY=1` and `br-lan` gets its own chain, fed by the **idx 0** rows of
`proxy-pools.conf`:

```
0|socks5|9.9.9.9|1080|u|p|LAN-01
```

```sh
sh scripts/assign.sh 0 aa:bb:cc:dd:ee:01 auto
```

The LAN has no `wifi-socks.conf` row and so no default proxy: only a pinned
device is proxied. An unpinned one matches no map entry, falls off the end of
the chain, and routes exactly as it did before — DNS included, because the DNS
rule follows the pin map rather than dragging every wired machine off dnsmasq
into fake-IP. `POOL_UNASSIGNED=block` applies here too.

Off by default, so a deployment that already lists an idx 0 row does not
suddenly start proxying its LAN. Set `LAN_BRIDGE` if the board names the bridge
something other than `br-lan`.

> `sock_bypass` is global, not per-SSID. The router must reach a proxy host
> directly or TPROXY would loop it back, and that bypass list is shared, so a
> proxy added to SSID 1's pool is also reachable directly by SSID 2's clients.
> This predates pools; pools just make it visible.

`kmod-nft-socket` is the only new dependency: it enables the divert rule, which
turns a per-packet map lookup into a per-connection one. Without it
`POOL_DIVERT="auto"` simply switches divert off and everything still works,
more slowly.

## UDP through the proxy

`SOCKS_UDP=1` (the default) lets a SOCKS5 outbound relay UDP with UDP
ASSOCIATE, so QUIC, WebRTC media and game traffic reach the Internet carrying
the proxy's address. It is also what makes `webrtc=2` work at all.

Set `SOCKS_UDP=0` when the upstream proxies refuse UDP ASSOCIATE. sing-box
would otherwise accept each UDP flow and blackhole it, so a QUIC attempt has to
time out before the browser falls back to TCP. With it off, nftables drops UDP
443 instead and the fallback is immediate.

QUIC stays blocked wherever UDP cannot be delivered anyway: with `SOCKS_UDP=0`,
and on any SSID that can route a device to an HTTP proxy — including one whose
pool merely contains an HTTP slot — because HTTP proxies have no UDP transport.

```sh
# What the generator decided for one SSID:
nft list chain inet sbproxy w1 | grep -c 'udp dport 443 drop'   # 1 = QUIC blocked here
jq '.outbounds[]|select(.tag=="out-w1")|.network' /etc/sing-box/config.json
# null = UDP relayed; "tcp" = TCP-only
```

## Traffic accounting

`clients.sh` reports how much a device pulled; it cannot say **what** it pulled,
which is the half you need before sending a destination direct. sing-box knows
the host behind every open connection, but only through its stats API.

Set `TRAFFIC_STATS=1` and reapply:

```sh
sh scripts/traffic.sh              # hosts by bytes, largest first
sh scripts/traffic.sh --idx 3      # one SSID only (0 = the main LAN)
sh scripts/traffic.sh --json
sh scripts/traffic.sh --suggest    # routing-rules.conf lines
```

A connection with no sniffed host is reported by destination IP — exactly the
case `ip_cidr` exists for. `--suggest` prints candidates to review, not a config
to paste: sending a host direct exposes the router's real address to it.

Counts cover **open** connections only; sing-box forgets a connection when it
closes, so this is a live picture, not a total since boot.

The API reconfigures sing-box rather than merely reporting on it, so `apply.sh`
refuses a `CLASH_API_LISTEN` bound anywhere but localhost, and the secret is
generated at `/etc/sbproxy/clash-secret` with mode 0600 instead of living in the
committed `settings.sh`. Off by default.

## Operations and recovery

- Use full apply for SSID topology changes.
- Use `set-sock.sh` for a single upstream change.
- Keep off-device snapshots with the PC scripts.
- Follow [ROLLBACK.en.md](ROLLBACK.en.md) when apply or firmware changes fail.
- Run `sh scripts/verify.sh` for router-side acceptance, `sh scripts/doctor.sh` for a full status report, and `sh scripts/diagnose.sh` to collect troubleshooting evidence.
- Run `sh scripts/gateway.sh` or call Agent action `gateway` to inspect the
  actual default route, list every interface the router has, and verify link,
  DNS, and direct HTTP latency. Any uplink is accepted unless one is pinned
  with `set_gateway` (the console's **Egress** dropdown).

## Privacy checklist

- IPv6: disabled on managed SSIDs because the project proxies IPv4 only.
- DNS: port-53 traffic on proxied SSIDs is hijacked into sing-box fake-IP, so SOCKS receives hostnames; DoH/DoT clients bypass the hijack and rely on TLS SNI sniffing.
- WebRTC: `webrtc=1` blocks the listed STUN/TURN ports and `webrtc=2` forces them
  through the proxy so the reflexive candidate is the proxy's address. Both are
  port-based and neither is a universal guarantee; `webrtc=2` also needs a proxy
  that relays UDP.
- Fail-closed: guest zones must never receive a direct guest-to-WAN forwarding rule.
- Logs: never print tokens, Wi-Fi passwords, or SOCKS credentials.

Run `sh scripts/security-audit.sh` for a read-only local-management audit. It reports findings but does not alter SSH or firewall policy.

For access from outside the site, connect to the management LAN through a VPN you control. Do not publish the local agent directly.
