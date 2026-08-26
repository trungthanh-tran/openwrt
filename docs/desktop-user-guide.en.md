# Desktop console — User guide

**Language:** English (default) | [Tiếng Việt](desktop-user-guide.md)

How to use the **desktop app** (`sbproxy-console.exe` on Windows,
`sbproxy-console` on Linux/macOS) day to day: open it, connect to the router,
add or edit Wi-Fi networks and their SOCKS5 upstreams, watch connected devices,
take backups. No command line needed.

- Setting up a brand-new router: [QUICKSTART.en.md](QUICKSTART.en.md) (four steps).
- Using the browser console instead: [user-guide.en.md](user-guide.en.md).
- Deeper administration (firmware, scripts, hardening): [admin-guide.en.md](admin-guide.en.md).

---

## 1 · The first launch

There is a **single file** and nothing to install:

- Windows: double-click `sbproxy-console.exe`.
- Linux/macOS: `chmod +x ./sbproxy-console`, then `./sbproxy-console`.

The app remembers the token, so **later launches go straight to the control
screens**. On the first one — no token yet — it **opens the setup form by
itself** and asks for the router's SSH details:

| Field | What goes in |
|---|---|
| **Router (IP)** | The router's LAN address, e.g. `192.168.8.1` |
| **SSH account** | `root` |
| **SSH port** | `22` |
| **SSH password** | The root password set on the router (or pick an SSH key) |
| **Source folder or .tar.gz** | **Leave it alone** — the executable carries its own package |
| **wifi-socks.conf** | Leave empty if you have none; add the networks in the app afterwards |

Then press **Check status**. The app signs in over SSH and reads what the router
already has (**read-only** — it changes nothing), and then:

- **No agent on the router** → it asks *“Install it now?”*
  - **Yes** → the whole sequence runs, the token is fetched, and the control
    screens open.
  - **No** → the app shows **ROUTER CANNOT BE CONFIGURED**, dims every control,
    and leaves a single **Install the agent now** button. Without an agent this
    console genuinely cannot do anything, so that is the only way forward; the
    button reuses the credentials you just typed and installs straight away,
    and a finished install unlocks the console.
- **Agent and token already present** → it says no reinstall is needed; close
  the form and press **Connect**.

> With no `wifi-socks.conf` yet, the console creates an empty one — column
> notes included — and installs normally. Add an SSID in the **Wi-Fi / SOCKS5**
> tab and press **Push configuration & Apply** to finish the router off.

> The SSH password lives only in the running session: it is never written to a
> configuration file, never appears on a command line, and is redacted in logs.

## 2 · Connecting day to day

The top row is always available:

- **Router** — `http://<router-ip>`, e.g. `http://192.168.8.1`.
- **Agent token** — issued by your administrator (filled in automatically after
  an install).
- **Connect** / **Refresh** — reconnect and reload everything from the router.
- **Post-flash setup…** — reopen the setup form at any time (after a reflash,
  for instance).

Once connected, the status bar reports sing-box running and the app shows the
agent version next to its own. A mismatch is handled for you:

- **Agent older than the app** → you are asked whether to upgrade it; on yes a
  window runs it **step by step with a log** (prepare the package, check the
  version, upload, verify the agent), and the router **keeps its Wi-Fi/SOCKS
  configuration**. Any failure stops right at that step and says why; if it
  still will not go through, reinstall over SSH with **Post-flash setup… →
  Reinstall the agent even if it is present**.
- **Agent newer than the app** → the console drops to **read-only** and asks for
  a newer build, so an old console cannot write a format it does not understand.

The **INTERNET GATEWAY** card shows the router's real egress (device, next hop,
source IP), link state, and HTTP latency.

The **Egress** dropdown lists every interface the router has (`wan`, `wwan`,
`lan`, …). It defaults to **Automatic**, which follows whichever interface is
actually reaching the Internet, so there is nothing to set. To enforce one
specific uplink, pick its name; the choice is stored on the router and survives
an agent reinstall. Choosing **Automatic** again removes the pin.

On yellow/red, press **Check gateway** and talk to your administrator before
applying anything else.

## 3 · The Wi-Fi / SOCKS5 tab

This is the main workspace. The table lists each Wi-Fi network with its band,
the SOCKS5 upstream it uses, its isolation mode, and live proxy latency.

| Goal | How |
|---|---|
| Add a network | **+ Add SSID** → name, password, band, SOCKS5 details |
| Edit a network | Double-click the row, right-click → **Edit configuration**, or the **Edit configuration** button in the *selected SSID* strip below the table |
| Swap the SOCKS5 quickly | Right-click → **Change SOCKS** (no need to open the full form) |
| Randomise the MAC | Right-click → **Random MAC** (vendor-shaped address) |
| Delete a network | Select the row → **Delete SSID** (you are asked to confirm) |
| Sort the table | Click a column heading |
| Write it to the router | **Push configuration & Apply** |

**Push configuration & Apply** always dry-runs first: a bad configuration is
reported and **nothing** is written. Every apply takes a backup first, so there
is always a way back from the Backup tab.

After applying, join a device to the new network and check:

- `https://ipinfo.io/ip` shows the matching SOCKS5 egress.
- `nslookup example.com` answers inside `198.18.0.0/15` (fake-IP — which means
  DNS is going through the proxy).

