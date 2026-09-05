# Build the portable Windows Web Deployer executable.
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
if ($LASTEXITCODE -ne 0) { throw "Windows executable build failed" }
$builtExe = Join-Path $here "dist\sbproxy-web-deployer.exe"
$selfTest = Start-Process -FilePath $builtExe -ArgumentList "--self-test-gui" `
  -PassThru -Wait -WindowStyle Hidden
if ($selfTest.ExitCode -ne 0) { throw "Windows executable self-test failed: $($selfTest.ExitCode)" }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$standalone = Join-Path $OutDir "sbproxy-web-deployer-$version-windows-x64.exe"
Copy-Item -LiteralPath $builtExe -Destination $standalone -Force
Write-Host "STANDALONE COMPLETE: $standalone"

$bundleName = "sbproxy-web-deploy-$version-windows-x64"
$stageRoot = Join-Path $env:TEMP "sbproxy-web-deploy-release-$PID"
$bundleDir = Join-Path $stageRoot $bundleName
$archive = Join-Path $OutDir "$bundleName.zip"
New-Item -ItemType Directory -Force $bundleDir | Out-Null
try {
  Copy-Item -LiteralPath $builtExe -Destination (Join-Path $bundleDir "sbproxy-web-deployer.exe")
  Copy-Item -LiteralPath (Join-Path $here "PACKAGE-README.md") -Destination (Join-Path $bundleDir "README.md")
  Copy-Item -LiteralPath (Join-Path $repo "docs\WEB-DEPLOYER.md") -Destination $bundleDir
  Copy-Item -LiteralPath (Join-Path $repo "docs\WEB-DEPLOY.md") -Destination $bundleDir
  Copy-Item -LiteralPath (Join-Path $repo "docs\RELEASE-ARTIFACTS.md") -Destination $bundleDir
  Copy-Item -LiteralPath (Join-Path $repo "docs\images") -Destination (Join-Path $bundleDir "images") -Recurse
  Copy-Item -LiteralPath (Join-Path $repo "LICENSE") -Destination $bundleDir

  $hashFiles = Get-ChildItem -LiteralPath $bundleDir -File -Recurse |
    Where-Object Name -NE "SHA256SUMS" | Sort-Object FullName
  $hashLines = foreach ($file in $hashFiles) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $relative = $file.FullName.Substring($bundleDir.Length + 1).Replace("\", "/")
    "$hash  $relative"
  }
  Set-Content -LiteralPath (Join-Path $bundleDir "SHA256SUMS") -Value $hashLines -Encoding ascii
  Compress-Archive -LiteralPath $bundleDir -DestinationPath $archive -CompressionLevel Optimal -Force
}
finally {
  Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PACKAGE COMPLETE: $archive"
