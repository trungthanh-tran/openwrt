# sbproxy Console Native cho Windows

**Ngôn ngữ:** Tiếng Việt | [English](README.md)

Ứng dụng desktop Tkinter chạy độc lập và gọi trực tiếp Agent API trên router.
Ứng dụng **không dùng HTML, WebView hay WebView2**; console web tại
`console/web/control-panel.html` là một ứng dụng riêng.

## Chức năng

- Chuyển trực tiếp giữa giao diện English/Tiếng Việt và theme Dark/Light; lựa
  chọn được lưu cho lần chạy sau. Mặc định là English + Dark.
- Quản lý danh sách Wi-Fi/SSID và SOCKS5, lưu cấu hình rồi apply.
- Thêm/xóa SSID; mọi lần Apply đều dry-run cấu hình tạm trước khi ghi và được
  Agent dry-run lần cuối trước khi thay đổi router.
- Hiển thị màn hình loading theo từng bước; timeout: dry-run 60 giây, lưu/backup
  45 giây và apply 120 giây.
- Đổi nhanh SOCKS5 cho từng SSID.
- Xem client, kick, ban và unban.
- Lọc thiết bị theo SSID, IP/tên/MAC, trạng thái cấm và mức tín hiệu.
- Bộ lọc nâng cao theo band, online/offline, quyền truy cập, ngưỡng RSSI,
  lưu lượng và thời gian kết nối. Bấm bất kỳ tiêu đề cột nào trong bảng Wi-Fi
  hoặc Thiết bị để sắp xếp; bấm lại để đảo chiều.
- Dashboard số thiết bị online/yếu/đã chặn/tổng lưu lượng, auto-refresh 5–60s,
  xem chi tiết, chọn nhiều thiết bị, copy IP/MAC và xuất CSV UTF-8.
- Khung Internet Gateway hiển thị route thực tế, `wwan`/device, next-hop, IP
  nguồn, link, DNS và HTTP latency; cảnh báo nếu đường ra không qua `wwan`.
- Hiển thị cả thiết bị trong blocklist khi đang offline để có thể bỏ cấm.
- Nhấp chuột phải lên một dòng SSID để sửa, đổi SOCKS, random MAC hoặc xoá.
  Khung chỉnh sửa cố định chỉ giữ Sửa và Xoá; toolbar chỉ chứa thao tác toàn cục.
- Tác vụ quan trọng luôn hiện cảnh báo ảnh hưởng và mặc định chọn **Không**;
  chỉ thực thi sau khi người dùng xác nhận rõ ràng.
- Nhấp chuột phải lên SSID, chọn **Random MAC**, rồi chọn hãng router/OUI
  (TP-Link, Netgear, ASUS, Xiaomi, Huawei, v.v.); provider và BSSID mới được lưu lại.
- Xem backup, rollback, health và log thao tác.
- Lưu URL router và token bằng Windows DPAPI cho đúng tài khoản Windows hiện tại.

## Build

Yêu cầu Python 3.9+ có Tkinter. PyInstaller không cross-compile — build trên
đúng nền tảng đích.

Windows:

```powershell
cd console\desktop
.\build.ps1
# -> dist\sbproxy-console.exe
```

Linux/macOS (Debian/Ubuntu cần `sudo apt install python3-tk` trước):

```sh
cd console/desktop
sh build.sh
# -> dist/sbproxy-console
```

Máy chạy file build ra không cần cài Python hay WebView2.

Trên Linux, bootloader POSIX không expand `~` hay `$HOME`, nên runtime giải nén
vào thư mục temp mặc định trừ khi chỉ định đường dẫn tuyệt đối:

```sh
SBPROXY_RUNTIME_TMPDIR=/opt/sbproxy/runtime sh build.sh
```

## Môi trường tách biệt

Mọi thứ app ghi ra đều nằm trong **một thư mục home riêng**, không lẫn với môi
trường Python bên ngoài hay với bản cài khác:

```
<home>/config/connection.json   URL router + token (DPAPI trên Windows, chmod 600 nơi khác)
<home>/logs/console.log         log debug xoay vòng (1 MB × 5 file)
<home>/cache/                   dữ liệu tạm
<home>/runtime/                 Python runtime + dependency đóng gói (Windows onefile)
```

Thứ tự xác định `<home>`:

1. Biến môi trường `SBPROXY_HOME` (tùy ý chỉ định).
2. Thư mục `data/` nằm cạnh file thực thi — **chế độ portable**, hợp với USB
   hoặc bản copy-anywhere; cứ tạo thư mục là app tự dùng.
3. Mặc định theo người dùng: `%LOCALAPPDATA%\sbproxy-console-native` (Windows),
   `~/.local/share/sbproxy-console-native` (Linux/macOS).

Chạy `sbproxy-console --where` để in ra đường dẫn thực tế. File
`connection.json` của bản cũ được tự động migrate vào `config/` ở lần chạy đầu.

## Log để debug

Mọi lệnh gọi agent (action, dung lượng, thời gian, lỗi HTTP/kết nối), tác vụ
nền, dòng log trên UI và **exception không bắt được** — cả main thread lẫn
worker thread — đều ghi vào `<home>/logs/console.log`, xoay vòng ở 1 MB và giữ
5 file. Thông tin nhạy cảm (token, header Bearer, mật khẩu WiFi/SOCKS) được
che (`***`) trước khi ghi nên file an toàn để gửi kèm báo lỗi. Bấm nút
**Thư mục log** trên header để mở, hoặc chạy `--verbose` để log mức DEBUG.

## Chạy khi phát triển

```powershell
cd console\desktop
.\run.ps1
```

## Nạp sẵn kết nối

Có thể nạp URL và token mà không ghi token rõ vào file:

```powershell
$env:SBPROXY_BASE = "http://192.168.8.1"
$env:SBPROXY_TOKEN = "<token>"
.\dist\sbproxy-console.exe --provision
.\dist\sbproxy-console.exe --probe
```

Thông tin được lưu ở
`%LOCALAPPDATA%\sbproxy-console-native\connection.json`; token được mã hóa bằng
DPAPI và chỉ tài khoản Windows hiện tại giải mã được. Agent dùng
`Authorization: Bearer <token>` vì uhttpd có thể loại bỏ header CGI tùy biến.

Chỉ dùng Agent trong LAN/VLAN quản trị; không mở API ra WAN.
