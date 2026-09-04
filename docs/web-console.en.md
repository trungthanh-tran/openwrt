# The router-hosted web console — login, layout, and the desktop feature map

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

## 1. Login — a dedicated sbproxy account

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

## 2. Screen layout

| Area | Contents |
|---|---|
| **Sidebar — Configuration** | ＋ Add Wi-Fi · ⤓ Import .conf · ⭳ Download wifi-socks.conf · ⭳ Download JSON · ✕ Clear all (browser-side only) |
| **Sidebar — Router** (shown when connected) | ⇪ Push & Apply · 📱 Devices · ⭳ Pull from router · 🗂 Backup/Rollback · 🌐 Egress · ⬆ Update · ⟲ Reset everything |
| **Top bar** | ☰ menu (mobile) · UI/agent version · 👤 account · Live · language · 🔌 Connect · ◐ Theme |
| **Content** | Stat cards (Wi-Fi count, BSSIDs per band, distinct SOCKS, isolation/WebRTC) · Wi-Fi table (health, sparkline, ⚡ change SOCKS, 🩺 diagnose, 🎲 rotate MAC, pool, edit/duplicate/delete) · preview tabs for `wifi-socks.conf` / `sing-box config.json` / `sbproxy.nft` |

## 3. Day-to-day use

### 3.1 Add a Wi-Fi and apply it

1. **＋ Add Wi-Fi** → fill in the name, band, idx, Wi-Fi password (≥ 8
   characters) and the proxy. The **Quick proxy input** field accepts
   `host:port:user:password`; **Parse** splits it into the four fields.
2. Click **🧪 Test proxy** (when connected) to try that proxy **from the
   router** before saving — the answer says why it fails, not just that it did.
3. **Save** → **⇪ Push & Apply**. Three steps, exactly like the desktop app:
   dry-run → write the config → apply. A failed dry-run leaves the running
   configuration **untouched**.

### 3.2 Change a proxy without reloading Wi-Fi

- **⚡** on a Wi-Fi row changes that SSID's SOCKS endpoint (`set_sock`). The
  Wi-Fi is not reloaded; only open sessions may drop.
- **🎲** gives that SSID a new random BSSID/MAC, with a vendor (OUI) choice
  like the desktop app. This Wi-Fi reloads, so **every device on it
  reconnects**.

### 3.3 The proxy pool of one SSID

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

### 3.4 The Devices screen

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

### 3.5 Internet egress

- **Switch egress**: pick an interface — it gets the best metric, every other
  uplink steps behind it, and the network reloads. Wi-Fi and proxies are
  unchanged.
- **📌 Pin** only records which interface is *expected*; nothing on the router
  changes, but if it later drifts to another uplink the health check reports
  the mismatch.
- **Automatic** unpins it again: whatever the default route uses is accepted.

### 3.6 Backup, update, reset

- **🗂 Backup / Rollback**: create a backup (it asks for a label, letters,
  digits and `. _ -` only), **⭳ Download** it to your computer (do this
  **before flashing firmware**), **↩ Restore**.
- **⬆ Update**: upload a `.tar.gz`/`.zip` package. Wi-Fi is not reloaded.
- **⟲ Reset everything**: kick every device, delete every SSID and pool, then
  apply. It reads the real configuration from the router before warning you,
  and only runs after you type `RESET`.

## 4. Feature map: desktop (.exe) ↔ web console

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

## 4. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `403 — no web account yet` (`setup_required`) | The router has no `/etc/sbproxy/webauth`: the page opens the **Create the first admin account** form by itself. If the form does not appear: SSH `sbproxy-webauth set admin`, or use a token under Advanced. |
| `401 — wrong current password` (change password) | Re-enter the password in use; forgotten → SSH `sbproxy-webauth set <user>`. |
| `401 — wrong username or password` | Double-check; the password was printed at agent install time. Forgot it → `sbproxy-webauth set admin`. |
| `429 — too many wrong passwords` | Wait 5 minutes, or SSH and delete `/tmp/sbproxy-weblock`. |
| Plain unstyled page, no polished sidebar | `/www/sbproxy/assets/bootstrap.min.css` is missing — re-run `install-agent.sh` or a self-update. The page still works. |
| `Connection lost … mixed content?` | The page was opened over https. Open `http://<router>/sbproxy/` directly. |
| An old agent has no `login` action | Update the agent (⬆ Update with a token, or `self-update.sh`), or log in with the token. |
