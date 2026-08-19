# Build the native Tkinter Windows controller (no HTML and no WebView).
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

python -c "import tkinter; print('Tkinter OK', tkinter.TkVersion)"
python -c "import PyInstaller; print('PyInstaller OK', PyInstaller.__version__)" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Cài dependency build lần đầu..."
  python -m pip install -r requirements.txt
}

python -m PyInstaller --noconfirm --clean --onefile --windowed `
  --name sbproxy-console `
  main.py

$exe = Join-Path $here "dist\sbproxy-console.exe"
if (-not (Test-Path $exe)) {
  throw "Build thất bại: không thấy $exe"
}
Write-Host "XONG (native): $exe"
Write-Host "App gọi trực tiếp Agent API; không dùng HTML/WebView."
