# Build the focused sbproxy Web installer/updater for Windows.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$desktop = Join-Path $repo "console\desktop"
Push-Location $here
try {

python -c "import tkinter; import PyInstaller; print('Build dependencies OK')"
if ($LASTEXITCODE -ne 0) {
  python -m pip install -r (Join-Path $here "requirements.txt")
}

$version = (Get-Content (Join-Path $repo "VERSION") -Raw).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-SNAPSHOT)?$') {
  throw "Invalid VERSION: '$version'"
}
$payloadDir = Join-Path $env:TEMP "sbproxy-web-deployer-payload-$PID"
$payload = Join-Path $payloadDir "sbproxy-update-$version.tar.gz"
New-Item -ItemType Directory -Force $payloadDir | Out-Null
tar -czf $payload -C $repo --exclude=node_modules --exclude=__pycache__ --exclude=dist --exclude=build `
  README.md VERSION agent config console docs etc scripts
if ($LASTEXITCODE -ne 0) {
  Remove-Item -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
  throw "Could not create the embedded router package"
}

try {
  python -m PyInstaller --noconfirm --clean --onefile --windowed `
    --name sbproxy-web-deployer `
    --specpath $payloadDir `
    --runtime-tmpdir "%LOCALAPPDATA%\sbproxy-web-deployer\runtime" `
    --paths $desktop `
    --add-data "$payload;payload" `
    web_deployer.py
}
finally {
  Remove-Item -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed: $LASTEXITCODE" }
$exe = Join-Path $here "dist\sbproxy-web-deployer.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Output not found: $exe" }
Write-Host "BUILD COMPLETE: $exe"
}
finally {
  Pop-Location
}
