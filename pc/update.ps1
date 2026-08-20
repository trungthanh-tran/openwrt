<#
.SYNOPSIS
Deploy the latest repository code to the router over SSH from Windows.

.DESCRIPTION
Preserves router-specific configuration (wifi-socks.conf and settings.sh) unless -WithSettings is used.
The pc/ directory may contain secrets and is never uploaded to the router.

Connection settings precedence: command-line parameters, config file, then defaults.
The default config file is pc\sbproxy-pc.conf; override it with -Conf or SBPC_CONF.
A config file is not required when -RouterHost is provided.

.PARAMETER Apply
Run apply.sh on the router after uploading; apply creates a backup first.

.PARAMETER WithSettings
Overwrite config/settings.sh on the router with the repository version.

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

.EXAMPLE
.\pc\update.ps1
Upload code using connection settings from pc\sbproxy-pc.conf.

.EXAMPLE
.\pc\update.ps1 -Apply
Upload code and apply the configuration.

.EXAMPLE
.\pc\update.ps1 -RouterHost 192.168.8.1 -Apply
No config file is required; all settings are passed as parameters.

.EXAMPLE
.\pc\update.ps1 -Conf D:\router2.conf
Manage a second router with a separate config file.
#>
param(
  [switch]$WithSettings,
  [switch]$Apply,
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

# 1) Package router-side files; pc/ may contain local secrets and is excluded.
$tmpTar = Join-Path $env:TEMP "sbproxy-update-$PID.tar.gz"
Log 'Dong goi repo...'
tar -czf $tmpTar -C $RepoDir --exclude=node_modules `
  README.md VERSION agent config console docs etc scripts
if ($LASTEXITCODE -ne 0) { Die 'tar that bai (can Windows 10+ co tar.exe)' }

try {
  # 2) Upload and extract while preserving active configuration.
  Log "Day len ${Target}:$RemoteDir ..."
  Copy-ToRouter $tmpTar '/tmp/sbproxy-update.tar.gz'

  $keep = '/tmp/sbproxy-keep'
  $cmd  = "set -e; rm -rf $keep; mkdir -p $RemoteDir $keep; " +
          "if [ -f $RemoteDir/config/wifi-socks.conf ]; then cp $RemoteDir/config/wifi-socks.conf $keep/; fi; "
  if (-not $WithSettings) {
    $cmd += "if [ -f $RemoteDir/config/settings.sh ]; then cp $RemoteDir/config/settings.sh $keep/; fi; "
  }
  $cmd += "tar xzf /tmp/sbproxy-update.tar.gz -C $RemoteDir; " +
          "if [ -f $keep/wifi-socks.conf ]; then cp $keep/wifi-socks.conf $RemoteDir/config/wifi-socks.conf; fi; " +
          "if [ -f $keep/settings.sh ]; then cp $keep/settings.sh $RemoteDir/config/settings.sh; fi; " +
          "chmod +x $RemoteDir/scripts/*.sh; " +
          "rm -rf $keep /tmp/sbproxy-update.tar.gz; " +
          "echo [router] Code da cap nhat: $RemoteDir"
  Invoke-Router $cmd
}
finally {
  Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue
}

# 3) Apply when requested.
if ($Apply) {
  Log 'Chay apply.sh tren router (tu backup truoc khi ap)...'
  Invoke-Router "cd $RemoteDir; sh scripts/apply.sh" -Tty
} else {
  Log 'Xong. Chua ap cau hinh — khi san sang:'
  Log "  .\pc\update.ps1 -Apply   (hoac SSH vao router: sh $RemoteDir/scripts/apply.sh)"
}
