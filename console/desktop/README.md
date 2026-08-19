# sbproxy Console — bản Desktop (.exe cho Windows)

**Ngôn ngữ:** Tiếng Việt | [English](README.en.md)

Cùng một giao diện với [bản Web](../web/control-panel.html), nhưng đóng gói thành
ứng dụng Windows (`.exe`) dùng WebView2. Khác biệt chính:

| | Bản Web (router-hosted) | Bản Desktop (.exe) |
|---|---|---|
| Chạy ở đâu | `http://<router>/sbproxy/` (cài qua `agent/install-agent.sh`) | máy Windows của quản trị viên |
| Gọi agent router | same-origin (không cần nhập URL) | nhập `http://<IP-router>` trong "Kết nối router" |
| Mixed-content | Bị chặn nếu mở qua **https** → phải mở qua http từ router | **Không bị chặn** — gọi thẳng router http qua LAN |
| Cập nhật | copy lại file HTML | build lại exe |

> Cả hai bản dùng **chung một file nguồn** `console/web/control-panel.html`. Sửa UI ở đó,
> bản Web copy trực tiếp, bản Desktop build lại (`build.ps1` tự copy file này).

## Yêu cầu
- **Để build:** Python 3.9+ trên PATH (`python --version`).
- **Để chạy exe:** Windows 10/11 với **Microsoft Edge WebView2 Runtime**
  (đã cài sẵn trên hầu hết Win10/11; nếu thiếu, tải "Evergreen Standalone
  Installer" từ trang WebView2 của Microsoft).

## Build
```powershell
# từ thư mục dự án
cd desktop
.\build.ps1
# -> desktop\dist\sbproxy-console.exe  (một file duy nhất)
```
`build.ps1` sẽ: copy `..\ui\control-panel.html` vào đây, cài
`pywebview`+`pyinstaller`, rồi đóng gói `--onefile --windowed`.

## Chạy thử khi phát triển (không cần build)
```powershell
cd desktop
python -m pip install -r requirements.txt
python main.py        # nạp thẳng ..\ui\control-panel.html
```

## Dùng
1. Mở `sbproxy-console.exe`.
2. Bấm **🔌 Kết nối router** → nhập `http://<IP-router>` (ví dụ
   `http://192.168.8.1`) và **token** (in ra bởi `agent/install-agent.sh`).
3. Từ đây thao tác giống hệt bản Web: thêm/bớt WiFi, đẩy & áp, xem thiết bị,
   kick/cấm, backup/rollback…

Token và URL được lưu ở `%USERPROFILE%\.sbproxy-console` nên lần sau tự nhớ.

## Bảo mật
- Chỉ kết nối tới router trong **LAN/VLAN quản trị**. Không expose agent ra WAN.
- Giữ token bí mật; đổi token bằng cách xoá `/etc/sbproxy/token` trên router rồi
  chạy lại `install-agent.sh`.
