# sbproxy — Multi-Wi-Fi to SOCKS5 on OpenWrt (GL-MT6000)

**Language:** [Tiếng Việt](README.md) | English

Create multiple isolated SSIDs on a GL-MT6000 and route each SSID's IPv4 TCP/UDP traffic through a dedicated SOCKS5 upstream. The project includes safe configuration scripts, rollback, a local LAN control panel, and PC-side management tools.

## Status and limitations

- v0.3 is pre-production and requires testing on real hardware.
- OpenWrt 24.10 (`opkg`) and 25.12 (`apk`) are supported; GL.iNet OEM firmware is experimental.
- Only IPv4 is proxied. IPv6 services are disabled on managed SSIDs to prevent bypass.
- Port-53 DNS on managed SSIDs is hijacked into sing-box fake-IP; reverse mapping sends hostnames to the matching SOCKS upstream for remote resolution.
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

The console has two independent frontends over the same Agent API: the
router-hosted **web build** and a native Tkinter **Windows desktop** app. The
desktop app uses no HTML/WebView/WebView2, protects its token with Windows
DPAPI, dry-runs before Apply, warns before important mutations, and includes
advanced client management. Build it with `cd console/desktop; .\build.ps1` —
see [console/desktop/README.en.md](console/desktop/README.en.md).

There is no cloud control. Use a trusted management LAN or self-managed VPN. Never expose LuCI, uhttpd, SSH, or the agent directly to the WAN.

## Documentation

- [Complete guide](docs/GUIDE.en.md)
- [Installation](docs/INSTALL.en.md)
- [Testing](docs/TESTING.en.md)
- [Latest-four-commit debugging handoff (Vietnamese)](docs/DEBUGGING.md)
- [Rollback](docs/ROLLBACK.en.md)
- [Administrator guide](docs/admin-guide.en.md)
- [User guide](docs/user-guide.en.md)
- [PC management](pc/README.en.md)
