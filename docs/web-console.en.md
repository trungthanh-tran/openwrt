# The router-hosted web console — bring-up, connecting, updating and daily use

> Vietnamese version: [web-console.md](web-console.md)

The web console is the admin page **served by the router itself** — nothing to
install on the PC, no Internet required:

```
http://<router-ip>/sbproxy/          (e.g. http://192.168.8.1/sbproxy/)
```

- **Light AdminLTE-style** layout: a left sidebar (navigation + actions), a top
  bar (account, Live badge, VI/EN language, light/dark theme), and the content
  area (stat cards, the Wi-Fi table, configuration previews).
- The CSS base is **offline Bootstrap**: `bootstrap.min.css` lives on the
  router at `/www/sbproxy/assets/` — no CDN, so the page renders correctly on a
  router with no Internet. If the assets folder is ever missing, the page still
  works on its own built-in stylesheet.
- The whole page is **one HTML file** (`console/web/control-panel.html` in the
  repo) plus the `assets/` folder. Both `install-agent.sh` and
  `self-update.sh` deploy them to `/www/sbproxy/`.

## 1. Bringing up a router from scratch (5 steps)

This chapter is for people **not using the .exe**: from a freshly flashed
router to an open web console. The desktop console does all of it for you in
one screen — with the exe at hand, [QUICKSTART.en.md](QUICKSTART.en.md) (4
steps) is faster; the commands below are **exactly what the exe runs over
SSH**.

> **Before you start**: connect a **wired LAN** cable from the PC to the
> router (the rescue path if Wi-Fi breaks halfway), and **download a backup**
> if the router is already running something — backups kept on the router are
> lost when it is flashed.

### Step 1 — Flash the firmware and set the root password

Both are manual because they carry physical risk (the wrong image bricks the
router). Follow **steps 2 and 3** of [QUICKSTART.en.md](QUICKSTART.en.md).

This step is done when `ssh root@192.168.8.1` logs in.

> Management IP: GL.iNet firmware defaults to `192.168.8.1`; a freshly flashed
> vanilla OpenWrt is usually `192.168.1.1`. Use the real one below.

### Step 2 — Put the code on the router

From a PC that has this repository:

```sh
sh pc/update.sh --host 192.168.8.1          # Linux/macOS/Git Bash
```
```powershell
pc\update.ps1 -Host 192.168.8.1             # Windows PowerShell
```

This packs the repo, uploads it to `/root/sbproxy` and **preserves**
`wifi-socks.conf` and `settings.sh` if the router already has them.

With only a package file (`sbproxy-update-<version>.tar.gz`):

```sh
scp sbproxy-update-*.tar.gz root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'mkdir -p /root/sbproxy && tar xzf /tmp/sbproxy-update-*.tar.gz -C /root/sbproxy'
```

### Step 3 — Check the hardware (read-only, changes nothing)

```sh
ssh root@192.168.8.1
cd /root/sbproxy
sh scripts/preflight.sh
```

Two lines matter:

- **Radio ↔ band**: if `radio0` is not the 2.4 GHz one, fix `RADIO_2G` /
  `RADIO_5G` in `config/settings.sh`.
- **valid interface combinations**: the real maximum number of APs per radio.
  Plan for that many SSIDs or fewer.

Set the country code in `config/settings.sh` too (required):
`WIFI_COUNTRY="VN"`.

### Step 4 — Install and initialise (3 commands)

```sh
cd /root/sbproxy
# An empty configuration: SSIDs are added from the web console later.
grep '^#' config/wifi-socks.conf.example > config/wifi-socks.conf
sh scripts/install-deps.sh      # nftables, sing-box, ip-full, iw-full… + the init script
sh scripts/apply.sh             # backs up first, then applies
sh agent/install-agent.sh       # CGI + web console + healthd + assignd
```

`install-deps.sh` takes the longest (a few minutes; the router needs Internet
to fetch packages). All four commands are **safe to re-run** — whatever is
already done is skipped.

