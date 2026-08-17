# sbproxy Local Agent — uhttpd CGI and health monitoring

**Language:** [Tiếng Việt](README.md) | English

The local agent turns the static configuration UI into a LAN-only control panel. It installs a token-protected CGI endpoint, a SOCKS latency daemon, and the self-hosted UI.

## Install

The base project must already be working at `/root/sbproxy`.

```sh
cd /root/sbproxy
sh agent/install-agent.sh
```

Open `http://<router>/sbproxy/`, leave Base URL empty, and paste the generated token.

## API

All requests require `X-SB-Token: <token>`.

| Method | Action | Purpose |
|---|---|---|
| GET | `status` | SSIDs, health, and runtime state |
| GET | `get_conf` | Current wifi-socks.conf |
| POST | `save_conf` | Back up and save desired configuration |
| POST | `apply` | Run validated apply |
| POST | `set_sock` | Change one upstream |
| GET/POST | `backups`, `backup` | List or create snapshots |
| GET | `download_backup` | Download a snapshot |
| POST | `rollback` | Restore a snapshot |
| GET | `health_now` | Run a health probe immediately |

## Security

- LAN or trusted management VPN only; never expose uhttpd/agent to the WAN.
- The bearer token grants full control and has no per-user authorization.
- Open the UI from the router over HTTP to avoid browser mixed-content blocking.
- Rotate a leaked token by removing `/etc/sbproxy/token` and rerunning the installer.
