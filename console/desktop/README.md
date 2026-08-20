# sbproxy Console Native for Windows

**Language:** English (default) | [Tiếng Việt](README.vi.md)

This standalone Tkinter desktop application calls the router Agent API
directly. It uses **no HTML, WebView, or WebView2**; the router-hosted console
at `console/web/control-panel.html` remains a separate application.

## Features

- Switch live between English/Vietnamese and Dark/Light themes. Preferences
  persist across launches; the defaults are English and Dark.
- Manage Wi-Fi/SSID and SOCKS5 records, save configuration, and apply it.
- Add/remove SSIDs; every Apply dry-runs the temporary candidate before saving,
  then the Agent enforces a final dry-run before changing router state.
- Show a staged modal loading screen; timeouts are 60 seconds for dry-run, 45
  seconds for save/backup, and 120 seconds for apply.
- Change an SSID's SOCKS5 endpoint without a full edit.
- List clients and kick, ban, or unban them.
- Filter clients by SSID, IP/name/MAC, ban state, and signal strength.
- Advanced filters for band, online/offline state, access state, RSSI range,
  traffic, and connection duration; click any column heading to sort.
- Dashboard counters, 5–60 second auto-refresh, details, multi-select actions,
  IP/MAC copy, and UTF-8 CSV export.
- Internet Gateway card with the actual route, `wwan`/device, next hop, source
  IP, link, DNS, and HTTP latency; warns when egress bypasses `wwan`.
- Keep offline blocklist entries visible so they can be unblocked.
- Selection-dependent actions live in the edit panel beside their table;
  toolbars contain only global actions.
- Important actions show their impact first and default to **No**; they run
  only after explicit confirmation.
- Select a router provider/OUI (TP-Link, Netgear, ASUS, Xiaomi, Huawei, etc.)
  and click **Random MAC**; the provider and new BSSID are persisted.
- Inspect backups, roll back, run health checks, and view operation logs.
- Protect the router URL and token with Windows DPAPI for the current user.

## Build

Python 3.9+ with Tkinter is required. PyInstaller does not cross-compile —
build on each target platform.

Windows:

```powershell
cd console\desktop
.\build.ps1
# -> dist\sbproxy-console.exe
```

Linux/macOS (Debian/Ubuntu: `sudo apt install python3-tk` first):

```sh
cd console/desktop
sh build.sh
# -> dist/sbproxy-console
```

The generated binary does not require Python or WebView2 on the target PC.
On Windows the token is sealed with DPAPI; on Linux/macOS it is stored in
`~/.config/sbproxy-console-native/connection.json` with `chmod 600`.

## Development run

```powershell
cd console\desktop
.\run.ps1
```

## Tests

From the repository root, run `sh tests/run-all.sh` (or `make test`). The
headless suites cover core parsing/filtering/API behavior and critical UI
workflows; `tests/test_desktop_gui.py` additionally exercises every
English/Vietnamese and Dark/Light combination when a display is available.
See [the full test matrix](../../docs/TEST-MATRIX.md).

## Provision a connection

Provision the URL and token without storing the token as plaintext:

```powershell
$env:SBPROXY_BASE = "http://192.168.8.1"
$env:SBPROXY_TOKEN = "<token>"
.\dist\sbproxy-console.exe --provision
.\dist\sbproxy-console.exe --probe
```

Connection data is stored in
`%LOCALAPPDATA%\sbproxy-console-native\connection.json`. The token is encrypted
with DPAPI and can only be decrypted by the current Windows account. Requests
use `Authorization: Bearer <token>` because uhttpd may discard custom CGI
headers.

Only expose the Agent on a management LAN/VLAN, never on the WAN.
