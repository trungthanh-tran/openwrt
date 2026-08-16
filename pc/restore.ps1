# restore.ps1 — đẩy 1 bản backup từ máy Windows này lên router và chạy rollback
# (khôi phục file cấu hình + reload network/dnsmasq/firewall/sing-box/wifi).
#
# Dùng (PowerShell):
#   .\pc\restore.ps1 -List                          # liệt kê backup local
#   .\pc\restore.ps1                                # khôi phục bản local MỚI NHẤT
#   .\pc\restore.ps1 20260816-101500-pc             # theo tên (trong LOCAL_BACKUP_DIR)
#   .\pc\restore.ps1 D:\duong\dan\backup.tar.gz     # theo đường dẫn file
param(
  [string]$Backup,
  [switch]$List
)
. "$PSScriptRoot\_lib.ps1"

if ($List) {
  Write-Host "Backup local trong ${LocalBackupDir}:"
  $files = Get-ChildItem -Path $LocalBackupDir -Filter '*.tar.gz' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending
  if ($files) { $files | ForEach-Object { Write-Host ('  ' + $_.BaseName.Replace('.tar','')) } }
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
$ans = Read-Host 'Tiep tuc? [y/N]'
if ($ans -notmatch '^[yY]$') { Die 'Da huy.' }

# 1) Đẩy lên router và giải nén vào thư mục backup của router
Log "Day $name len router..."
Copy-ToRouter $file '/tmp/sb-restore.tar.gz'
Invoke-Router "mkdir -p $RemoteBackupDir; tar xzf /tmp/sb-restore.tar.gz -C $RemoteBackupDir; rm -f /tmp/sb-restore.tar.gz"

# 2) Chạy rollback của repo (SB_YES=1: đã xác nhận ở trên rồi)
Log 'Chay rollback tren router...'
Invoke-Router "SB_YES=1 sh $RemoteDir/scripts/rollback.sh $name" -Tty

Log 'KHOI PHUC XONG. Kiem tra lai mang/WiFi. Neu mat ket noi SSH, xem docs/ROLLBACK.md.'
