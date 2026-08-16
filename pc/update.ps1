# update.ps1 — đẩy code mới nhất của repo lên router qua SSH (chạy từ Windows).
# GIỮ NGUYÊN config đã chỉnh trên router (wifi-socks.conf + settings.sh) trừ khi bảo khác.
#
# Dùng (PowerShell):
#   .\pc\update.ps1                  # chỉ cập nhật code
#   .\pc\update.ps1 -Apply           # cập nhật code rồi chạy apply.sh trên router (tự backup trước)
#   .\pc\update.ps1 -WithSettings    # ghi đè luôn config/settings.sh bằng bản trong repo
param(
  [switch]$WithSettings,
  [switch]$Apply
)
. "$PSScriptRoot\_lib.ps1"

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
