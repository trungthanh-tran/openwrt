# build.ps1 — build sbproxy-console.exe from the shared web UI.
# Requires Python 3.9+ on PATH (only to BUILD; end users just run the exe).
# Output: desktop\dist\sbproxy-console.exe  (single file)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$ui = Join-Path $here "..\ui\control-panel.html"
if (-not (Test-Path $ui)) { throw "Không thấy UI nguồn: $ui" }

# Stage the shared UI next to main.py so PyInstaller can bundle it.
Copy-Item $ui (Join-Path $here "control-panel.html") -Force
Write-Host "Đã copy UI từ ui\control-panel.html"

python -m pip install --upgrade -r requirements.txt

python -m PyInstaller --noconfirm --clean --onefile --windowed `
  --name sbproxy-console `
  --add-data "control-panel.html;." `
  main.py

$exe = Join-Path $here "dist\sbproxy-console.exe"
if (Test-Path $exe) {
  Write-Host ""
  Write-Host "XONG: $exe"
  Write-Host "Chạy exe -> bấm 'Kết nối router' -> nhập http://<IP-router> + token."
} else {
  throw "Build thất bại: không thấy $exe"
}
