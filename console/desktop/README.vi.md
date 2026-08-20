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
  lưu lượng và thời gian kết nối; bấm tiêu đề cột để sắp xếp.
- Dashboard số thiết bị online/yếu/đã chặn/tổng lưu lượng, auto-refresh 5–60s,
  xem chi tiết, chọn nhiều thiết bị, copy IP/MAC và xuất CSV UTF-8.
- Khung Internet Gateway hiển thị route thực tế, `wwan`/device, next-hop, IP
  nguồn, link, DNS và HTTP latency; cảnh báo nếu đường ra không qua `wwan`.
- Hiển thị cả thiết bị trong blocklist khi đang offline để có thể bỏ cấm.
- Các thao tác cần chọn mục chỉ nằm trong khung chỉnh sửa sát bảng; toolbar chỉ
  chứa thao tác toàn cục.
- Tác vụ quan trọng luôn hiện cảnh báo ảnh hưởng và mặc định chọn **Không**;
  chỉ thực thi sau khi người dùng xác nhận rõ ràng.
- Chọn hãng router/OUI (TP-Link, Netgear, ASUS, Xiaomi, Huawei, v.v.) rồi bấm
  **Random MAC** cho từng SSID; provider và BSSID mới được lưu lại.
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

Máy chạy file build ra không cần cài Python hay WebView2. Trên Windows token
được niêm phong bằng DPAPI; trên Linux/macOS token nằm trong
`~/.config/sbproxy-console-native/connection.json` với quyền `chmod 600`.

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
