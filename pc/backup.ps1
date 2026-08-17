<#
.SYNOPSIS
Back up the router and download the snapshot to this Windows computer.

.DESCRIPTION
Runs scripts/backup.sh on the router, including configuration, sing-box, nftables,
wifi-socks.conf, and sysupgrade backup data, then downloads a
<timestamp>-<label>.tar.gz snapshot to LOCAL_BACKUP_DIR. Restore it with
pc\restore.ps1 or pc/restore.sh on Linux.

Connection settings precedence: command-line parameters, config file, then defaults.
The default config file is pc\sbproxy-pc.conf; override it with -Conf or SBPC_CONF.
A config file is not required when -RouterHost is provided.

.PARAMETER Label
Label appended to the backup name; accepts letters, digits, dots, underscores, and hyphens. Defaults to "pc".

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
It must match BACKUP_DIR in the router's config/settings.sh.

.PARAMETER LocalBackupDir
Local backup directory; defaults to pc\backups (= LOCAL_BACKUP_DIR).

.EXAMPLE
.\pc\backup.ps1
Create a backup labeled "pc" using connection settings from pc\sbproxy-pc.conf.

.EXAMPLE
.\pc\backup.ps1 -Label truoc-nang-cap

.EXAMPLE
.\pc\backup.ps1 -RouterHost 192.168.8.1 -LocalBackupDir D:\router-backups
No config file is required; all settings are passed as parameters.
#>
param(
  [string]$Label = 'pc',
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

if ($Label -notmatch '^[A-Za-z0-9._-]+$') {
  Die "Nhan chi gom chu/so/._- (khong khoang trang): $Label"
}

# 1) Create a router snapshot with scripts/backup.sh.
Log "Tao backup tren router (nhan: $Label)..."
Invoke-Router "sh $RemoteDir/scripts/backup.sh $Label"

# 2) Resolve the newly created snapshot through `latest`.
$name = (ssh @SshArgs $Target "basename `$(readlink -f $RemoteBackupDir/latest)" | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not $name -or $name -eq 'latest') {
  Die 'Khong xac dinh duoc ban backup vua tao tren router.'
}
$name = $name.Trim()

# 3) Archive the snapshot on the router and download it with SCP.
if (-not (Test-Path $LocalBackupDir)) { New-Item -ItemType Directory -Force $LocalBackupDir | Out-Null }
$out = Join-Path $LocalBackupDir "$name.tar.gz"
Log "Keo ve: $out ..."
Invoke-Router "tar czf /tmp/sb-pull.tar.gz -C $RemoteBackupDir $name"
try {
  Copy-FromRouter '/tmp/sb-pull.tar.gz' $out
}
finally {
  Invoke-Router 'rm -f /tmp/sb-pull.tar.gz'
}
if (-not (Test-Path $out) -or (Get-Item $out).Length -eq 0) {
  Die 'File keo ve rong — kiem tra ket noi/duong dan.'
}

Log "Backup xong: $out"
Log 'Danh sach ban local: .\pc\restore.ps1 -List'