`install-agent.sh` prints the web console address at the end and says that the
**account will be created on the first visit**.

### Step 5 — Open the web console and create the account

Open `http://192.168.8.1/sbproxy/` → the page opens the **"Create the first
admin account"** form by itself → pick a user (default `admin`) and a password
of at least 8 characters → you land straight in the console.

From here Wi-Fi and proxies are added entirely in the browser: see
[§5.1 Add a Wi-Fi and apply it](#51-add-a-wi-fi-and-apply-it).

### Verifying the install

```sh
sh scripts/doctor.sh        # full read-only status report
```

Join a device to the new SSID and check that `https://ipinfo.io/ip` returns
the proxy's address and `nslookup example.com` answers inside
`198.18.0.0/15` (fake-IP). The full checklist is in
[TESTING.en.md](TESTING.en.md).

### When something breaks

| Symptom | Fix |
|---|---|
| `ssh` will not connect | Wrong IP, no root password set, or SSH disabled. |
| `install-deps.sh` stops fetching packages | The router has no Internet (it needs the WAN). Fix the uplink and re-run. |
| `preflight.sh` reports the wrong radio mapping | Set `RADIO_2G`/`RADIO_5G` in `config/settings.sh` as preflight suggests. |
| `apply.sh` fails | The router **backed up before applying**: `sh scripts/rollback.sh` restores it. See [ROLLBACK.en.md](ROLLBACK.en.md). |
| Networking is lost after applying | Get in over the wired LAN and run `sh scripts/rollback.sh`. |
| Remove everything | `sh scripts/uninstall.sh`. |

## 2. Connecting and logging in — a dedicated sbproxy account

The web console has its **own username/password**, separate from the router's
root account, and no token has to be pasted by hand.

### When is the account created? (first-run setup)

**On the first visit to the web UI.** While the router has no account, the
page opens the **"Create the first admin account"** form by itself (default
user `admin`; password ≥ 8 characters, typed twice) — creating it logs you in
immediately. On the agent side, `setup_account` **only works while no account
exists**: once one is there, every creation attempt is refused (403), so
nobody can "create over" it; the only recovery path is SSH
(`sbproxy-webauth`).

Unattended provisioning can still pre-create the account through environment
variables when running `install-agent.sh`:

```sh
SBPROXY_WEB_USER=admin SBPROXY_WEB_PASS='your-password' sh agent/install-agent.sh
```

### Changing the password

- **In the UI**: 🔌 Connect router → the **🔑 Change password** button (shown
  when connected) → enter the current password and the new one (twice). It
  requires both the logged-in token **and** the current password, so a browser
  that only holds the stored token cannot take over the account. A wrong
  current password is delayed ~1 s and logged to syslog.
- **On the router (SSH)**: `sbproxy-webauth set <user>` — also the recovery
  path for a forgotten password.

### Logging in on the page

Click **🔌 Connect router** → enter **Username / Password** → **Connect**. The
page calls `?action=login`; with the right password the agent returns the API
token, the page stores it in the browser (localStorage), and every later call
uses the token exactly as before. The account name shows in the top bar (👤).

- **Log out** (in the Connect dialog) removes the token and the username from
  the browser; the next person needs the password.
- **Disconnect** only pauses the connection; the token stays remembered.
- **Advanced** keeps the raw Token field (the old way) and the Base URL field
  for opening the page from somewhere other than the router.

### Managing the account on the router (`sbproxy-webauth`)

```sh
sbproxy-webauth set admin          # change the password (prompts on the terminal)
echo 'new-password' | sbproxy-webauth set admin -   # set it through a pipe
sbproxy-webauth show               # print the configured username
sbproxy-webauth disable            # turn password login off (token only)
```

- Storage: `/etc/sbproxy/webauth`, mode `600`, format
  `user:salt:sha256(salt:password)` — **the password itself is never written
  to disk**.
- Passwords must be at least 8 characters.
- **Forgot the password**: SSH to the router and run
  `sbproxy-webauth set admin`; or `sbproxy-webauth disable` and reopen the
  web UI — the page asks to create a new account like on the first run.

### Brute-force protection

- Every wrong password waits ~1 second before answering and logs one line to
  syslog (`logger -t sbproxy`).
- **5 failures within 5 minutes** → `429 Too Many Requests`: login is locked
  (even for the right password) until the window passes. A successful login
  clears the counter.
- `login` is the **only** unauthenticated action; everything else still
  requires `Authorization: Bearer <token>`.

### Security notes

- Only expose the console on the **management LAN**. Never expose the router's
  port 80 to the WAN.
- The page runs over **http** (stock uhttpd). Opening the console from an
  https page makes the browser block calls to the router (mixed content) —
  open `http://<router>/sbproxy/` directly.
- The API token remains the root credential (the desktop app uses it
  directly). To rotate it: delete `/etc/sbproxy/token` and re-run
  `install-agent.sh`.

## 3. Updating

Three update paths; which one you use depends on where you are standing.

### 3.1 From the web console (no SSH)

The normal path for an operator:

1. On a machine with the source, build a package: `make package` (or
   `sh pc/make-package.sh`) → `sbproxy-update-<version>.tar.gz`.
2. Web console → **⬆ Update** → choose the file → **⬆ Update**.

The router **backs up first**, validates the package, **refuses a downgrade**
(unless *Allow version downgrade* is ticked), then replaces the code and
redeploys the CGI, the web UI, `sbproxy-webauth` and healthd.

**Preserved**: `wifi-socks.conf`, `proxy-pools.conf`, `settings.sh` (keys new
to the new version are *added*; your values are never overwritten), the token,
the web account, the blocklist, proxy pins and the device history.

**Updating does NOT reload Wi-Fi.** The configuration only changes when you
press **⇪ Push & Apply** afterwards.

### 3.2 From a PC over SSH

While working on the source and pushing straight to a router:

```sh
sh pc/update.sh --host 192.168.8.1            # upload the code
sh pc/update.sh --host 192.168.8.1 --apply    # upload, then run apply.sh
```

`wifi-socks.conf` and `settings.sh` on the router are preserved by default;
add `--with-settings` only when you really mean to replace `settings.sh`.

If the agent or the web UI does not follow the new code, run
`sh agent/install-agent.sh` on the router again — it leaves the token, the
account and the running configuration alone.

### 3.3 On the router itself

```sh
cd /root/sbproxy
sh scripts/self-update.sh /tmp/sbproxy-update-<version>.tar.gz
```

This is the script the **⬆ Update** button calls, so it behaves exactly like
§3.1.

### After an update

- The top bar shows `v<UI> · agent v<agent>`. When the two differ the line
  turns amber — the browser is still holding the old UI: reload the page
  (Ctrl+F5).
- To be safe: **🗂 Backup / Rollback → 💾 Create a backup now** before
  updating, and **⭳ Download** before a *firmware* upgrade (backups kept on
  the router are lost in a reflash).

## 4. Screen layout

| Area | Contents |
|---|---|
| **Sidebar — Configuration** | ＋ Add Wi-Fi · ⤓ Import .conf · ⭳ Download wifi-socks.conf · ⭳ Download JSON · ✕ Clear all (browser-side only) |
| **Sidebar — Router** (shown when connected) | ⇪ Push & Apply · 📱 Devices · ⭳ Pull from router · 🗂 Backup/Rollback · 🌐 Egress · ⬆ Update · ⟲ Reset everything |
| **Top bar** | ☰ menu (mobile) · UI/agent version · 👤 account · Live · language · 🔌 Connect · ◐ Theme |
| **Content** | Stat cards (Wi-Fi count, BSSIDs per band, distinct SOCKS, isolation/WebRTC) · Wi-Fi table (health, sparkline, ⚡ change SOCKS, 🩺 diagnose, 🎲 rotate MAC, pool, edit/duplicate/delete) · preview tabs for `wifi-socks.conf` / `sing-box config.json` / `sbproxy.nft` |

## 5. Day-to-day use

### 5.1 Add a Wi-Fi and apply it

1. **＋ Add Wi-Fi** → fill in the name, band, idx, Wi-Fi password (≥ 8
   characters) and the proxy. The **Quick proxy input** field accepts
   `host:port:user:password`; **Parse** splits it into the four fields.
2. Click **🧪 Test proxy** (when connected) to try that proxy **from the
   router** before saving — the answer says why it fails, not just that it did.
3. **Save** → **⇪ Push & Apply**. Three steps, exactly like the desktop app:
   dry-run → write the config → apply. A failed dry-run leaves the running
   configuration **untouched**.

### 5.2 Change a proxy without reloading Wi-Fi

- **⚡** on a Wi-Fi row changes that SSID's SOCKS endpoint (`set_sock`). The
  Wi-Fi is not reloaded; only open sessions may drop.
- **🎲** gives that SSID a new random BSSID/MAC, with a vendor (OUI) choice
  like the desktop app. This Wi-Fi reloads, so **every device on it
  reconnects**.

### 5.3 The proxy pool of one SSID

Open it with the **pool** button on a Wi-Fi row.

- **Paste proxies**: one per line. Pick the **provider format** (auto-detect,
  `host:port:user:pass`, `user:pass@host:port`, `host:port`,
  `host,port,user,pass`, `host;port;user;pass`,
  `socks5://user:pass@host:port`) and the proxy type (SOCKS5/HTTP), then **Add
  to the pool**. Lines that cannot be read are listed for you to decide on,
  never silently dropped.
- **Test proxy** tries the whole pool from the router; each slot shows OK/FAIL.
- **Delete the listed slots**: type slot numbers (`0,2,5`). A slot still used
  by an online device is **refused**, exactly as on the desktop, so nobody's
  device is quietly repointed at a different proxy.
- **Delete the pool** empties it entirely.
- **Rebalance clients** spreads this SSID's online devices evenly over the
  slots.

### 5.4 The Devices screen

The list holds **every machine that has ever joined**, not only the ones
associated right now:

| Status | Meaning |
|---|---|
| `active 5m 12s` | Associated now, with the current session's length |
| `idle 2h 15m` | Has joined before, not associated now, with how long ago |
| `blocked` | The MAC is on that SSID's blocklist |

- **Filters**: by Wi-Fi, by status, and a search box (MAC/IP/hostname/SSID).
  Filtering and sorting work on the payload already fetched — no extra router
  calls.
- **Sorting**: click a column header (click again to reverse).
- **Auto refresh**: on/off plus a 5/10/30/60 second interval.
- **Summary line**: shown / online / blocked / total known devices and total
  traffic.
- Per-row buttons: **Disconnect** (temporary, online devices only), **Block**
  (persistent MAC block — reloads that band), **Unblock**, **Proxy** (choose a
  pool slot, or `none` to unpin), **ℹ Details** (IP, hostname, first/last seen,
  signal, traffic, pinned proxy, interface).
- **⛔ Block a MAC…** blocks a MAC that has **never connected**.
- **⭳ Export CSV** exports exactly the rows on screen (UTF-8 with a BOM, so
  Excel does not mangle hostnames).

> **Where does the history come from?** The router records each sighting in
> `/tmp/sbproxy.seen` (RAM, rewritten on every poll, so it never wears the
> flash) and only copies it to `/etc/sbproxy.seen` **when a device appears for
> the first time** — history therefore survives a reboot and a sysupgrade at a
> handful of flash writes per device. The default cap is 400 devices
> (`SEEN_MAX` in `config/settings.sh`); the least recently seen go first.

### 5.5 Internet egress

- **Switch egress**: pick an interface — it gets the best metric, every other
  uplink steps behind it, and the network reloads. Wi-Fi and proxies are
  unchanged.
- **📌 Pin** only records which interface is *expected*; nothing on the router
  changes, but if it later drifts to another uplink the health check reports
  the mismatch.
- **Automatic** unpins it again: whatever the default route uses is accepted.

### 5.6 Backup, update, reset

- **🗂 Backup / Rollback**: create a backup (it asks for a label, letters,
  digits and `. _ -` only), **⭳ Download** it to your computer (do this
  **before flashing firmware**), **↩ Restore**.
- **⬆ Update**: upload a `.tar.gz`/`.zip` package. Wi-Fi is not reloaded.
- **⟲ Reset everything**: kick every device, delete every SSID and pool, then
  apply. It reads the real configuration from the router before warning you,
  and only runs after you type `RESET`.

### 5.7 sing-box not running — how to see it and restart it

sing-box is the proxy engine: when it dies **every proxied Wi-Fi loses the
Internet at once**, even though the WAN is fine and the SSIDs keep
broadcasting. That state used to be visible only inside the Connect dialog;
it now sits **on the main page**, refreshed every 10 seconds:

- The **sing-box card** in the stats row: green *running* / red **NOT
  RUNNING** with a **↻ Restart sing-box** button.
- The **`sing-box ✓` chip** next to the Live badge in the top bar; it turns
  blinking red when sing-box is down. Clicking it re-checks (when running) or
  restarts (when down).

**Restart** (card or chip → confirm) calls `restart_singbox`: the router
re-enables the service flag if the firmware left `enabled=0`, runs
`/etc/init.d/sing-box restart`, then **waits up to 6 seconds for the process
to actually be alive** — the init script's exit code is not trusted. The
result opens in the log box:

| Line | Meaning |
|---|---|
| `Running: yes (pid …)` | It is up. Open sessions on proxied Wi-Fi reconnect. |
| `Service enabled: no` | `/etc/config/sing-box` still has `enabled=0`; the script turned it on — restart once more. |
| `config.json valid: no` | `sing-box check` rejects the config → press **⇪ Push & Apply** to regenerate it. |
| `Hint: install the sing-box package…` | The `sing-box` package is missing → `sh scripts/install-deps.sh` on the router. |
| The `logread -e sing-box` block | The last 15 log lines — the crash reason is usually here (bad proxy, busy port, missing kmod). |

Still down: press **🩺** on a Wi-Fi row (walks every link: service, process,
listening port, config, proxy), or over SSH:

```sh
/etc/init.d/sing-box restart; sleep 3; pgrep -f sing-box
logread -e sing-box | tail -n 30
sh /root/sbproxy/scripts/doctor.sh
```

> **The page never redraws itself wholesale.** Every 10 seconds only the
> *Health* cells, the sing-box chip/card and the version line are updated in
> place; the configuration is compared with the router every 60 seconds and
> **re-rendered only when the text actually differs**.
>
> Both timer-driven tables (Wi-Fi and Devices) are **patched by key**: every row
> carries its own key (Wi-Fi = the local row id, Devices = `idx|MAC`), and a row
> the router reports identically **keeps its DOM node untouched**. Only rows
> that really changed are re-rendered, new ones are inserted in place and gone
> ones removed. So the table does not blink, and **the scroll position, a text
> selection and a checkbox you just ticked all survive** a refresh. Re-sorting
> **moves** the existing nodes rather than re-creating them.

## 6. Feature map: desktop (.exe) ↔ web console

Both fronts talk to the **same agent CGI** on the router, so features are
equivalent except where noted.

| Feature | Desktop (sbproxy-console) | Web (`/sbproxy/`) | Agent action |
|---|---|---|---|
| Connect / authenticate | Token (fetched over SSH during provisioning) | **Dedicated user/pass** (`login`) or a raw token (Advanced) | `login`, `status` |
| Provision a fresh router over SSH (code, deps, agent) | ✅ | ❌ (a desktop/CLI job) | — (SSH) |
| Add / edit / delete / duplicate SSIDs | ✅ | ✅ | — (local) + `save_conf` |
| Import / export `wifi-socks.conf`, JSON | ✅ | ✅ | `get_conf` |
| Push & Apply: dry-run → write → apply | ✅ | ✅ | `dryrun_conf`, `save_conf`, `apply` |
| Change one SSID's SOCKS without a Wi-Fi reload (⚡) | ✅ | ✅ | `set_sock` |
| Rotate MAC/BSSID with a vendor choice (🎲) | ✅ | ✅ | `rotate_mac` |
| Per-SSID health + latency sparkline | ✅ | ✅ | `status` |
| Diagnose one SSID's data path (🩺) | ✅ | ✅ | `diagnose_ssid` |
| Probe one proxy from the router, with the failure reason (🧪) | ✅ | ✅ (Wi-Fi form + whole-pool test) | `probe_proxy` |
| **Proxy pool**: view, add in several provider formats, delete chosen slots, empty it | ✅ | ✅ | `get_pool`, `save_pool` |
| Pool: pin/unpin one device's proxy | ✅ | ✅ (**Proxy** button on the Devices screen) | `assign_proxy` |
| Pool: spread devices evenly over the slots | ✅ (code only) | ✅ (**Rebalance clients**) | `rebalance` |
| Devices: list, kick, ban, unban | ✅ | ✅ | `clients`, `kick`, `ban`, `unban` |
| Devices: history of every machine seen, with status | ✅ | ✅ | `clients` |
| Devices: filter, sort, summary, auto-refresh interval | ✅ | ✅ | — |
| Devices: details of one machine | ✅ | ✅ (**ℹ**) | — |
| Devices: CSV export | ✅ | ✅ | — |
| Devices: block a MAC that never connected | ✅ | ✅ (**⛔ Block a MAC…**) | `ban` |
| Backup (with a label) / download / rollback | ✅ | ✅ | `backups`, `backup`, `download_backup`, `rollback` |
| Egress: view, switch, pin / unpin | ✅ | ✅ | `gateway`, `switch_gateway`, `set_gateway` |
| Reset everything (kick all, delete all, apply) | ✅ | ✅ (behaviour parity is tested) | `kick`, `save_pool`, `save_conf`, `apply` |
| Update the agent with a .tar.gz/.zip package | ✅ | ✅ | `update` |
| VI/EN language, light/dark theme | ✅ | ✅ | — |
| SSH host-key repair, log folder, DPAPI-encrypted token | ✅ | — (does not apply to a browser) | — |

What remains desktop-only is what **cannot work in a browser at all**:
provisioning a router over SSH, encrypting the token with Windows DPAPI,
opening a local log folder, and the command-line modes (`--provision`,
`--probe`). `tests/run.sh` carries a block that pins every "✅" in the web
column above, so removing one of these features turns the suite red.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| **sing-box: NOT RUNNING** card (red), Wi-Fi broadcasts but has no Internet | Press **↻ Restart sing-box** and read the log box (§5.7). Still down → 🩺 diagnose one Wi-Fi, or `logread -e sing-box` over SSH. |
| No sing-box card/chip at all | Not connected (Live badge off), or an old agent: update it (§3). |
| `403 — no web account yet` (`setup_required`) | The router has no `/etc/sbproxy/webauth`: the page opens the **Create the first admin account** form by itself. If the form does not appear: SSH `sbproxy-webauth set admin`, or use a token under Advanced. |
| `401 — wrong current password` (change password) | Re-enter the password in use; forgotten → SSH `sbproxy-webauth set <user>`. |
| `401 — wrong username or password` | Double-check; the password was printed at agent install time. Forgot it → `sbproxy-webauth set admin`. |
| `429 — too many wrong passwords` | Wait 5 minutes, or SSH and delete `/tmp/sbproxy-weblock`. |
| Plain unstyled page, no polished sidebar | `/www/sbproxy/assets/bootstrap.min.css` is missing — re-run `install-agent.sh` or a self-update. The page still works. |
| `Connection lost … mixed content?` | The page was opened over https. Open `http://<router>/sbproxy/` directly. |
| An old agent has no `login` action | Update the agent (⬆ Update with a token, or `self-update.sh`), or log in with the token. |
