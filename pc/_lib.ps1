# _lib.ps1 — helpers chung cho các script pc/*.ps1 (Windows PowerShell 5.1+).
# Dot-source từ update.ps1 / backup.ps1 / restore.ps1. Đọc cấu hình pc/sbproxy-pc.conf.
$ErrorActionPreference = 'Stop'

$script:PcDir   = $PSScriptRoot
$script:RepoDir = Split-Path -Parent $PSScriptRoot

function Log($m)  { Write-Host "[pc] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[pc][CANH BAO] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[pc][LOI] $m" -ForegroundColor Red; exit 1 }

$ConfFile = Join-Path $PcDir 'sbproxy-pc.conf'
if ($env:SBPC_CONF) { $ConfFile = $env:SBPC_CONF }
if (-not (Test-Path $ConfFile)) {
  Die "Chua co $ConfFile — copy pc/sbproxy-pc.conf.example thanh pc/sbproxy-pc.conf roi sua."
}

# Đọc file KEY=value (định dạng dùng chung với bản bash)
$script:Conf = @{}
foreach ($line in Get-Content $ConfFile) {
  if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
    $Conf[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
  }
}
function Get-Conf($key, $default) {
  if ($Conf.ContainsKey($key) -and $Conf[$key]) { $Conf[$key] } else { $default }
}

$script:RouterHost      = Get-Conf 'ROUTER_HOST' $null
if (-not $RouterHost) { Die 'Thieu ROUTER_HOST trong sbproxy-pc.conf' }
$script:RouterUser      = Get-Conf 'ROUTER_USER' 'root'
$script:RouterPort      = Get-Conf 'ROUTER_PORT' '22'
$script:RemoteDir       = Get-Conf 'REMOTE_DIR' '/root/sbproxy'
$script:RemoteBackupDir = Get-Conf 'REMOTE_BACKUP_DIR' '/root/sbproxy-backups'
$script:LocalBackupDir  = Get-Conf 'LOCAL_BACKUP_DIR' (Join-Path $PcDir 'backups')
$script:SshKey          = Get-Conf 'SSH_KEY' $null

$script:Target  = "$RouterUser@$RouterHost"
$script:SshArgs = @('-p', $RouterPort, '-o', 'ConnectTimeout=10')
$script:ScpArgs = @('-P', $RouterPort, '-o', 'ConnectTimeout=10')
if ($SshKey) { $SshArgs += @('-i', $SshKey); $ScpArgs += @('-i', $SshKey) }

foreach ($exe in 'ssh', 'scp', 'tar') {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
    Die "Thieu $exe.exe — can Windows 10+ voi OpenSSH Client (Settings > Optional Features)."
  }
}

# Chạy lệnh trên router. -Tty: cấp terminal cho lệnh có hỏi xác nhận.
function Invoke-Router([string]$cmd, [switch]$Tty) {
  $extra = @(); if ($Tty) { $extra += '-t' }
  ssh @extra @SshArgs $Target $cmd
  if ($LASTEXITCODE -ne 0) { Die "Lenh tren router that bai (exit $LASTEXITCODE)" }
}
function Copy-ToRouter([string]$local, [string]$remote) {
  scp @ScpArgs $local "${Target}:$remote"
  if ($LASTEXITCODE -ne 0) { Die 'scp len router that bai' }
}
function Copy-FromRouter([string]$remote, [string]$local) {
  scp @ScpArgs "${Target}:$remote" $local
  if ($LASTEXITCODE -ne 0) { Die 'scp tu router that bai' }
}
