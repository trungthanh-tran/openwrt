param(
  [switch]$Push,
  [switch]$SkipTests,
  [switch]$Wait
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$source = (Get-Content VERSION -Raw).Trim()
if ($source -notmatch '^([0-9]+)\.([0-9]+)\.([0-9]+)-SNAPSHOT$') { throw "VERSION must end in -SNAPSHOT: $source" }
$major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
$Version = "$major.$minor.$patch"
$next = "$major.$minor.$($patch + 1)-SNAPSHOT"
$null = git diff --quiet
$trackedDiff = $LASTEXITCODE
$null = git diff --cached --quiet
$stagedDiff = $LASTEXITCODE
if ($trackedDiff -ne 0 -or $stagedDiff -ne 0) {
  throw 'Tracked working-tree changes are not committed'
}
$untracked = @(git status --short | Where-Object { $_ -match '^\?\? ' })
if ($untracked.Count -gt 0) {
  Write-Warning "Ignoring untracked files; they are not included in the release: $($untracked -join ', ')"
}
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
  # Windows PowerShell's -Encoding utf8 writes a BOM and can transcode the
  # existing UTF-8 source through the active code page. Keep release edits
  # byte-stable and UTF-8 without BOM on every supported PowerShell.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $repo 'VERSION'), $value, $utf8NoBom)
  $main = Join-Path $repo 'console/desktop/main.py'
  $mainText = [System.IO.File]::ReadAllText($main, [System.Text.Encoding]::UTF8)
  $mainText = $mainText -replace 'APP_VERSION = "[^"]+"', ('APP_VERSION = "' + $value + '"')
  [System.IO.File]::WriteAllText($main, $mainText, $utf8NoBom)
  $web = Join-Path $repo 'console/web/control-panel.html'
  $webText = [System.IO.File]::ReadAllText($web, [System.Text.Encoding]::UTF8)
  $webText = $webText -replace 'const UI_VERSION = "[^"]+";', ('const UI_VERSION = "' + $value + '";')
  [System.IO.File]::WriteAllText($web, $webText, $utf8NoBom)
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
  Write-Host "Pushed $Version; GitHub Actions is building the release."
  if ($Wait) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
      throw 'The -Wait option requires GitHub CLI (gh) to be installed and authenticated.'
    }
    $run = $null
    for ($i = 0; $i -lt 30 -and -not $run; $i++) {
      Start-Sleep -Seconds 2
      $runs = gh run list --workflow deploy-release.yml --limit 20 --json databaseId,headSha,status |
        ConvertFrom-Json
      $run = $runs | Where-Object { $_.headSha -eq (git rev-list -n 1 $Version) } | Select-Object -First 1
    }
    if (-not $run) { throw "Could not find the GitHub Actions run for $Version" }
    gh run watch $run.databaseId --exit-status
    gh release view $Version --json tagName,isDraft,isPrerelease,assets
    Write-Host "Release $Version is published."
  }
} else {
  Write-Host "Prepared release $Version and next version $next locally. Re-run with -Push to push."
  Write-Host "Use -Push -Wait to push and wait for the GitHub Release."
}
