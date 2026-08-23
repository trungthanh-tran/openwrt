param(
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [switch]$Push,
  [switch]$CreateMilestone
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Version must be semver" }
$sourceVersion = (Get-Content VERSION -Raw).Trim()
if ($sourceVersion -ne $Version) { throw "VERSION is $sourceVersion, requested release is $Version" }
if (@(git status --short).Count -gt 0) { throw 'Working tree is not clean' }
if (@(git tag --list $Version).Count -gt 0) { throw "Tag $Version already exists" }

if ($CreateMilestone) {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh CLI is required for -CreateMilestone' }
  gh api 'repos/{owner}/{repo}/milestones' -f "title=$Version" -f state=open | Out-Host
}

git tag -a $Version -m "Release $Version"
if ($Push) {
  git push origin main
  git push origin $Version
} else {
  Write-Host 'Dry-run complete. Re-run with -Push to push main and the tag.'
}
