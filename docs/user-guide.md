# sbproxy Console — Hướng dẫn Người dùng

Tạo và quản lý nhiều WiFi, mỗi WiFi đi qua một SOCKS5 riêng, theo dõi sức khỏe proxy, và sao lưu/khôi phục — tất cả bằng giao diện. Không cần dòng lệnh.

> Bản HTML đọc offline: [user-guide.html](user-guide.html). Kỹ thuật/quản trị: [admin-guide.md](admin-guide.md).

---

## 01 · Console này làm gì?

Mỗi mạng WiFi bạn tạo sẽ gắn với một **SOCKS5** riêng — thiết bị nối vào WiFi đó ra internet qua đúng proxy đó. Console giúp bạn:

- Thêm/sửa/xoá WiFi, đặt tên, mật khẩu, chọn SOCKS.
- Đổi SOCKS mà không reload WiFi; các phiên mạng đang mở có thể gián đoạn ngắn.
- Xem **độ trễ (latency) proxy theo thời gian thực** cho từng WiFi.
- Sao lưu & khôi phục cấu hình chỉ bằng một nút.

**Hai cách dùng local:**
- **Offline** — soạn cấu hình rồi tải file về (không đụng router).
- **Live LAN** — nối thẳng tới router trong cùng mạng: bấm nút là áp dụng thật, thấy sức khỏe proxy realtime (cần token quản trị viên cấp).

---

## 02 · Mở & kết nối router

1. Mở console: nếu quản trị viên đã cài trên router, vào `http://<địa-chỉ-router>/sbproxy/` (ví dụ `http://192.168.1.1/sbproxy/`).
2. Bấm **🔌 Kết nối router** (góc trên phải).
3. Để trống ô *Base URL*, dán **token** quản trị viên cấp, bấm **Kết nối**.
4. Kết nối thành công: hiện huy hiệu **● Live** và cột **Sức khỏe** bắt đầu chạy.

> **Nếu không kết nối được (Live LAN):** thường do mở console qua `https` nên trình duyệt chặn gọi router `http`. Hãy mở đúng `http://<router>/sbproxy/`. Nếu vẫn lỗi, kiểm tra lại token với quản trị viên.

---

## 03 · Đọc bảng WiFi

| Cột | Ý nghĩa |
|---|---|
| **#** | Số thứ tự (idx) — cố định cho mỗi WiFi, quyết định dải mạng riêng. |
| **WiFi (SSID)** | Tên WiFi + dải mạng & cổng nội bộ (chỉ để tham khảo). |
| **Băng** | 2.4G xa hơn/chậm hơn · 5G nhanh hơn/gần hơn. |
| **SOCKS5** | Proxy đang gán: `host:cổng`. |
| **Isolate** | on = các thiết bị trong WiFi này không thấy nhau (an toàn hơn). |
| **WebRTC** | on = chặn rò rỉ IP qua WebRTC (đánh đổi: hỏng gọi video P2P). |
| **Sức khỏe** | Độ trễ proxy realtime + biểu đồ xu hướng — xem mục kế. |

---

## 04 · Sức khỏe proxy (realtime)

Ở chế độ Live, router đo độ trễ mỗi proxy ~mỗi 15 giây; console cập nhật ~8 giây/lần và vẽ **biểu đồ đường (sparkline)** theo thời gian bên cạnh con số.

| Hiển thị | Nghĩa | Nên làm |
|---|---|---|
| `123ms` (xanh) | Proxy tốt, phản hồi nhanh. | Không cần làm gì. |
| `950ms` (vàng) | Proxy chậm (trên ngưỡng). | Theo dõi; cân nhắc đổi SOCKS khác. |
| `fail` (đỏ) | Proxy chết/không phản hồi (kèm mã lỗi). | Đổi SOCKS cho WiFi đó (nút ⚡). |

Đường biểu đồ đi lên = độ trễ tăng dần (proxy đang xấu đi); thấp và phẳng = ổn định.

---

## 05 · Thao tác WiFi

