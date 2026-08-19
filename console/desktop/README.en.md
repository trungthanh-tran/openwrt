# sbproxy Console — Desktop build (.exe for Windows)

**Language:** [Tiếng Việt](README.md) | English

The same interface as the [web build](../web/control-panel.html), packaged as a
Windows app (`.exe`) using WebView2. Key differences:

| | Web build (router-hosted) | Desktop build (.exe) |
|---|---|---|
| Runs at | `http://<router>/sbproxy/` (installed by `agent/install-agent.sh`) | the admin's Windows machine |
| Reaching the agent | same-origin (no URL needed) | enter `http://<router-ip>` in "Connect router" |
| Mixed content | Blocked when opened over **https** → must open over http from the router | **Not blocked** — calls the router over http on the LAN directly |
| Updating | recopy the HTML | rebuild the exe |

> Both builds share **one source file**, `console/web/control-panel.html`. Edit the UI
> there; the web build copies it as-is, the desktop build repackages it
> (`build.ps1` copies it automatically).

## Requirements
- **To build:** Python 3.9+ on PATH.
- **To run the exe:** Windows 10/11 with the **Microsoft Edge WebView2
  Runtime** (preinstalled on most Win10/11; otherwise grab the "Evergreen
  Standalone Installer" from Microsoft's WebView2 page).

## Build
```powershell
cd desktop
.\build.ps1
# -> desktop\dist\sbproxy-console.exe  (single file)
```

## Dev run (no build)
```powershell
cd desktop
python -m pip install -r requirements.txt
python main.py
```

## Use
1. Launch `sbproxy-console.exe`.
2. Click **🔌 Connect router**, enter `http://<router-ip>` (e.g.
   `http://192.168.8.1`) and the **token** printed by `install-agent.sh`.
3. Everything else matches the web build: add/remove Wi-Fi, push & apply, view
   devices, kick/ban, backup/rollback.

The token and URL are stored under `%USERPROFILE%\.sbproxy-console` and reused
on the next launch.

## Security
- Only connect to routers on the **management LAN/VLAN**. Never expose the
  agent to the WAN.
- Keep the token secret; rotate it by removing `/etc/sbproxy/token` on the
  router and rerunning `install-agent.sh`.
