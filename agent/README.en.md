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
| GET | `gateway` | Actual Internet route, interface/device, link, DNS, and direct HTTP latency. Any uplink the default route picks is accepted; `egress_problem` names a loop through a proxied SSID bridge, or a mismatch when `GATEWAY_EXPECTED_INTERFACE` pins one interface |
| GET | `clients` | Online clients and offline blocklist entries with band/RSSI/traffic |
| POST | `kick`, `ban`, `unban` | Deauthenticate a client, or add/remove one MAC in the blocklist |
| POST | `update` | Upload a `sbproxy-update-<version>.tar.gz`; `scripts/self-update.sh` keeps `wifi-socks.conf` and `settings.sh` and refuses downgrades unless `force=1` |
| POST | `uninstall` | Remove the project-managed configuration |

## Security

- LAN or trusted management VPN only; never expose uhttpd/agent to the WAN.
- The bearer token grants full control and has no per-user authorization.
- Open the UI from the router over HTTP to avoid browser mixed-content blocking.
- Rotate a leaked token by removing `/etc/sbproxy/token` and rerunning the installer.
