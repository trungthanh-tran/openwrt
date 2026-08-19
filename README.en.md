# sbproxy — Multi-Wi-Fi to SOCKS5 on OpenWrt (GL-MT6000)

**Language:** [Tiếng Việt](README.md) | English

Create multiple isolated SSIDs on a GL-MT6000 and route each SSID's IPv4 TCP/UDP traffic through a dedicated SOCKS5 upstream. The project includes safe configuration scripts, rollback, a local LAN control panel, and PC-side management tools.

## Status and limitations

- v0.2 is pre-production and requires testing on real hardware.
- OpenWrt 24.10 (`opkg`) and 25.12 (`apk`) are supported; GL.iNet OEM firmware is experimental.
- Only IPv4 is proxied. IPv6 services are disabled on managed SSIDs to prevent bypass.
- Per-SSID DNS through the matching SOCKS endpoint is not complete; DNS leakage is a known limitation.
- Changing SOCKS keeps Wi-Fi associated, but active sessions may be interrupted when sing-box restarts.

## Architecture

```text
SSID w1 -> br-w1 -> nftables TPROXY :12001 -> sing-box out-w1 -> SOCKS A
SSID w2 -> br-w2 -> nftables TPROXY :12002 -> sing-box out-w2 -> SOCKS B
```

Each SSID has its own bridge, subnet, DHCP scope, firewall zone, stable random MAC, and sing-box inbound/outbound pair.

## Quick start

```sh
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
vi config/wifi-socks.conf
vi config/settings.sh          # set radio mapping and WIFI_COUNTRY
sh scripts/preflight.sh
sh scripts/install-deps.sh
DRYRUN=1 sh scripts/apply.sh | less
sh scripts/apply.sh
```

Change one upstream or restore the newest snapshot:

```sh
sh scripts/set-sock.sh 2 5.6.7.8 1080 user pass
sh scripts/rollback.sh
```

## Local-only operation

- Offline mode edits and previews configuration without contacting a router.
- Live LAN mode uses [the local agent](agent/README.en.md) at `http://<router>/sbproxy/`.

The console ships in two flavors sharing one source (`console/web/control-panel.html`):
the **web build** (router-hosted, same-origin) and the **desktop build** (a
Windows `.exe` via WebView2 that reaches `http://<router-ip>` over the LAN with
no mixed-content limit). Build the desktop app with `cd console/desktop; .\build.ps1`
— see [console/desktop/README.en.md](console/desktop/README.en.md).

There is no cloud control. Use a trusted management LAN or self-managed VPN. Never expose LuCI, uhttpd, SSH, or the agent directly to the WAN.

## Documentation

- [Complete guide](docs/GUIDE.en.md)
- [Installation](docs/INSTALL.en.md)
- [Testing](docs/TESTING.en.md)
- [Rollback](docs/ROLLBACK.en.md)
- [Administrator guide](docs/admin-guide.en.md)
- [User guide](docs/user-guide.en.md)
- [PC management](pc/README.en.md)