## 4 · The devices tab

See what is connected to each network: MAC, IP, uptime, traffic, signal. The
filters above narrow by SSID, state, band, signal, traffic, or duration.

Select a row, then use the **selected device** strip below:

- **Details** — everything known about that device.
- **Copy IP/MAC** — straight to the clipboard.
- **Kick** — disconnect it; it may come straight back.
- **Ban** — block the MAC for good; the ban list survives every apply and a
  router reboot.
- **Unblock** — remove it from the list.

The toolbar also carries **Block MAC…** (ban an address you type in, online or
not) and **Export CSV** (write the filtered list to a file). Tick **Auto
refresh** to reload on the interval beside it (5s–60s).

## 4.1 · Several proxies on one Wi-Fi

**Viewing and replacing a pool.** On the Wi-Fi tab, select an SSID and press
**Proxy pool…**. The table lists each slot in order together with **how many
devices are on it**. The box below takes a pasted list, one proxy per line:

```
socks5://user:pass@1.2.3.4:1080
http://5.6.7.8:8080
user:pass@9.9.9.9:1080
10.0.0.1:3128:user:pass
10.0.0.2:1080
```

Blank lines and lines starting with `#` are ignored. Anything unreadable is
**listed back with the reason** rather than quietly dropped.

Saving a pool does **not** interrupt Wi-Fi. A device whose proxy is still in the
list **keeps that proxy**, even if its position in the list moved. Only devices
whose proxy is gone are reassigned.

**Changing several devices at once.** On the Devices tab, select the devices
(Ctrl/Shift, or Ctrl+A) and press **Change proxy…**. The dialog shows **which
proxy each device will get**; pressing Apply sends exactly that table, without
recomputing it. The counts differ by at most one.

The button is greyed out when nothing is selected, or when the selected devices
are **not on the same Wi-Fi** -- slots are numbered per Wi-Fi, so one split
cannot span two of them.

**Changing one device.** Right-click a row → **Assign a proxy…** → pick a slot,
or *Do not pin a proxy* to unpin it.

**The Proxy column** shows the proxy's label, or `host:port` when it has none.
Four states, which are worth telling apart:

| Shown | Meaning |
|---|---|
| a name or `host:port` | Pinned, and that proxy still exists |
| `not pinned` | The Wi-Fi has a pool but this device has not been assigned |
| `slot N no longer exists` | The device points past the end of a shortened pool -- **needs attention** |
| `—` | This Wi-Fi does not use a pool |

## 5 · The Backup / Log tab

- **Load list** — refresh the snapshots the router holds.
- **Create backup** — snapshot the current configuration (every apply also takes
  one automatically).
- **Roll back selected backup** — return to the chosen snapshot (you are asked to
  confirm).
- The right-hand column is the session's **operation log**.

> Backups live **on the router** and are lost when the firmware is reflashed. To
> keep a copy on your computer, download it from the web console
> (`http://<router>/sbproxy/` → Backup tab → **⭳ Download**) or use LuCI's
> *Generate archive* before flashing.

## 6 · Language, theme, logs

Top right: switch **Language** (English / Tiếng Việt) and **Theme** (Dark /
Light) — both are remembered.

**Log folder** opens the directory holding two files:

- `console.log` — the technical log. Attach it when reporting a problem.
- `audit.log` — who connected and what was changed: each connection (router,
  agent version, sing-box state) and every change sent to a router (apply,
  SOCKS change, MAC rotation, kick/ban/unban, backup, rollback, agent update)
  with the Windows/Linux user who did it and whether it succeeded.

Both roll over at midnight and **keep seven days**; older files are deleted the
next time the app starts. Tokens and passwords are redacted in both. For more
detail, start the app with `--verbose`; `sbproxy-console --where` prints where
the app keeps its data.

## 7 · When something goes wrong

| Symptom | What to do |
|---|---|
| Yellow **ROUTER NOT CONFIGURED** bar | No token yet, or no agent on the router. Press **Check status** to see which. |
| Red **ROUTER CANNOT BE CONFIGURED** bar | You declined the install. Press **Install the agent now**; the console unlocks itself afterwards. |
| **Check the SSH connection** fails | Wrong address or password, or SSH is off. Run `ssh root@<ip>` yourself to see the real error. |
| Stops at **Install dependencies** | The router cannot reach the Internet to fetch packages. Fix the WAN uplink and run it again. |
| Is re-running the setup safe? | Yes. Every step is idempotent and anything already done is marked *Skipped*. |
| `Security validation failure: parent process has different executable!` | A bug in the 0.4.3 and older executables. Download **0.4.4** or newer. |
| The app reports a version mismatch | See *Version compatibility* in [../console/desktop/README.md](../console/desktop/README.md). |
| Cannot reach the agent | Check that your computer and the router share the management LAN, and that the token is still valid. |

## 8 · Staying safe

- Tokens are per-person: **do not share them**, and do not send screenshots of one.
- On Windows the token is encrypted with DPAPI (only that Windows account can
  read it); on Linux/macOS the token file is `chmod 600`.
- Keep the agent on a **management LAN or VPN** — never expose it to the WAN.
- Wi-Fi and SOCKS5 passwords never appear in the logs.
