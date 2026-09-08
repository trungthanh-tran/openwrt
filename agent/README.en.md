# sbproxy Local Agent — uhttpd CGI and health monitoring

**Language:** [Tiếng Việt](README.md) | English

> The Vietnamese edition ([README.md](README.md)) is the fuller field reference: it keeps the long troubleshooting tables and command transcripts that are summarised here.

The local agent turns the static configuration UI into a LAN-only control panel. It installs a token-protected CGI endpoint, a SOCKS latency daemon, and the self-hosted UI.

## Install

The base project must already be working at `/root/sbproxy`.

```sh
cd /root/sbproxy
sh agent/install-agent.sh
```

Open `http://<router>/sbproxy/`, leave Base URL empty, and paste the generated token.

The desktop console runs this same script over SSH, then reads the token back
for you — see **Post-flash setup** in
[../console/desktop/README.md](../console/desktop/README.md).

## API

All requests require `Authorization: Bearer <token>`. The legacy
`X-SB-Token` header is also accepted when the HTTP server forwards custom CGI
headers.

| Method | Action | Purpose |
|---|---|---|
| GET | `status` | SSIDs, health, and runtime state |
| GET | `get_conf` | Current wifi-socks.conf |
| POST | `save_conf` | Back up and save desired configuration |
| POST | `dryrun_conf` | Dry-run a temporary candidate without saving it |
| POST | `apply` | Enforce a final dry-run, then apply only on success |
| POST | `set_sock` | Change one upstream |
| POST | `rotate_mac` | Optionally select a provider OUI, randomize BSSID/MAC, persist it, and reload the radio |
| GET | `backups` | List snapshots |
| POST | `backup` | Create a snapshot |
| GET | `download_backup` | Download a snapshot |
| POST | `rollback` | Restore a snapshot |
| GET | `health_now` | Run a health probe immediately |
| GET | `gateway` | Actual Internet route, interface/device, link, DNS, direct HTTP latency, and `interfaces[]` — every logical interface the router has (name, device, proto, ipv4, up, default_route, current, proxied) so a console can offer the choice. Any uplink the default route picks is accepted; `egress_problem` names a loop through a proxied SSID bridge, or a mismatch when an interface is pinned |
| POST | `set_gateway` | Pin which interface counts as the uplink: `{"interface":"wan"}`, or `""` for automatic. Stored in `/etc/sbproxy/env`; the name is restricted to `A-Za-z0-9._-` (max 32) because that file is sourced by the agent |
| GET | `debug` | The troubleshooting assistant: one rule-driven pass over the router, answering `{summary, verdict, findings[]}` worst first; each finding names a `fix` (empty when it has to be done by hand) and carries both languages |
| POST | `debug_fix` | Run EXACTLY one named repair: `singbox_restart`, `config_eol`, `bridge_nf`, `apply`, `install_agent`. The id accepts `[a-z_]` only and anything else is refused before the script runs |
| GET | `diagnose_ssid&idx=N` | Walk the data path of one SSID — wifi-iface, bridge address, DHCP leases, bridge-nf, nft table/chain/vmap/tproxy rule, fwmark rule and route table, sing-box process/listener/config, the proxy probe, sing-box log, conntrack — and name the first broken link in `verdict`. `report` is the same as plain text |
| POST | `probe_proxy` | Test one proxy from the router right now: `{"host","port","user"?,"pass"?,"type"?}` → `state`, `curl_exit`, `error`, `hint`, and the tail of the curl transcript (password blanked). Use it when a pool shows `fail` to learn *why* — IP whitelist, bad credentials, curl without SOCKS support |
| POST | `switch_gateway` | Make that interface the real uplink: `{"interface":"wan"}`. The chosen interface gets default-route metric 0, every other uplink is pushed to metric 100, the network is reloaded, and the choice is pinned as with `set_gateway`. Refused when the interface is down, has no default route, or is a proxied SSID bridge |
| GET | `clients` | Online clients and offline blocklist entries with band/RSSI/traffic |
| POST | `kick`, `ban`, `unban` | Deauthenticate a client, or add/remove one MAC in the blocklist |
| POST | `update` | Upload a `sbproxy-update-<version>.tar.gz`; `scripts/self-update.sh` keeps `wifi-socks.conf` and `settings.sh` and refuses downgrades unless `force=1` |
| POST | `uninstall` | Remove the project-managed configuration |

## Adaptive proxy health

New pool proxies are checked by the Web UI before they are saved. The daemon
then caches each slot result: `ok` is checked again after 300 seconds, `slow`
after 120 seconds, and failures retry with 15/30/60/120/300-second backoff.
At most four pool slots are probed per daemon pass. For WebRTC mode `2`, each
SOCKS5 slot must also pass a real UDP ASSOCIATE + STUN exchange. A TCP-good but
UDP-bad slot is shown as `UDP FAIL`, excluded from random assignment, and only
released after a successful UDP probe. A runtime `UDP is not supported by
outbound: out-w<idx>-s<slot>` error quarantines that exact slot immediately.
The checker uses `ucode-mod-socket` and `ucode-mod-struct`, installed by
`install-deps.sh` and reported by `preflight.sh` when missing.
These intervals and `MAX_POOL_PROBES_PER_RUN` can be overridden in
`/etc/sbproxy/env`.

## Security

- LAN or trusted management VPN only; never expose uhttpd/agent to the WAN.
- The bearer token grants full control and has no per-user authorization.
- Open the UI from the router over HTTP to avoid browser mixed-content blocking.
- Rotate a leaked token by removing `/etc/sbproxy/token` and rerunning the installer.
