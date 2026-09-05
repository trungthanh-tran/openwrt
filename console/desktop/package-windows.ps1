# Build and stage the full native Windows management console as a release asset.
param([string]$OutDir)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
if (-not $OutDir) { $OutDir = Join-Path $repo "dist\release" }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$version = (Get-Content (Join-Path $repo "VERSION") -Raw).Trim()
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-SNAPSHOT)?$') {
  throw "Invalid VERSION: '$version'"
}

& (Join-Path $here "build.ps1")
if ($LASTEXITCODE -ne 0) { throw "Desktop Console build failed" }
$builtExe = Join-Path $here "dist\sbproxy-console.exe"
$selfTest = Start-Process -FilePath $builtExe -ArgumentList "--self-test-gui" `
  -PassThru -Wait -WindowStyle Hidden
if ($selfTest.ExitCode -ne 0) { throw "Desktop Console GUI self-test failed: $($selfTest.ExitCode)" }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$standalone = Join-Path $OutDir "sbproxy-console-$version-windows-x64.exe"
Copy-Item -LiteralPath $builtExe -Destination $standalone -Force
Write-Host "DESKTOP STANDALONE COMPLETE: $standalone"
