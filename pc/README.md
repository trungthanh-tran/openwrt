# pc/ — update · backup · restore router từ máy quản trị (Windows & Linux)

**Ngôn ngữ:** Tiếng Việt | [English](README.en.md)

Bộ script chạy trên **máy của bạn** (không phải trên router) để quản lý router qua SSH:

| Việc | Windows (PowerShell) | Linux / macOS / Git Bash |
|---|---|---|
| Cập nhật code lên router | `.\pc\update.ps1` | `sh pc/update.sh` |
| Backup router → kéo về máy | `.\pc\backup.ps1` | `sh pc/backup.sh` |
| Khôi phục từ backup trên máy | `.\pc\restore.ps1` | `sh pc/restore.sh` |

Hai bản Windows/Linux **tương đương nhau** — dùng bản nào cũng được, backup tạo từ bản này restore được bằng bản kia (cùng định dạng `<timestamp>-<nhãn>.tar.gz` trong `pc/backups/`).

## Yêu cầu
- **Windows 10/11:** OpenSSH Client (`ssh`, `scp`) + `tar` — có sẵn trên Windows 10 1809+.
  Nếu thiếu: *Settings → Apps → Optional Features → OpenSSH Client*.
- **Linux/macOS:** `ssh` + `tar` (mặc định đều có).
- Router đã SSH được (mật khẩu hoặc key). Lần đầu nên cài key để đỡ gõ mật khẩu nhiều lần:
  ```
  ssh-keygen -t ed25519            # nếu chưa có key
  # OpenWrt không có ssh-copy-id phía router, làm tay:
  type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@192.168.8.1 "cat >> /etc/dropbear/authorized_keys"
  ```

## Cấu hình: file config HOẶC tham số dòng lệnh

Mỗi script nhận cấu hình theo thứ tự ưu tiên (cao → thấp):

1. **Tham số dòng lệnh** — `-RouterHost ...` (Windows) / `--host ...` (Linux)
2. **File config** — mặc định `pc/sbproxy-pc.conf`; đổi file bằng `-Conf FILE` / `--conf FILE`
   hoặc biến môi trường `SBPC_CONF`
3. **Giá trị mặc định** — user `root`, port `22`, `/root/sbproxy`, …

File config **không bắt buộc** nếu đã truyền địa chỉ router qua tham số.

### Bảng tham số chung (mọi script đều nhận)

| Windows (PowerShell) | Linux (bash) | Khóa trong file config | Mặc định |
|---|---|---|---|
| `-RouterHost HOST` | `--host HOST` | `ROUTER_HOST` | *(bắt buộc)* |
| `-RouterUser USER` | `--user USER` | `ROUTER_USER` | `root` |
| `-RouterPort PORT` | `--port PORT` | `ROUTER_PORT` | `22` |
| `-SshKey FILE` | `--key FILE` | `SSH_KEY` | *(ssh tự chọn)* |
| `-RemoteDir DIR` | `--remote-dir DIR` | `REMOTE_DIR` | `/root/sbproxy` |
| `-RemoteBackupDir DIR` | `--backup-dir DIR` | `REMOTE_BACKUP_DIR` | `/root/sbproxy-backups` |
| `-LocalBackupDir DIR` | `--local-dir DIR` | `LOCAL_BACKUP_DIR` | `pc/backups` |
| `-Conf FILE` | `--conf FILE` | — | `pc/sbproxy-pc.conf` |

`REMOTE_BACKUP_DIR` phải khớp `BACKUP_DIR` trong [config/settings.sh](../config/settings.sh) của router.

### Cách 1 — dùng file config (khuyên dùng khi quản lý 1 router lâu dài)
```
copy pc\sbproxy-pc.conf.example pc\sbproxy-pc.conf    # Windows
cp   pc/sbproxy-pc.conf.example pc/sbproxy-pc.conf    # Linux
```
Sửa `pc/sbproxy-pc.conf`: điền `ROUTER_HOST` (IP router), còn lại thường giữ mặc định.
File này nằm trong `.gitignore` — không bị commit, không bị đẩy lên router.

