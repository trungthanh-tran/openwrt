param(
  [switch]$Push,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$source = (Get-Content VERSION -Raw).Trim()
if ($source -notmatch '^([0-9]+)\.([0-9]+)\.([0-9]+)-SNAPSHOT$') { throw "VERSION must end in -SNAPSHOT: $source" }
$major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
$Version = "$major.$minor.$patch"
$next = "$major.$minor.$($patch + 1)-SNAPSHOT"
if (@(git status --short).Count -gt 0) { throw 'Working tree is not clean' }
if (@(git tag --list $Version).Count -gt 0) { throw "Tag $Version already exists" }

if ($SkipTests) {
  Write-Warning 'Skipping tests at the operator request'
} else {
  Write-Host "Running the full test suite before releasing $Version..."
  & sh tests/run-all.sh
  if ($LASTEXITCODE -ne 0) { throw 'Tests failed; release aborted' }
  Write-Host 'Tests passed.'
}

function Set-Version([string]$value) {
  Set-Content VERSION $value -NoNewline -Encoding utf8
  $main = Join-Path $repo 'console/desktop/main.py'
  (Get-Content $main -Raw) -replace 'APP_VERSION = "[^"]+"', ('APP_VERSION = "' + $value + '"') | Set-Content $main -NoNewline -Encoding utf8
  $web = Join-Path $repo 'console/web/control-panel.html'
  (Get-Content $web -Raw) -replace 'const UI_VERSION = "[^"]+";', ('const UI_VERSION = "' + $value + '";') | Set-Content $web -NoNewline -Encoding utf8
}

Set-Version $Version
git add VERSION console/desktop/main.py console/web/control-panel.html
git commit -m "release: $Version"
git tag -a $Version -m "Release $Version"
Set-Version $next
git add VERSION console/desktop/main.py console/web/control-panel.html
git commit -m "chore: start $next development"
if ($Push) {
  git push origin main
  git push origin $Version
  Write-Host "Released $Version; main is now $next"
} else {
  Write-Host "Prepared release $Version and next version $next locally. Re-run with -Push to push."
}
