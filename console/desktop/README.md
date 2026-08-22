# sbproxy Console Native

**Language:** English (default) | [Tiếng Việt](README.vi.md)

A standalone Tkinter desktop application that talks to the router Agent API
directly. It uses **no HTML, WebView, or WebView2** — the router-hosted console
at `console/web/control-panel.html` is a separate application over the same API.
Windows is the primary target; the same source builds on Linux and macOS.

Two things it does that the web console cannot: it installs a freshly flashed
router over SSH (**Post-flash setup**), and it runs from a single executable
with no Python and no repository checkout on the operator's machine.

## Features

**Configuration**

- Manage Wi-Fi/SSID and SOCKS5 records, save the configuration, and apply it.
- Add or remove SSIDs; every Apply dry-runs the candidate before saving, and
  the Agent enforces a final dry-run before the router changes state.
- Change one SSID's SOCKS5 endpoint without a full edit.
- Right-click an SSID row for its item actions: edit, change SOCKS, randomize
  MAC, or delete. **Random MAC** then asks for a router vendor/OUI (TP-Link,
  Netgear, ASUS, Xiaomi, Huawei, …); the vendor and new BSSID are persisted.

**Devices**

- List clients and kick, ban, or unban them; offline blocklist entries stay
  visible so they can be unblocked.
- Filter by SSID, IP/name/MAC, band, online state, access state, RSSI, traffic,
  and connection duration. Click any Wi-Fi or Devices column heading to sort;
  click it again to reverse the order.
- Dashboard counters, 5–60 second auto-refresh, per-device details,
  multi-select actions, IP/MAC copy, and UTF-8 CSV export.

**Operations**

- Internet Gateway card: actual route, `wwan`/device, next hop, source IP,
  link, DNS, and HTTP latency; warns when egress bypasses `wwan`.