**Thêm WiFi:** bấm **＋ Thêm WiFi**, điền tên, chọn băng tần, mật khẩu (≥ 8 ký tự), nhập SOCKS (host/cổng, user/pass nếu có), bật/tắt *Cách ly* & *Chặn WebRTC*. Theo dõi đồng hồ **BSSID** ở đầu trang — đừng để chuyển đỏ (vượt giới hạn phần cứng).

**Đổi SOCKS nhanh (không reload WiFi):** sửa host/cổng (nút **Sửa**), rồi bấm **⚡** ở hàng đó.
Thiết bị vẫn nối WiFi và giữ DHCP, nhưng phiên mạng đang mở có thể gián đoạn khi sing-box restart.

**Áp toàn bộ thay đổi:** sau khi thêm/sửa/xoá nhiều WiFi, bấm **⇪ Đẩy & Áp lên router** (bước này reload WiFi trong giây lát).

> **Mẹo:** **⭳ Tải từ router** để nạp cấu hình đang chạy trên router về console (khi mở console trên máy khác).

---

## 06 · Backup & Rollback

Router **tự sao lưu** trước mỗi lần "Áp" hay "đổi sock". Ngoài ra bạn có thể chủ động:

1. Bấm **🗂 Backup / Rollback**.
2. **💾 Tạo backup ngay** để lưu một mốc thủ công (nên làm trước khi thay đổi lớn).
3. **⭳ Về máy** ở mỗi bản — tải file backup xuống **máy tính của bạn**.
4. Để quay lui: chọn một bản (mới nhất ở trên) → **↩ Khôi phục** → xác nhận.

> **Rất quan trọng — tải backup về máy:** backup lưu **trên router**. Nếu router phải cài lại firmware hoặc bị hỏng, các backup đó **mất theo**. Vì vậy: định kỳ, và **bắt buộc trước khi cập nhật firmware**, hãy bấm **⭳ Về máy**.

> **Lưu ý:** Khôi phục sẽ **ghi đè** cấu hình hiện tại. Nếu chưa chắc, tạo một backup mới trước khi khôi phục.

---

## 07 · Khi gặp sự cố

| Hiện tượng | Bạn có thể tự làm |
|---|---|
| Một WiFi báo `fail` | Đổi SOCKS cho WiFi đó (đổi host/cổng → nút ⚡). Nhiều sock cùng fail → báo quản trị viên. |
| Sau khi "Áp" bị lỗi/mất mạng | Vào **🗂 Backup / Rollback** → khôi phục bản "mới nhất" (nhãn `pre-apply`). |
| Router treo / không vào được sau update firmware | Việc của quản trị viên (recovery). Cung cấp **file backup đã tải về máy** để họ khôi phục nhanh. |
| Console báo "Mất kết nối" | Mở lại đúng `http://<router>/sbproxy/`; kiểm tra token; hỏi quản trị viên. |
| Latency toàn bộ tăng cao | Có thể do đường mạng/nhà cung cấp SOCKS. Theo dõi biểu đồ; báo admin nếu kéo dài. |
| Client vẫn thấy nhau / gọi video hỏng | Kiểm tra cột *Isolate*/*WebRTC* của WiFi đó và chỉnh cho đúng nhu cầu. |

---

## 08 · An toàn token quản trị

- **Không chia sẻ token**. Token agent là bí mật dùng chung và có toàn quyền cấu hình router.
- Khoá máy khi rời đi; token được lưu trong trình duyệt của máy đang dùng.
- Chỉ mở console tại địa chỉ LAN của router; không dán token vào website bên ngoài.
- Nghi lộ token → báo quản trị viên xoá `/etc/sbproxy/token` và chạy lại `agent/install-agent.sh`.
- **Không gửi ảnh chụp màn hình** chứa token, mật khẩu, hay IP/tài khoản SOCKS ra ngoài.

> Project không có tài khoản hoặc phân quyền theo người. Ai có token agent đều có toàn quyền, vì vậy chỉ dùng trên LAN/VPN quản trị tin cậy.
