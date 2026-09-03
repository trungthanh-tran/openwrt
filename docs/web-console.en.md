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
| **Content** | Stat cards (Wi-Fi count, BSSIDs per band, distinct SOCKS, isolation/WebRTC) · Wi-Fi table (health, sparkline, ⚡ change SOCKS, 🩺 diagnose, edit/duplicate/delete) · preview tabs for `wifi-socks.conf` / `sing-box config.json` / `sbproxy.nft` |

## 3. Feature map: desktop (.exe) ↔ web console

Both fronts talk to the **same agent CGI** on the router, so features are
equivalent except where noted.

| Feature | Desktop (sbproxy-console) | Web (`/sbproxy/`) | Agent action |
|---|---|---|---|
| Connect / authenticate | Token (fetched over SSH during provisioning) | **Dedicated user/pass** (`login`) or a raw token (Advanced) | `login`, `status` |
| Provision a fresh router over SSH (code, deps, agent) | ✅ | ❌ (a desktop/CLI job) | — (SSH) |
| Add / edit / delete / duplicate SSIDs | ✅ | ✅ | — (local) + `save_conf` |
| Import / export `wifi-socks.conf`, JSON | ✅ | ✅ | `get_conf` |
| Push & Apply (validate, then apply) | ✅ | ✅ | `dryrun_conf`, `save_conf`, `apply` |
| Change one SSID's SOCKS without a Wi-Fi reload (⚡) | ✅ | ✅ | `set_sock` |
| Per-SSID health + latency sparkline | ✅ | ✅ | `status` |
| Diagnose one SSID's data path (🩺) | ✅ | ✅ | `diagnose_ssid` |
| Probe one proxy from the router, with the failure reason (🧪) | ✅ (Pool, adding proxies) | ✅ (button in the Add/Edit Wi-Fi form) | `probe_proxy` |
| Devices: list, kick, ban, unban | ✅ | ✅ | `clients`, `kick`, `ban`, `unban` |
| Backup / download a backup / rollback | ✅ | ✅ | `backups`, `backup`, `download_backup`, `rollback` |
| Internet egress: view + switch the uplink | ✅ | ✅ | `gateway`, `switch_gateway` |
| Reset everything (kick all, delete all, apply) | ✅ | ✅ (behaviour parity is tested) | `kick`, `save_pool`, `save_conf`, `apply` |
| Update the agent with a .tar.gz/.zip package | ✅ | ✅ | `update` |
| Rotate MAC/BSSID | ✅ | ❌ (API exists, no UI yet) | `rotate_mac` |
| **Per-SSID proxy pool**: slots, MAC pinning, rebalance | ✅ (Pool screen) | ❌ (pools are only emptied by Reset; no pool UI yet) | `get_pool`, `save_pool`, `assign_proxy`, `rebalance` |
| SSH host-key repair dialog | ✅ | — (the web console does not use SSH) | — |
| VI/EN language, light/dark theme | ✅ | ✅ | — |

The two gaps on the web side (MAC rotate, the Pool screen) already have agent
APIs — only the UI is missing; use the desktop app for those.

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