- Inspect backups, roll back, run health checks, and read the operation log.
- Install or repair a router over SSH from the app — see
  [Post-flash setup](#post-flash-setup).

**Interface and safety**

- Switch live between English/Vietnamese and Dark/Light; preferences persist
  (defaults: English, Dark).
- Chrome-like rounded tabs whose active surface connects to the panel below,
  with distinct idle and hover states in both themes.
- A staged modal loading screen with finite timeouts: 60 s dry-run, 45 s
  save/backup, 120 s apply.
- Important actions state their impact first and default to **No**.
- The fixed edit panel keeps only Edit and Delete; the rest of the
  selection-dependent actions live in the row context menu, and toolbars hold
  only global actions.
- The router URL and token are stored with Windows DPAPI for the current user
  (`chmod 600` on Linux/macOS).

## Post-flash setup

A freshly flashed router carries no sbproxy code, no agent, and no token. Open
**Post-flash setup…** — from the yellow bar shown while no token is stored, or
from the button in the connection row, which is always available — and the
console runs the whole bring-up over SSH, ticking each step in the checklist as
it goes:

1. Check the SSH connection (and report the OpenWrt release).
2. Check what the router already has: code, `wifi-socks.conf`, sing-box, the
   agent CGI, its token, and whether sing-box runs.
3. Push the code to `/root/sbproxy`.
4. Install dependencies (`scripts/install-deps.sh`).
5. Push `config/wifi-socks.conf` — and `config/settings.sh` when selected.
6. Run `scripts/preflight.sh` and `DRYRUN=1 scripts/apply.sh`.
7. Run the initial `scripts/apply.sh` (optional checkbox).
8. Install or update the agent (`agent/install-agent.sh`).
9. Read `/etc/sbproxy/token` and store it like a manually typed token.
10. Call `?action=status` to confirm the agent answers.

**Nothing already working is redone.** Step 2 decides the rest of the run:
dependencies present are not reinstalled, an existing configuration is kept,
and an installed agent with a valid token is left alone — its token is still
read, so the tool opens on it. Tick **Overwrite the configuration already on
the router** or **Reinstall the agent even if it is present** to force either.

The run stops at the first failing step and shows the router's own error, so
the step can be fixed and the run repeated; every finished step is idempotent.
When the last step passes, the wizard closes and the control screens open
against the new token.

**Authentication** uses the local OpenSSH client: an SSH key, a key already
loaded in the agent, or the router password. The password reaches `ssh` through
an askpass helper — never on the command line — and is never written to
`connection.json`. Router address, user, port, and paths are remembered for the
next run.

**Checking before installing.** With a stored token the app connects on launch
and opens the control screens. Without one it quietly probes the stored router
address and puts the answer in the yellow bar: agent healthy, agent up but the
token is wrong, router up without an agent, or unreachable. **Check status**
repeats that on demand and adds the SSH inventory from step 2. Both are
read-only, so a setup run is only started when it is actually needed.

## Version compatibility

The console, the router package it carries, and the agent on the router are one
version. On every connection the console reads `meta.version` from
`?action=status` and acts on the difference:

| Situation | What the console does |
|---|---|
| Same version | Connects normally. |
| No agent yet | The yellow bar offers **Post-flash setup…**, which installs it. |
| Agent older than the console | Offers to upgrade it in place; on **Yes** it uploads its own package to `?action=update`. `scripts/self-update.sh` backs the router up as `pre-update`, **keeps `wifi-socks.conf` and `settings.sh`**, redeploys the CGI/UI/healthd, and never touches Wi-Fi. Declining leaves an **Upgrade the agent** button in the yellow bar. |
| Agent newer than the console | Refuses to drive it: an error explains that a newer console is required, and every mutating action (Apply, SOCKS change, MAC randomization, SSID delete, kick/ban/unban, backup, rollback) is blocked. Reading and status checks still work. |

**Post-flash setup** enforces the same rule over SSH. It reads the router's
`VERSION` before writing anything and refuses to push an older package onto a
newer router; it reinstalls the agent whenever the deployed CGI, health daemon,
or UI differ from the code it just pushed — a version bump alone would otherwise
leave the old CGI serving; and the last step fails if the agent still reports a
different version than the package that was installed.

## Field runbook: the executable plus a `sbproxy-update-*.tar.gz`

The same workflow ships in two forms — pick the one for the machine you are
carrying. **PyInstaller does not cross-compile: a Windows `.exe` cannot run on
Linux and a Linux binary cannot run on Windows**, so build (or fetch) the one
that matches.

| | Windows | Linux / macOS |
|---|---|---|
| File to carry | `sbproxy-console.exe` | `sbproxy-console` (ELF/Mach-O binary) |
| Built by | `.\build.ps1` | `sh build.sh` |
| Start it | `.\sbproxy-console.exe` | `./sbproxy-console` (`chmod +x` once) |
| Token storage | DPAPI, current Windows account | `chmod 600` inside the app home |
| Private home | `%LOCALAPPDATA%\sbproxy-console-native` | `~/.local/share/sbproxy-console-native` |
| Extra requirement | — | a working Tk on the build machine (`python3-tk`) |

Both forms embed the router package matching their own version, so **the single
file installs a router by itself**. Add a `sbproxy-update-<version>.tar.gz` only
to install a version other than the embedded one; build one from a checkout with
`make package`, `sh pc/make-package.sh`, or `.\pc\make-package.ps1` (output in
`dist/`).

What the machine needs either way: the OpenSSH client (`ssh` and `scp`) on
`PATH` and a wired LAN connection to the router. Nothing else — no Python, no
repository checkout, and no `tar`: the embedded package is uploaded as it is and
unpacked by the router. `tar` is only needed on the machine when the payload is
a source checkout that has to be packaged first.

### 1. Check the tool and the package it carries

There is no package file to look after: the executable already contains
`sbproxy-update-<version>.tar.gz` and unpacks it beside its own runtime at
launch. `--where` prints the copy it will push, so the `payload=` line is both
the proof it is there and the version that will be installed.

Windows (PowerShell):

```powershell
ssh -V                           # OpenSSH client must exist on PATH
.\sbproxy-console.exe --where    # home/config/logs/runtime + payload=…-<version>.tar.gz
```

Linux/macOS (shell):

```sh
ssh -V                           # OpenSSH client must exist on PATH
chmod +x ./sbproxy-console       # first run only
./sbproxy-console --where        # home/config/logs/runtime + payload=…-<version>.tar.gz
```

Running from a source checkout instead of a build, `payload=` points at the
checkout, which the app packages on the fly — that is the case that needs `tar`
on the machine.

**Only if you also carry a separate package** (to install a version other than
the embedded one) is there a file to inspect:

```powershell
tar -tzf .\sbproxy-update-0.5.0.tar.gz | Select-Object -First 10   # what it contains
tar -xzOf .\sbproxy-update-0.5.0.tar.gz VERSION                    # which version it is
```

```sh
tar -tzf ./sbproxy-update-0.5.0.tar.gz | head
tar -xzOf ./sbproxy-update-0.5.0.tar.gz VERSION
```

### 2. Check the router before changing anything

Start the app and read the yellow bar, or press **Check status** — both are
read-only, as described above. From a script, `--probe` exits 0 when the stored
token still works.

### 3. Install or repair the router

Open **Post-flash setup…**, then:

| Field | What to enter |
|---|---|
| Router (IP) | `192.168.8.1` on GL.iNet firmware, `192.168.1.1` on vanilla/recovery |
| SSH account / port | `root`, `22` |
| SSH password / key | the router password, or an SSH key (a key needs no password) |
| Router directory | `/root/sbproxy` unless the install lives elsewhere |
| Source folder or `.tar.gz` | leave as-is for the embedded package; browse to a `sbproxy-update-<version>.tar.gz` to install that one instead |
| `wifi-socks.conf` | the configuration to push; leave empty to keep the router's own |
| Overwrite / Reinstall | tick only to replace an existing configuration or agent |

Press **Start setup** and watch the checklist: steps whose work is already done
are marked *Skipped*, a failure stops the run with the router's own error, and a
finished run stores the token and opens the control screens.

To install a different package later, reopen the wizard and pick the new
`.tar.gz`, or point the app at one before launching:

```powershell
$env:SBPROXY_PAYLOAD = "D:\packages\sbproxy-update-0.5.0.tar.gz"
.\sbproxy-console.exe
```

```sh
SBPROXY_PAYLOAD=/srv/packages/sbproxy-update-0.5.0.tar.gz ./sbproxy-console
```

Once a router runs the agent, routine updates no longer need SSH: upload the
same `.tar.gz` from the web console's **Update** dialog (`scripts/self-update.sh`
keeps `wifi-socks.conf` and `settings.sh` and refuses downgrades).

