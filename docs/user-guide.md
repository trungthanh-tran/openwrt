# sbproxy Console — Hướng dẫn Người dùng

Tạo và quản lý nhiều WiFi, mỗi WiFi đi qua một SOCKS5 riêng, theo dõi sức khỏe proxy, và sao lưu/khôi phục — tất cả bằng giao diện. Không cần dòng lệnh.

> Bản HTML đọc offline: [user-guide.html](user-guide.html). Kỹ thuật/quản trị: [admin-guide.md](admin-guide.md).

---

## 01 · Console này làm gì?

Mỗi mạng WiFi bạn tạo sẽ gắn với một **SOCKS5** riêng — thiết bị nối vào WiFi đó ra internet qua đúng proxy đó. Console giúp bạn:

- Thêm/sửa/xoá WiFi, đặt tên, mật khẩu, chọn SOCKS.
- Đổi SOCKS của một WiFi **không làm rớt kết nối**.
- Xem **độ trễ (latency) proxy theo thời gian thực** cho từng WiFi.
- Sao lưu & khôi phục cấu hình chỉ bằng một nút.

**Ba cách dùng:**
- **Offline** — soạn cấu hình rồi tải file về (không đụng router).
- **Live LAN** — nối thẳng tới router trong cùng mạng: bấm nút là áp dụng thật, thấy sức khỏe proxy realtime (cần token quản trị viên cấp).
- **Cloud (từ xa)** — nếu quản trị viên đã dựng server, bạn **đăng nhập bằng tài khoản riêng** trên web để điều khiển router từ bất cứ đâu; thao tác giống hệt, chỉ khác mỗi hành động có thể bị giới hạn theo **quyền** tài khoản của bạn.

---

## 02 · Mở & kết nối router

1. Mở console: nếu quản trị viên đã cài trên router, vào `http://<địa-chỉ-router>/sbproxy/` (ví dụ `http://192.168.1.1/sbproxy/`).
2. Bấm **🔌 Kết nối router** (góc trên phải).
3. Để trống ô *Base URL*, dán **token** quản trị viên cấp, bấm **Kết nối**.
4. Kết nối thành công: hiện huy hiệu **● Live** và cột **Sức khỏe** bắt đầu chạy.

> **Dùng web Cloud (đăng nhập từ xa):** mở địa chỉ web quản trị viên cấp → đăng nhập tài khoản/mật khẩu của bạn. Chọn router muốn quản ở ô trên cùng. Nút nào bị mờ/ẩn nghĩa là tài khoản của bạn **chưa được cấp quyền** cho tính năng đó — liên hệ quản trị viên. Đổi mật khẩu ở nút **Đổi MK** góc trên phải.

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

**Đổi SOCKS nhanh (không rớt WiFi):** sửa host/cổng (nút **Sửa**), rồi bấm **⚡** ở hàng đó để đẩy riêng thay đổi SOCKS. Người đang dùng **không bị ngắt**, chỉ đường ra internet đổi proxy.

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

## 08 · An toàn tài khoản (chống lộ)

- **Không chia sẻ** mật khẩu / token của bạn cho ai. Mỗi người một tài khoản riêng.
- **Đăng xuất** khi dùng máy chung; khoá máy khi rời đi (token/đăng nhập được lưu trong trình duyệt).
- Chỉ mở console/web ở **đúng địa chỉ** quản trị viên cấp — cảnh giác trang giả xin token/mật khẩu.
- Nghi lộ mật khẩu → đổi ngay ở nút **Đổi MK** và báo quản trị viên.
- **Không gửi ảnh chụp màn hình** chứa token, mật khẩu, hay IP/tài khoản SOCKS ra ngoài.

> **Nút bị mờ/ẩn?** Nghĩa là tài khoản của bạn chưa được cấp quyền cho tính năng đó — điều này là **chủ ý để an toàn**, liên hệ quản trị viên nếu cần.
