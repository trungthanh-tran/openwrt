<#
.SYNOPSIS
Upload a backup from this Windows computer and restore it on the router.

.DESCRIPTION
Uploads the snapshot and runs scripts/rollback.sh to restore configuration and
reload network, dnsmasq, firewall, sing-box, and Wi-Fi. Prompts before overwriting;
use -Yes to skip confirmation.

Connection settings precedence: command-line parameters, config file, then defaults.
The default config file is pc\sbproxy-pc.conf; override it with -Conf or SBPC_CONF.
A config file is not required when -RouterHost is provided.

.PARAMETER Backup
Backup to restore: a name in LocalBackupDir or a .tar.gz file path.
When omitted, the newest local backup is selected.

.PARAMETER List
List local backups and exit.

.PARAMETER Yes
Skip confirmation for scripts and automation.

.PARAMETER Conf
Config file path; defaults to pc\sbproxy-pc.conf.

.PARAMETER RouterHost
Router IP address or hostname (= ROUTER_HOST in the config file).

.PARAMETER RouterUser
SSH user; defaults to root (= ROUTER_USER).

.PARAMETER RouterPort
SSH port; defaults to 22 (= ROUTER_PORT).

.PARAMETER SshKey
SSH private-key path (= SSH_KEY).

.PARAMETER RemoteDir
Repository directory on the router; defaults to /root/sbproxy (= REMOTE_DIR).

.PARAMETER RemoteBackupDir
Backup directory on the router; defaults to /root/sbproxy-backups (= REMOTE_BACKUP_DIR).

.PARAMETER LocalBackupDir
Local backup directory; defaults to pc\backups (= LOCAL_BACKUP_DIR).

.EXAMPLE
.\pc\restore.ps1 -List
List backups available on this computer.

.EXAMPLE
.\pc\restore.ps1
Restore the newest backup after confirmation.

.EXAMPLE
.\pc\restore.ps1 20260816-101500-pc

.EXAMPLE
.\pc\restore.ps1 D:\backup\router.tar.gz -RouterHost 192.168.8.1 -Yes
No config file or confirmation is required.
#>
param(
  [string]$Backup,
  [switch]$List,
  [switch]$Yes,
  [string]$Conf,
  [string]$RouterHost,
  [string]$RouterUser,
  [string]$RouterPort,
  [string]$SshKey,
  [string]$RemoteDir,
  [string]$RemoteBackupDir,
  [string]$LocalBackupDir
)
. "$PSScriptRoot\_lib.ps1"
Initialize-SbPc $PSBoundParameters

if ($List) {
  Write-Host "Backup local trong ${LocalBackupDir}:"
  $files = Get-ChildItem -Path $LocalBackupDir -Filter '*.tar.gz' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
  if ($files) { $files | ForEach-Object { Write-Host ('  ' + ($_.Name -replace '\.tar\.gz$', '')) } }
  else        { Write-Host '  (chua co — chay .\pc\backup.ps1 truoc)' }
  exit 0
}

# Resolve the requested snapshot.
if (-not $Backup) {
  $file = Get-ChildItem -Path $LocalBackupDir -Filter '*.tar.gz' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $file) { Die "Chua co backup nao trong $LocalBackupDir. Chay .\pc\backup.ps1 truoc." }
  $file = $file.FullName
} elseif (Test-Path $Backup) {
  $file = (Resolve-Path $Backup).Path
} elseif (Test-Path (Join-Path $LocalBackupDir "$Backup.tar.gz")) {
  $file = Join-Path $LocalBackupDir "$Backup.tar.gz"
} else {
  Die "Khong tim thay: $Backup. Xem danh sach: .\pc\restore.ps1 -List"
}
$name = [IO.Path]::GetFileName($file) -replace '\.tar\.gz$', ''

Warn "Se GHI DE cau hinh tren router $RouterHost bang ban: $name"
if (-not $Yes) {
  $ans = Read-Host 'Tiep tuc? [y/N]'
  if ($ans -notmatch '^[yY]$') { Die 'Da huy.' }
}

# 1) Upload and extract into the router backup directory.
Log "Day $name len router..."
Copy-ToRouter $file '/tmp/sb-restore.tar.gz'
Invoke-Router "mkdir -p $RemoteBackupDir; tar xzf /tmp/sb-restore.tar.gz -C $RemoteBackupDir; rm -f /tmp/sb-restore.tar.gz"

# 2) Run project rollback; confirmation was already handled above.
Log 'Chay rollback tren router...'
Invoke-Router "SB_YES=1 sh $RemoteDir/scripts/rollback.sh $name" -Tty

Log 'KHOI PHUC XONG. Kiem tra lai mang/WiFi. Neu mat ket noi SSH, xem docs/ROLLBACK.md.'