### Cách 2 — chỉ dùng tham số (không cần file, tiện chạy nhanh / nhiều router)
```powershell
.\pc\backup.ps1 -RouterHost 192.168.8.1
.\pc\update.ps1 -RouterHost 192.168.8.1 -RouterPort 2222 -SshKey C:\keys\router -Apply
```
```sh
sh pc/backup.sh --host 192.168.8.1
sh pc/update.sh --host 192.168.8.1 --port 2222 --key ~/.ssh/router --apply
```

### Nhiều router — mỗi router 1 file config riêng
```powershell
.\pc\backup.ps1 -Conf D:\configs\router-a.conf
.\pc\backup.ps1 -Conf D:\configs\router-b.conf
```
Tham số vẫn đè được lên file: `.\pc\update.ps1 -Conf router-a.conf -RouterPort 2222`.

### Xem hướng dẫn ngay trên terminal
```powershell
Get-Help .\pc\update.ps1 -Detailed     # Windows: help đầy đủ + ví dụ
sh pc/update.sh --help                 # Linux
```

## update — cập nhật code lên router
```powershell
.\pc\update.ps1                # chỉ chép code mới (chưa áp cấu hình)
.\pc\update.ps1 -Apply         # chép code rồi chạy apply.sh (apply tự backup trước)
.\pc\update.ps1 -WithSettings  # ghi đè cả config/settings.sh bằng bản trong repo
```
Mặc định **giữ nguyên** `config/wifi-socks.conf` và `config/settings.sh` đang dùng trên router — chỉ code (scripts/, etc/, agent/, ui/, docs/…) được thay. Thư mục `pc/` không được đẩy lên router.

## backup — snapshot router, kéo về máy
```powershell
.\pc\backup.ps1                       # nhãn "pc"
.\pc\backup.ps1 -Label truoc-nang-cap
```
Chạy `scripts/backup.sh` trên router (tar `/etc/config` + `/etc/sing-box` + nft + wifi-socks.conf, kèm `sysupgrade -b`), rồi kéo nguyên snapshot về `pc/backups/<timestamp>-<nhãn>.tar.gz`. Nhờ vậy **kể cả khi router chết hẳn** bạn vẫn còn bản cấu hình nằm trên máy mình.

## restore — khôi phục router từ backup trên máy
```powershell
.\pc\restore.ps1 -List                # xem các bản đang có
.\pc\restore.ps1                      # khôi phục bản MỚI NHẤT (hỏi xác nhận)
.\pc\restore.ps1 20260816-101500-pc   # khôi phục bản chỉ định
```
Đẩy snapshot lên router rồi chạy `scripts/rollback.sh` (khôi phục file + reload network/dnsmasq/firewall/sing-box/wifi). Nếu router đã bị reset sạch: cài lại code trước (`.\pc\update.ps1`) rồi mới restore; trường hợp nặng nhất dùng file `sysupgrade-backup.tar.gz` bên trong snapshot qua LuCI *System → Backup/Flash → Restore*.

## Ghi chú kỹ thuật
- Truyền file dùng scp giao thức cũ / `tar` qua pipe SSH — tương thích **dropbear** của OpenWrt, không cần cài `openssh-sftp-server` trên router.
- Nếu Linux của bạn có OpenSSH ≥ 9.0 mà scp lỗi SFTP: bản bash không dùng scp nên không bị ảnh hưởng.
- Backup trên router tự giữ 20 bản gần nhất ([scripts/backup.sh](../scripts/backup.sh)); backup local trên máy không tự xoá — bạn tự quản lý `pc/backups/`.

## Bản GUI cho cùng đường SSH

Cần giao diện thay vì dòng lệnh — kể cả cài router mới flash và lấy token agent về — dùng **Cài đặt sau khi flash** trong [../console/desktop/README.vi.md](../console/desktop/README.vi.md). `pc/make-package.sh` / `pc\make-package.ps1` tạo gói `sbproxy-update-<version>.tar.gz` dùng chung cho wizard đó và cho dialog cập nhật của console web.
