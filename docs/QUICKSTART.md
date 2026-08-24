# Cài đặt nhanh bằng file exe (4 bước)

**Ngôn ngữ:** Tiếng Việt | [English](QUICKSTART.en.md)

Đây là cách cài ngắn nhất: **backup → flash firmware → đặt mật khẩu root → chạy
file exe**. Console desktop lo phần còn lại (đẩy mã nguồn, cài gói, đẩy cấu
hình, chạy script khởi tạo, cài agent, lấy token) và mở luôn màn hình điều khiển.

Cần làm tay đúng ba việc đầu vì chúng có rủi ro vật lý (mất mạng, brick router).

## Chuẩn bị

- Router **GL-MT6000**, cắm **LAN dây** từ máy tính (đường cứu hộ khi Wi-Fi hỏng).
- File `sbproxy-console.exe` (Windows) hoặc `sbproxy-console` (Linux/macOS) —
  bên trong đã có sẵn gói cài cho router, **không cần mã nguồn**.
- Máy có OpenSSH client: mở PowerShell chạy `ssh -V`, có version là được.
  Windows 10/11 cài sẵn; nếu thiếu: *Settings → Apps → Optional features → OpenSSH Client*.
- Danh sách SOCKS5 sẽ dùng (host, port, user, pass) cho từng Wi-Fi.

---

## Bước 1 — Backup ra máy tính

Backup nằm trên router sẽ **mất sạch** khi flash. Tải về máy trước:

- LuCI: **System → Backup/Flash Firmware → Generate archive** → lưu file `.tar.gz`.
- Nếu router đang chạy sbproxy: mở console web `http://<router>/sbproxy/` →
  tab **Backup / Rollback** → **⭳ Về máy**.

Ghi lại phiên bản đang chạy để so sánh về sau: `cat /etc/openwrt_release`.

## Bước 2 — Flash firmware

Không có script cho bước này (chọn sai image là brick router):

1. Tải image **sysupgrade** cho `GL.iNet GL-MT6000` từ
   firmware-selector.openwrt.org và **so khớp sha256** với giá trị công bố:
   `Get-FileHash .\firmware.bin -Algorithm SHA256`. Lệch → không flash.
2. Flash bằng một trong hai cách:
   - **U-Boot** (an toàn nhất khi đổi họ firmware): tắt nguồn → đặt IP máy tính
     `192.168.1.2` → giữ nút Reset khi cấp nguồn tới lúc đèn nháy nhanh →
     mở `http://192.168.1.1` → upload image → chờ reboot.
   - **GL GUI**: `http://192.168.8.1` → System → Upgrade → Local Upgrade →
     **bỏ tick "Keep settings"** khi đổi họ firmware.
3. Chờ router khởi động lại rồi kiểm tra ping được IP LAN.

> IP quản trị: firmware GL.iNet mặc định `192.168.8.1`; OpenWrt vanilla mới flash
> thường là `192.168.1.1`. Nhớ đúng IP thực tế để dùng ở bước 4.

## Bước 3 — Đặt mật khẩu root

Console cần đăng nhập SSH bằng mật khẩu này (hoặc SSH key).

- LuCI: **System → Administration → Router Password** → đặt mật khẩu → Save.
- Hoặc SSH vào router rồi chạy `passwd`.

Kiểm tra nhanh từ máy tính: `ssh root@192.168.8.1` — đăng nhập được là xong bước này.

## Bước 4 — Chạy file exe

1. Chạy `sbproxy-console.exe` (Linux/macOS: `chmod +x ./sbproxy-console` rồi
   `./sbproxy-console`).
2. Chưa có token thì app **tự mở form cài đặt** ngay lần chạy đầu. Nếu đã đóng
   form, mở lại bằng nút **Cài đặt sau khi flash…** (trên thanh vàng
   **CHƯA CẤU HÌNH ROUTER** hoặc ở hàng trên cùng).
