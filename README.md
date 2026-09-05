# sbproxy — Multi-Wi-Fi to SOCKS5 on OpenWrt (GL-MT6000)

**Language:** English (default) | [Tiếng Việt](README.vi.md)

Create multiple isolated SSIDs on a GL-MT6000 and route each SSID's IPv4 TCP/UDP traffic through a dedicated SOCKS5 upstream. The project includes safe configuration scripts, rollback, a local LAN control panel, and PC-side management tools.

## Status and limitations

- 0.4.x is pre-production and requires testing on real hardware; the
  current version is in [VERSION](VERSION) and in the console header.
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

One SSID can also carry several proxies. Each becomes a *slot* with its own
TPROXY port and outbound, and an nftables map sends each device to its own:

```text
                            /-> :13256 -> out-w1s0 -> SOCKS A
SSID w1 -> br-w1 -> map by source address -> :13257 -> out-w1s1 -> SOCKS B
                            \-> :13258 -> out-w1s2 -> SOCKS C
```

A device keeps the proxy it was given across reconnections, and moving one to a
different proxy is a single `nft add element` -- no regenerated configuration,
no restart, no Wi-Fi interruption. See
[proxy pools](docs/admin-guide.en.md#proxy-pools).

## Quick start — the executable

Back up, flash, set the root password, run the app. The desktop console does the
rest over SSH: it pushes the code and configuration, installs the dependencies
and the agent, runs the initial scripts, fetches the token, and opens the
control screens. Nothing else has to be installed on your computer.

**[Follow the four steps →](docs/QUICKSTART.en.md)**

## Quick start — by hand on the router

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
router-hosted **web build** and a native Tkinter **desktop** app. The desktop
app uses no HTML/WebView/WebView2, protects its token with Windows DPAPI (or
`chmod 600` on Linux/macOS), dry-runs before Apply, warns before important
mutations, and includes advanced client management. Its interface supports English and Vietnamese, plus Dark and
Light themes; English is the default.

The desktop app can also bring up a freshly flashed router by itself
(**Post-flash setup**): over SSH it inspects what the router already has, pushes
the code and configuration, installs dependencies and the agent, runs the
initial scripts, then reads the token back and opens the control screens —
reusing anything already installed and reporting every step live. A built
executable embeds the matching router package, so no repository checkout is
needed on the operator's machine.

It ships as two separate artifacts because PyInstaller does not cross-compile:
`console/desktop/dist/sbproxy-console.exe` for Windows (`cd console/desktop;
.\build.ps1`) and `console/desktop/dist/sbproxy-console` for Linux/macOS
(`sh console/desktop/build.sh`). Each one is self-contained — start it with
`.\sbproxy-console.exe` or `./sbproxy-console`. See
[console/desktop/README.md](console/desktop/README.md).

There is no cloud control. Use a trusted management LAN or self-managed VPN. Never expose LuCI, uhttpd, SSH, or the agent directly to the WAN.

## Documentation

**Install**

- [Quick start with the executable](docs/QUICKSTART.en.md) — four steps, no checkout
- [Installation by hand](docs/INSTALL.en.md) — the same work, command by command
- [Complete guide](docs/GUIDE.en.md) — firmware to acceptance in one read

**Operate**

- [Desktop console user guide](docs/desktop-user-guide.en.md) — daily use of the app
- [User guide](docs/user-guide.en.md) — daily use of the browser console
- [Web Deployer guide (Vietnamese, illustrated)](docs/WEB-DEPLOYER.md) — use the Windows standalone EXE or the full platform bundle to inspect, install, and update a router
- [Router-hosted web console](docs/web-console.en.md) — bring up a router from scratch without the .exe, connect, update, daily use, and the desktop ↔ web feature map
- [Administrator guide](docs/admin-guide.en.md) — every step with its script
- [Testing](docs/TESTING.en.md) · [Rollback](docs/ROLLBACK.en.md) · [Debugging](docs/DEBUGGING.en.md)

**Components**

- [Desktop console](console/desktop/README.md) · [Local agent](agent/README.en.md) · [PC management](pc/README.en.md)
- [Automated test matrix](docs/TEST-MATRIX.md)

## Testing

Run every workstation-safe suite with `make test` or `sh tests/run-all.sh`.
This includes the native desktop core/workflows, optional Tk GUI smoke tests,
Agent CGI endpoints, the health daemon, the proxy pool and its assignment
daemon, and OpenWrt generators using isolated router stubs. See the
[automated test matrix](docs/TEST-MATRIX.md).

Those suites check the text the generators produce, not whether a kernel loads
it. [`tests/vm/spike.sh`](tests/vm/README.md) closes that gap by loading real
rules on an OpenWrt VM or on the router. Real-radio acceptance scenarios remain
in [hardware testing](docs/TESTING.en.md).
