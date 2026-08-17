# _lib.ps1 — helpers chung cho các script pc/*.ps1 (Windows PowerShell 5.1+).
#
# CẤU HÌNH — lấy theo thứ tự ưu tiên (cao → thấp):
#   1. Tham số dòng lệnh  (-RouterHost, -RouterUser, -RouterPort, ...)
#   2. File config        (mặc định pc/sbproxy-pc.conf; đổi bằng -Conf FILE
#                          hoặc biến môi trường SBPC_CONF)
#   3. Giá trị mặc định   (user root, port 22, /root/sbproxy, ...)
# File config KHÔNG bắt buộc nếu đã truyền -RouterHost.
#
# Cách script dùng lib này:
#   param([string]$Conf, [string]$RouterHost, ... , tham số riêng)
#   . "$PSScriptRoot\_lib.ps1"
#   Initialize-SbPc $PSBoundParameters     # nạp config + kiểm tra
$ErrorActionPreference = 'Stop'

$script:PcDir   = $PSScriptRoot
$script:RepoDir = Split-Path -Parent $PSScriptRoot

function Log($m)  { Write-Host "[pc] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[pc][CANH BAO] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[pc][LOI] $m" -ForegroundColor Red; exit 1 }

# Initialize-SbPc — nạp file config (nếu có), áp tham số CLI đè lên, điền mặc định.
# $Cli: thường là $PSBoundParameters của script gọi. Các key được hiểu:
#   Conf, RouterHost, RouterUser, RouterPort, SshKey,
#   RemoteDir, RemoteBackupDir, LocalBackupDir  (key khác bị bỏ qua)
function Initialize-SbPc([hashtable]$Cli = @{}) {
  # 1) File config: -Conf > env SBPC_CONF > pc/sbproxy-pc.conf
  if ($Cli['Conf']) {
    $confFile = [string]$Cli['Conf']
    if (-not (Test-Path $confFile)) { Die "Khong thay file config: $confFile" }
  } elseif ($env:SBPC_CONF) {
    $confFile = $env:SBPC_CONF
  } else {
    $confFile = Join-Path $PcDir 'sbproxy-pc.conf'
  }

  # Đọc file KEY=value (định dạng dùng chung với bản bash) — nếu file tồn tại
  $conf = @{}
  if (Test-Path $confFile) {
    foreach ($line in Get-Content $confFile) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $conf[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
      }
    }
  }

  # 2+3) CLI > file > mặc định
  function Pick($cliKey, $confKey, $default) {
    if ($Cli[$cliKey])                                  { return [string]$Cli[$cliKey] }
    if ($conf.ContainsKey($confKey) -and $conf[$confKey]) { return $conf[$confKey] }
    $default
  }
  $script:RouterHost      = Pick 'RouterHost'      'ROUTER_HOST'       $null
  $script:RouterUser      = Pick 'RouterUser'      'ROUTER_USER'       'root'
  $script:RouterPort      = Pick 'RouterPort'      'ROUTER_PORT'       '22'
  $script:SshKey          = Pick 'SshKey'          'SSH_KEY'           $null
  $script:RemoteDir       = Pick 'RemoteDir'       'REMOTE_DIR'        '/root/sbproxy'
  $script:RemoteBackupDir = Pick 'RemoteBackupDir' 'REMOTE_BACKUP_DIR' '/root/sbproxy-backups'
  $script:LocalBackupDir  = Pick 'LocalBackupDir'  'LOCAL_BACKUP_DIR'  (Join-Path $PcDir 'backups')

  if (-not $RouterHost) {
    Die ("Chua biet dia chi router. Truyen -RouterHost <IP> hoac tao $PcDir\sbproxy-pc.conf " +
         '(copy tu sbproxy-pc.conf.example).')
  }

  $script:Target  = "$RouterUser@$RouterHost"
  $script:SshArgs = @('-p', $RouterPort, '-o', 'ConnectTimeout=10')
  $script:ScpArgs = @('-P', $RouterPort, '-o', 'ConnectTimeout=10')
  if ($SshKey) {
    if (-not (Test-Path $SshKey)) { Die "Khong thay SSH key: $SshKey" }
    $script:SshArgs += @('-i', $SshKey)
    $script:ScpArgs += @('-i', $SshKey)
  }

  foreach ($exe in 'ssh', 'scp', 'tar') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
      Die "Thieu $exe.exe — can Windows 10+ voi OpenSSH Client (Settings > Optional Features)."
    }
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
