<#
.SYNOPSIS
Đẩy code mới nhất của repo lên router qua SSH (chạy từ Windows).

.DESCRIPTION
GIỮ NGUYÊN config đã chỉnh trên router (wifi-socks.conf + settings.sh) trừ khi -WithSettings.
Thư mục pc/ (có thể chứa secret) không bao giờ được đẩy lên router.

Cấu hình kết nối lấy theo ưu tiên: tham số dòng lệnh > file config > mặc định.
File config mặc định: pc\sbproxy-pc.conf (đổi bằng -Conf hoặc env SBPC_CONF).
KHÔNG cần file config nếu đã truyền -RouterHost.

.PARAMETER Apply
Sau khi chép code, chạy apply.sh trên router (apply tự backup trước khi áp).

.PARAMETER WithSettings
Ghi đè luôn config/settings.sh trên router bằng bản trong repo.

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

.EXAMPLE
.\pc\update.ps1
Cập nhật code, đọc kết nối từ pc\sbproxy-pc.conf.

.EXAMPLE
.\pc\update.ps1 -Apply
Cập nhật code rồi áp cấu hình luôn.

.EXAMPLE
.\pc\update.ps1 -RouterHost 192.168.8.1 -Apply
Không cần file config — mọi thứ truyền qua tham số.

.EXAMPLE
.\pc\update.ps1 -Conf D:\router2.conf
Quản lý router thứ hai bằng file config riêng.
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

# 1) Đóng gói repo (không kèm pc/ — script phía máy quản trị, có thể chứa secret)
$tmpTar = Join-Path $env:TEMP "sbproxy-update-$PID.tar.gz"
Log 'Dong goi repo...'
tar -czf $tmpTar -C $RepoDir --exclude=node_modules `
  README.md agent cloud-server config docs etc scripts tools ui
if ($LASTEXITCODE -ne 0) { Die 'tar that bai (can Windows 10+ co tar.exe)' }

try {
  # 2) Đẩy lên router + giải nén, giữ lại config đang dùng
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

# 3) Áp dụng (tuỳ chọn)
if ($Apply) {
  Log 'Chay apply.sh tren router (tu backup truoc khi ap)...'
  Invoke-Router "cd $RemoteDir; sh scripts/apply.sh" -Tty
} else {
  Log 'Xong. Chua ap cau hinh — khi san sang:'
  Log "  .\pc\update.ps1 -Apply   (hoac SSH vao router: sh $RemoteDir/scripts/apply.sh)"
}
