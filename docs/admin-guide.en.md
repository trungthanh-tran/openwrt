# sbproxy — Administrator guide

**Language:** [Tiếng Việt](admin-guide.md) | English

## Safety baseline

- Keep a wired LAN recovery connection while changing firmware or networking.
- Download backups off-device before firmware upgrades.
- Test one or two SSIDs before scaling up.
- Keep LuCI, SSH, uhttpd, and the agent off the WAN.
- Treat `wifi-socks.conf`, generated sing-box config, backups, and the agent token as secrets.

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

## Operations and recovery

- Use full apply for SSID topology changes.
- Use `set-sock.sh` for a single upstream change.
- Keep off-device snapshots with the PC scripts.
- Follow [ROLLBACK.en.md](ROLLBACK.en.md) when apply or firmware changes fail.

## Privacy checklist

- IPv6: disabled on managed SSIDs because v0.2 proxies IPv4 only.
- DNS: still a known leak risk through dnsmasq.
- WebRTC: port-based STUN/TURN blocking is optional and not a universal guarantee.
- Fail-closed: guest zones must never receive a direct guest-to-WAN forwarding rule.
- Logs: never print tokens, Wi-Fi passwords, or SOCKS credentials.

For access from outside the site, connect to the management LAN through a VPN you control. Do not publish the local agent directly.
