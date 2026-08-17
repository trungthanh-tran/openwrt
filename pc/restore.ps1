<#
.SYNOPSIS
Đẩy 1 bản backup từ máy Windows này lên router và khôi phục.

.DESCRIPTION
Đẩy snapshot lên router rồi chạy scripts/rollback.sh (khôi phục file cấu hình +
reload network/dnsmasq/firewall/sing-box/wifi). Có hỏi xác nhận trước khi ghi đè
(bỏ qua bằng -Yes).

Cấu hình kết nối lấy theo ưu tiên: tham số dòng lệnh > file config > mặc định.
File config mặc định: pc\sbproxy-pc.conf (đổi bằng -Conf hoặc env SBPC_CONF).
KHÔNG cần file config nếu đã truyền -RouterHost.

.PARAMETER Backup
Bản backup cần khôi phục: tên (trong LocalBackupDir) hoặc đường dẫn file .tar.gz.
Bỏ trống = bản local MỚI NHẤT.

.PARAMETER List
Liệt kê backup local rồi thoát.

.PARAMETER Yes
Không hỏi xác nhận (cho script/tự động hoá).

.PARAMETER Conf
Đường dẫn file config (mặc định pc\sbproxy-pc.conf).

.PARAMETER RouterHost
IP/hostname router (= ROUTER_HOST trong file config).

.PARAMETER RouterUser
User SSH, mặc định root (= ROUTER_USER).

.PARAMETER RouterPort
Cổng SSH, mặc định 22 (= ROUTER_PORT).

.PARAMETER SshKey
Đường dẫn SSH private key (= SSH_KEY).

.PARAMETER RemoteDir
Thư mục repo trên router, mặc định /root/sbproxy (= REMOTE_DIR).

.PARAMETER RemoteBackupDir
Thư mục backup trên router, mặc định /root/sbproxy-backups (= REMOTE_BACKUP_DIR).

.PARAMETER LocalBackupDir
Thư mục backup ở máy này, mặc định pc\backups (= LOCAL_BACKUP_DIR).

.EXAMPLE
.\pc\restore.ps1 -List
Xem các bản backup đang có trên máy.

.EXAMPLE
.\pc\restore.ps1
Khôi phục bản mới nhất (hỏi xác nhận).

.EXAMPLE
.\pc\restore.ps1 20260816-101500-pc

.EXAMPLE
.\pc\restore.ps1 D:\backup\router.tar.gz -RouterHost 192.168.8.1 -Yes
Không cần file config, không hỏi xác nhận.
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

# Xác định file backup
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

# 1) Đẩy lên router và giải nén vào thư mục backup của router
Log "Day $name len router..."
Copy-ToRouter $file '/tmp/sb-restore.tar.gz'
Invoke-Router "mkdir -p $RemoteBackupDir; tar xzf /tmp/sb-restore.tar.gz -C $RemoteBackupDir; rm -f /tmp/sb-restore.tar.gz"

# 2) Chạy rollback của repo (SB_YES=1: đã xác nhận ở trên rồi)
Log 'Chay rollback tren router...'
Invoke-Router "SB_YES=1 sh $RemoteDir/scripts/rollback.sh $name" -Tty

Log 'KHOI PHUC XONG. Kiem tra lai mang/WiFi. Neu mat ket noi SSH, xem docs/ROLLBACK.md.'