3. Điền vào form:
   - **Router (IP)**: IP đã ghi ở bước 2.
   - **Tài khoản / Port SSH**: `root` / `22`.
   - **Mật khẩu SSH**: mật khẩu vừa đặt ở bước 3 (hoặc chọn SSH key).
   - **Mã nguồn hoặc gói .tar.gz**: **để nguyên** — app dùng gói nhúng sẵn.
   - **wifi-socks.conf**: để trống nếu chưa có; cấu hình Wi-Fi/SOCKS nhập trong
     app sau khi cài xong.
4. Bấm **Kiểm tra tình trạng**. App đăng nhập SSH và đọc hiện trạng router
   (chỉ đọc, không đổi gì). Kết nối được mà router **chưa có agent** thì app hỏi
   luôn *“Cài ngay bây giờ?”*:
   - **Có** → chạy luôn toàn bộ cài đặt (khỏi bấm thêm).
   - **Không** → console báo **KHÔNG CẤU HÌNH ĐƯỢC ROUTER**, làm mờ toàn bộ
     phần điều khiển và chỉ để lại một nút **Cài agent ngay**; bấm nút đó là
     cài, cài xong console mở khoá.
5. Hoặc bấm thẳng **Bắt đầu cài đặt** và theo dõi checklist. App sẽ: kiểm tra SSH → xem
   router có sẵn gì → đẩy mã nguồn → cài gói phụ thuộc → đẩy cấu hình →
   preflight + dry-run → `apply.sh` → cài agent → lấy token → kiểm tra agent.
6. Chạy xong, cửa sổ cài đặt tự đóng và màn hình điều khiển mở ra với token vừa lấy.

Thời gian: phần cài gói phụ thuộc lâu nhất (vài phút, tuỳ mạng của router).

---

## Sau khi cài

1. Tab **Wi-Fi / SOCKS5**: thêm SSID, điền SOCKS5 cho từng SSID rồi bấm
   **Đẩy cấu hình & Apply** (app tự dry-run trước khi ghi).
2. Nối một thiết bị vào SSID vừa tạo và kiểm tra:
   - `https://ipinfo.io/ip` phải ra IP của SOCKS tương ứng.
   - `nslookup example.com` phải trả IP trong dải `198.18.0.0/15` (fake-IP).
3. Khung **Internet Gateway** trong app cho biết đường ra thực tế và độ trễ.

Dùng app hằng ngày (thêm WiFi, xem thiết bị, backup):
[desktop-user-guide.md](desktop-user-guide.md). Danh sách kiểm tra đầy đủ:
[TESTING.md](TESTING.md).

## Gặp lỗi thì làm gì

| Hiện tượng | Xử lý |
|---|---|
| Bước "Kiểm tra kết nối SSH" lỗi | Sai IP, sai mật khẩu, hoặc chưa bật SSH. Thử `ssh root@<ip>` trong PowerShell để thấy lỗi thật. |
| Dừng ở "Cài gói phụ thuộc" | Router chưa ra được Internet (cần WAN để tải gói). Kiểm tra dây WAN/uplink rồi chạy lại. |
| Dừng ở "Chạy preflight" | Đọc thông báo của router: thường là thiếu gói hoặc mapping radio sai trong `config/settings.sh`. |
| Chạy lại được không? | Được. Mọi bước đều idempotent; phần nào đã cài app sẽ **Bỏ qua**. |
| Muốn cài lại cấu hình/agent từ đầu | Tick **Ghi đè cấu hình đã có trên router** hoặc **Cài lại agent dù đã có** trong wizard. |
| App báo agent version khác | Xem *Tương thích version* trong [../console/desktop/README.vi.md](../console/desktop/README.vi.md). |

Muốn làm tay từng lệnh thay vì dùng app: [INSTALL.md](INSTALL.md) và
[admin-guide.md](admin-guide.md).
