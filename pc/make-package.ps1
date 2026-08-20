# make-package.ps1 - build an update package for upload through the console UI
# (POST ?action=update) or for archiving a release.
#
# Usage: pc\make-package.ps1 [-OutDir dist]
#
# Output: <OutDir|dist>\sbproxy-update-<version>.tar.gz
# Same file list as pc\update.ps1; always includes VERSION so
# scripts/self-update.sh can enforce its downgrade guard.
param(
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoDir 'dist' }

$Ver = (Get-Content (Join-Path $RepoDir 'VERSION') -Raw).Trim()
if ($Ver -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "VERSION khong hop le: '$Ver'" }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$Pkg = Join-Path $OutDir "sbproxy-update-$Ver.tar.gz"
tar -czf $Pkg -C $RepoDir --exclude=node_modules `
  README.md VERSION agent config console docs etc scripts
if ($LASTEXITCODE -ne 0) { throw 'tar that bai (can Windows 10+ co tar.exe)' }

Write-Host "Da tao: $Pkg"
Write-Host 'Upload qua UI: Ket noi router -> Cap nhat -> chon file nay.'
