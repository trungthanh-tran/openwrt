# backup.ps1 — chạy backup trên router rồi KÉO snapshot về máy Windows này.
# Snapshot lưu tại LOCAL_BACKUP_DIR dạng <timestamp>-<nhãn>.tar.gz, dùng lại được với pc/restore.ps1.
#
# Dùng (PowerShell):
#   .\pc\backup.ps1                       # nhãn mặc định "pc"
#   .\pc\backup.ps1 -Label truoc-nang-cap
param(
  [string]$Label = 'pc'
)
. "$PSScriptRoot\_lib.ps1"

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
