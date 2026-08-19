# run.ps1 — dev run of the desktop console without building an exe.
# Loads the shared UI (..\web\control-panel.html) in a WebView2 window.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

# Install deps only if pywebview is missing.
python -c "import webview" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Cài dependency lần đầu…"
  python -m pip install -r requirements.txt
}
python main.py
