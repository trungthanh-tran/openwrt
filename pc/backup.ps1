<#
.SYNOPSIS
Backup router rồi KÉO snapshot về máy Windows này.

.DESCRIPTION
Chạy scripts/backup.sh trên router (tar /etc/config + /etc/sing-box + nft + wifi-socks.conf,
kèm sysupgrade -b), rồi kéo snapshot về LOCAL_BACKUP_DIR dạng <timestamp>-<nhãn>.tar.gz.
Snapshot dùng lại được với pc\restore.ps1 (hoặc pc/restore.sh trên Linux).

Cấu hình kết nối lấy theo ưu tiên: tham số dòng lệnh > file config > mặc định.
File config mặc định: pc\sbproxy-pc.conf (đổi bằng -Conf hoặc env SBPC_CONF).
KHÔNG cần file config nếu đã truyền -RouterHost.

.PARAMETER Label
Nhãn gắn vào tên bản backup (chữ/số/._- ; mặc định "pc").

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
Phải khớp BACKUP_DIR trong config/settings.sh của router.

.PARAMETER LocalBackupDir
Thư mục lưu backup ở máy này, mặc định pc\backups (= LOCAL_BACKUP_DIR).

.EXAMPLE
.\pc\backup.ps1
Backup với nhãn "pc", đọc kết nối từ pc\sbproxy-pc.conf.

.EXAMPLE
.\pc\backup.ps1 -Label truoc-nang-cap

.EXAMPLE
.\pc\backup.ps1 -RouterHost 192.168.8.1 -LocalBackupDir D:\router-backups
Không cần file config — mọi thứ truyền qua tham số.
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

# 1) Tạo snapshot trên router (scripts/backup.sh của repo: tar config + sysupgrade -b)
Log "Tao backup tren router (nhan: $Label)..."
Invoke-Router "sh $RemoteDir/scripts/backup.sh $Label"

# 2) Lấy tên bản vừa tạo (con trỏ 'latest')
$name = (ssh @SshArgs $Target "basename `$(readlink -f $RemoteBackupDir/latest)" | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not $name -or $name -eq 'latest') {
  Die 'Khong xac dinh duoc ban backup vua tao tren router.'
}
$name = $name.Trim()

# 3) Nén bản đó trên router rồi scp về máy
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
