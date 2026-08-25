# Quick start with the executable (4 steps)

**Language:** English (default) | [Tiếng Việt](QUICKSTART.md)

The shortest path to a working router: **back up → flash → set the root password
→ run the executable**. The desktop console does the rest — push the code,
install dependencies, push the configuration, run the initial scripts, install
the agent, fetch the token — and opens the control screens when it finishes.

Only the first three steps are manual, because they carry physical risk (losing
the network, bricking the router).

## Before you start

- A **GL-MT6000** with a **wired LAN** cable to your computer (the recovery path
  if Wi-Fi breaks).
- `sbproxy-console.exe` (Windows) or `sbproxy-console` (Linux/macOS) — it
  already contains the router package, so **no repository checkout is needed**.
- An OpenSSH client: run `ssh -V`; Windows 10/11 ships one (otherwise
  *Settings → Apps → Optional features → OpenSSH Client*).
- The SOCKS5 upstreams you will use (host, port, user, password) per Wi-Fi.

---

## Step 1 — Back up to your computer

Backups stored on the router are **lost when you flash**. Pull one off-device
first:

- LuCI: **System → Backup/Flash Firmware → Generate archive** → save the
  `.tar.gz`.
- If the router already runs sbproxy: open `http://<router>/sbproxy/` → the
  **Backup / Rollback** tab → **⭳ Download**.

Note the running release for later comparison: `cat /etc/openwrt_release`.

## Step 2 — Flash the firmware

No script covers this — the wrong image bricks the router:

1. Download the **sysupgrade** image for `GL.iNet GL-MT6000` from
   firmware-selector.openwrt.org and **verify its sha256** against the published
   value: `Get-FileHash .\firmware.bin -Algorithm SHA256`. A mismatch means: do
   not flash.
2. Flash it either way:
   - **U-Boot** (safest when changing firmware family): power off → set your
     computer to `192.168.1.2` → hold Reset while powering on until the LED
     blinks fast → open `http://192.168.1.1` → upload the image → wait for the
     reboot.
   - **GL GUI**: `http://192.168.8.1` → System → Upgrade → Local Upgrade →
     **untick "Keep settings"** when changing firmware family.
3. Wait for the reboot and confirm you can ping the LAN address.

> Management address: GL.iNet firmware defaults to `192.168.8.1`; freshly
> flashed vanilla OpenWrt is usually `192.168.1.1`. Remember the real one for
> step 4.

## Step 3 — Set the root password

The console signs in over SSH with this password (or an SSH key).

- LuCI: **System → Administration → Router Password** → set it → Save.
- Or SSH into the router and run `passwd`.

Confirm from your computer: `ssh root@192.168.8.1` — if you get in, this step is
done.

## Step 4 — Run the executable

1. Start `sbproxy-console.exe` (Linux/macOS: `chmod +x ./sbproxy-console`, then
   `./sbproxy-console`).
2. With no token stored, the app **opens the setup form by itself** on that
   first run. If you closed it, reopen it with **Post-flash setup…** — on the
   yellow **Router not configured** bar or in the top row.
3. Fill in the form:
   - **Router (IP)**: the address from step 2.
   - **SSH account / port**: `root` / `22`.
   - **SSH password**: the one from step 3 (or pick an SSH key).
   - **Source folder or .tar.gz**: **leave it as it is** — the app uses its
     embedded package.
   - **wifi-socks.conf**: leave empty if you do not have one yet; Wi-Fi and
     SOCKS entries are easier to add in the app afterwards. With it empty the
     checklist marks the dry-run and `apply.sh` as *Skipped* — there is nothing
     to apply yet — and still installs the agent and fetches the token.
4. Press **Check status**. The app signs in over SSH and reads what the router
   carries (read-only). If the login works but there is **no agent**, it asks
   right there — *“Install it now?”*:
   - **Yes** → the whole setup runs immediately, no further clicks.
   - **No** → the console shows **ROUTER CANNOT BE CONFIGURED**, dims every
     control, and leaves exactly one button: **Install the agent now**. Press
     it to install; a finished install unlocks the console.
5. Or press **Start setup** directly and watch the checklist: check SSH → inspect what the
   router already has → push the code → install dependencies → push the
   configuration → preflight and dry-run → `apply.sh` → install the agent →
   fetch the token → verify the agent.
6. When it finishes, the wizard closes and the control screens open on the new
   token.

Expect the dependency step to take the longest — a few minutes, depending on the
router's own Internet connection.

---

## After the install

1. In the **Wi-Fi / SOCKS5** tab, add an SSID, fill in its SOCKS5 upstream, and
   press **Push configuration & Apply** (the app dry-runs before it writes).
2. Join a device to the new SSID and check:
   - `https://ipinfo.io/ip` shows the SOCKS egress for that SSID.
   - `nslookup example.com` returns an address in `198.18.0.0/15` (fake-IP).
3. The **Internet Gateway** card shows the real egress route and its latency.

Day-to-day use of the app — adding networks, watching devices, backups — is in
the [desktop console user guide](desktop-user-guide.en.md). The complete
acceptance list is in [TESTING.en.md](TESTING.en.md).

## When something fails

| Symptom | What to do |
|---|---|
| "Check the SSH connection" fails | Wrong address, wrong password, or SSH is off. Run `ssh root@<ip>` yourself to see the real error. |
| Stops at "Install dependencies" | The router has no Internet yet (it downloads packages). Fix the WAN uplink and run it again. |
| Stops at "Run preflight" | Read the router's own message in the log pane. For a radio mismatch, preflight names the value `RADIO_2G`/`RADIO_5G` should have in `config/settings.sh`. |
| Can I run it again? | Yes. Every step is idempotent and anything already done is marked *Skipped*. |
| Reinstall the configuration or agent | Tick **Overwrite the configuration already on the router** or **Reinstall the agent even if it is present**. |
| `Security validation failure: parent process has different executable!` | A bug in the 0.4.3 and older executables. Use **0.4.4** or newer. |
| The app reports a version mismatch | See *Version compatibility* in [../console/desktop/README.md](../console/desktop/README.md). |

Prefer to run each command yourself? See [INSTALL.en.md](INSTALL.en.md) and the
[administrator guide](admin-guide.en.md).
