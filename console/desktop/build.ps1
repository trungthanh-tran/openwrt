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

# Embed the router-side package so the .exe alone can provision a freshly
# flashed router (Post-flash setup) without a repository checkout. The package
# is built outside the repo so it never ends up inside its own payload.
$repo = Split-Path -Parent (Split-Path -Parent $here)
$version = (Get-Content (Join-Path $repo "VERSION") -Raw).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid VERSION: '$version'" }
$payloadDir = Join-Path $env:TEMP "sbproxy-console-payload-$PID"
New-Item -ItemType Directory -Force $payloadDir | Out-Null
$payload = Join-Path $payloadDir "sbproxy-update-$version.tar.gz"
tar -czf $payload -C $repo --exclude=node_modules --exclude=__pycache__ --exclude=dist --exclude=build `
  README.md VERSION agent config console docs etc scripts
if ($LASTEXITCODE -ne 0) {
  Remove-Item $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
  throw "Build failed: tar could not create $payload (needs Windows 10+ tar.exe)"
}
Write-Host "Router payload for Post-flash setup: $payload"

try {
  # --runtime-tmpdir keeps the bundled Python runtime and dependencies inside the
  # app's own data folder instead of the shared system temp, so one install never
  # mixes with another environment. Config, logs and cache live beside it.
  python -m PyInstaller --noconfirm --clean --onefile --windowed `
    --name sbproxy-console `
    --runtime-tmpdir "%LOCALAPPDATA%\sbproxy-console-native\runtime" `
    --add-data "$payload;payload" `
    main.py
}
finally {
  Remove-Item $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) {
  throw "Build failed: PyInstaller exited with code $LASTEXITCODE"
}

$exe = Join-Path $here "dist\sbproxy-console.exe"
if (-not (Test-Path $exe)) {
  throw "Build failed: output not found at $exe"
}
Write-Host "BUILD COMPLETE (native): $exe"
Write-Host "The app calls the Agent API directly and uses no HTML/WebView."
Write-Host "Post-flash setup provisions a router from the embedded v$version package."