## Command line and environment

| Flag / variable | Effect |
|---|---|
| `--where` | Print the resolved home, config, logs, runtime, and payload paths |
| `--probe` | Exit 0 when the stored token still reaches the agent, 1 otherwise |
| `--where` … `payload=` | The package version this console would install |
| `--provision` | Store `SBPROXY_BASE`/`SBPROXY_TOKEN` and exit (0 on success, 2 without a token) |
| `--verbose` | DEBUG-level logging for this run |
| `SBPROXY_HOME` | Override the private home directory |
| `SBPROXY_PAYLOAD` | Router package or checkout **Post-flash setup** should push |
| `SBPROXY_BASE`, `SBPROXY_TOKEN` | Connection values consumed by `--provision` |

Provision a connection without ever writing the token in plaintext:

```powershell
$env:SBPROXY_BASE = "http://192.168.8.1"
$env:SBPROXY_TOKEN = "<token>"
.\dist\sbproxy-console.exe --provision
.\dist\sbproxy-console.exe --probe
```

```sh
SBPROXY_BASE=http://192.168.8.1 SBPROXY_TOKEN=<token> ./dist/sbproxy-console --provision
./dist/sbproxy-console --probe
```

Requests use `Authorization: Bearer <token>` because uhttpd may discard custom
CGI headers. Only expose the Agent on a management LAN/VLAN, never on the WAN.

## Build

Python 3.9+ with Tkinter is required. PyInstaller does not cross-compile —
build on each target platform.

```powershell
cd console\desktop
.\build.ps1
# -> dist\sbproxy-console.exe
```

```sh
cd console/desktop
sh build.sh
# -> dist/sbproxy-console        (Debian/Ubuntu: sudo apt install python3-tk first)
```

Both scripts embed the router-side package (`sbproxy-update-<version>.tar.gz`,
the same file list as `pc/make-package.sh`) so **Post-flash setup** works from
the executable alone. The package is built in a temp folder outside the
repository and unpacks with the rest of the bundle at launch; `SBPROXY_PAYLOAD`
and the wizard's file picker still take precedence. The generated binary needs
neither Python nor WebView2 on the target PC.

On Linux the POSIX bootloader does not expand `~` or `$HOME`, so the bundled
runtime unpacks to the default temp folder unless an absolute path is given:

```sh
SBPROXY_RUNTIME_TMPDIR=/opt/sbproxy/runtime sh build.sh
```

## Isolated environment

Everything the app writes lives under one private home, so an install never
mixes with other Python environments or with another copy of the app:

```
<home>/config/connection.json   router URL + token (DPAPI on Windows, chmod 600 elsewhere)
<home>/logs/console.log         rotating debug log (1 MB × 5 files)
<home>/cache/                   scratch data
<home>/runtime/                 bundled Python runtime and dependencies (Windows onefile)
```

`<home>` is resolved in this order:

1. `SBPROXY_HOME` (any path you choose).
2. A `data/` folder next to the executable — **portable mode**, ideal for a USB
   stick or a copy-anywhere install; create the folder and the app uses it.
3. Per-user default: `%LOCALAPPDATA%\sbproxy-console-native` on Windows,
   `~/.local/share/sbproxy-console-native` on Linux/macOS.

`--where` prints the resolved paths. A `connection.json` from an older release
is migrated into `config/` automatically on first start.

## Logs

Every agent call (action, size, duration, HTTP/transport errors), background
task, UI log line, and uncaught exception — main thread and workers alike — is
written to `<home>/logs/console.log`, rotated at 1 MB, keeping 5 files.
Credentials (token, Bearer header, Wi-Fi key, SOCKS password) are redacted
before anything is written, so the file is safe to attach to a bug report. The
**Log folder** button in the header opens it; `--verbose` adds DEBUG detail.

## Development and tests

```powershell
cd console\desktop
.\run.ps1          # sh run.sh on Linux/macOS
```

From the repository root, `sh tests/run-all.sh` (or `make test`) runs every
workstation-safe suite: core parsing/filtering/API behavior, UI workflows, the
post-flash provisioning sequence against injected fakes, and — when a display
is available — Tk smoke tests across both languages and themes. See
[the full test matrix](../../docs/TEST-MATRIX.md).
