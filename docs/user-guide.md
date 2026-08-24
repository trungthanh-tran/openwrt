# sbproxy Console — Hướng dẫn Người dùng

**Ngôn ngữ:** Tiếng Việt | [English](user-guide.en.md)

Tạo và quản lý nhiều WiFi, mỗi WiFi đi qua một SOCKS5 riêng, theo dõi sức khỏe proxy, và sao lưu/khôi phục — tất cả bằng giao diện. Không cần dòng lệnh.

> Dùng bản **desktop (.exe)**: [desktop-user-guide.md](desktop-user-guide.md).
> Kỹ thuật/quản trị: [admin-guide.md](admin-guide.md).

---

## 01 · Console này làm gì?

Mỗi mạng WiFi bạn tạo sẽ gắn với một **SOCKS5** riêng — thiết bị nối vào WiFi đó ra internet qua đúng proxy đó. Console giúp bạn:

- Thêm/sửa/xoá WiFi, đặt tên, mật khẩu, chọn SOCKS, **giả MAC theo hãng WiFi**.
- Đổi SOCKS mà không reload WiFi; các phiên mạng đang mở có thể gián đoạn ngắn.
- Xem **độ trễ (latency) proxy theo thời gian thực** cho từng WiFi.
- **Xem thiết bị đang kết nối** từng WiFi (MAC, IP, thời gian, lưu lượng) và **kick / cấm**.
- Sao lưu & khôi phục cấu hình chỉ bằng một nút.

**Hai cách dùng local:**
- **Offline** — soạn cấu hình rồi tải file về (không đụng router).
- **Live LAN** — nối thẳng tới router trong cùng mạng: bấm nút là áp dụng thật, thấy sức khỏe proxy realtime (cần token quản trị viên cấp).

**Hai bản Console (hai giao diện, cùng Agent API):**
- **Bản Web** — mở trong trình duyệt tại `http://<router>/sbproxy/`.
- **Bản Desktop (.exe)** — ứng dụng Windows Tkinter native, không dùng WebView; kết nối trực tiếp Agent API qua LAN và lưu token mã hóa bằng Windows DPAPI.

---

## 02 · Mở & kết nối router

1. Mở console:
   - **Bản Web:** vào `http://<địa-chỉ-router>/sbproxy/` (MT6000 mặc định: `http://192.168.8.1/sbproxy/`).
   - **Bản Desktop:** Windows mở `sbproxy-console.exe`; Linux/macOS chạy `./sbproxy-console` (mỗi nền tảng có file build riêng, tự chứa đủ mọi thứ).
2. Nhập token quản trị viên cấp rồi bấm **Kết nối**:
   - Bản Web mở từ router: để trống ô *Base URL*.
   - Bản Desktop: nhập *Router* = `http://<IP-router>` (ví dụ `http://192.168.8.1`).
3. Kết nối thành công: thanh trạng thái báo sing-box đang chạy; cấu hình, thiết bị và backup được nạp từ router.

Khung **Internet Gateway** phía trên các tab cho biết đường ra thực tế
(`wwan`/device, next-hop, IP nguồn), trạng thái link, DNS và HTTP latency. Nếu
hiện **KHÔNG QUA wwan** hoặc màu vàng/đỏ, bấm **Kiểm tra gateway** rồi báo quản
trị viên trước khi Apply thêm thay đổi.

> **Bản Desktop hiện thanh vàng “CHƯA CẤU HÌNH ROUTER”?** Router đó chưa có agent hoặc chưa có token. Bấm **Kiểm tra tình trạng** để biết thiếu cái nào (thao tác chỉ đọc, không đổi gì trên router), rồi báo quản trị viên chạy **Cài đặt sau khi flash** — xem [admin-guide.md](admin-guide.md).

> **Nếu không kết nối được (bản Web):** thường do mở console qua `https` nên trình duyệt chặn gọi router `http`. Hãy mở đúng `http://<router>/sbproxy/`, hoặc dùng **bản Desktop** (không bị chặn). Nếu vẫn lỗi, kiểm tra lại token với quản trị viên.

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
| `fail` (đỏ) | Proxy chết/không phản hồi (kèm mã lỗi). | Đổi SOCKS cho WiFi đó (bản web: nút ⚡; bản desktop: chuột phải → **Đổi SOCKS**). |

Đường biểu đồ đi lên = độ trễ tăng dần (proxy đang xấu đi); thấp và phẳng = ổn định.

---

## 05 · Thao tác WiFi

**Thêm WiFi:** bấm **＋ Thêm WiFi**, điền tên, chọn băng tần, mật khẩu (≥ 8 ký tự), nhập SOCKS (host/cổng, user/pass nếu có), bật/tắt *Cách ly* & *Chặn WebRTC*. Theo dõi đồng hồ **BSSID** ở đầu trang — đừng để chuyển đỏ (vượt giới hạn phần cứng).

**Giả MAC theo hãng WiFi:** nhấp chuột phải lên SSID trong bảng, chọn **Random MAC** rồi chọn hãng (TP-Link, Netgear, ASUS, Xiaomi…). Ba byte đầu theo OUI của hãng, ba byte sau ngẫu nhiên. Thao tác lưu provider và reload radio ngay sau khi bạn xác nhận cảnh báo.

**Đổi SOCKS nhanh:** nhấp chuột phải lên SSID trong bảng rồi chọn **Đổi SOCKS**. Menu chuột phải tự chọn đúng dòng dưới con trỏ; khung cố định chỉ giữ nút Sửa và Xoá.
Thiết bị vẫn nối WiFi và giữ DHCP, nhưng phiên mạng đang mở có thể gián đoạn khi sing-box restart.

**Áp toàn bộ thay đổi:** sau khi thêm/sửa/xoá nhiều WiFi, bấm **Đẩy cấu hình & Apply**. App native luôn dry-run candidate trước; chỉ khi đạt mới backup, ghi cấu hình và reload WiFi.

> **Cảnh báo:** Apply, đổi SOCKS, random MAC, xoá SSID, kick/cấm/bỏ cấm và rollback đều hiển thị phạm vi ảnh hưởng trước khi chạy. Mặc định là **Không**; đọc kỹ mục tiêu rồi mới xác nhận.

> **Mẹo:** **⭳ Tải từ router** để nạp cấu hình đang chạy trên router về console (khi mở console trên máy khác).

---

## 06 · Thiết bị đang kết nối (kick / cấm)

Mở tab **Thiết bị** để xem client online và cả MAC trong blocklist đang offline:

| Cột | Ý nghĩa |
|---|---|
| **SSID / Band** | WiFi và băng 2.4/5 GHz của thiết bị. |
| **MAC** | Địa chỉ MAC của thiết bị. |
| **IP / Tên máy** | Địa chỉ IP được cấp và tên máy (nếu có trong DHCP). |
| **Kết nối** | Thời gian đã kết nối (vd `3g 20p`). |
| **Vào / Ra** | Lưu lượng tải xuống (in) / tải lên (out) của phiên. |
| **Sóng** | Cường độ tín hiệu (dBm); càng gần 0 càng mạnh. |

- Lọc theo SSID, band, online/offline, quyền truy cập, RSSI, traffic, thời gian; tìm bằng IP/tên/MAC và bấm tiêu đề cột để sắp xếp.
- Chọn một hoặc nhiều dòng; thao tác **Chi tiết / Copy / Kick / Cấm / Bỏ cấm** chỉ nằm trong khung điều khiển sát bảng và tự khóa nếu không phù hợp.
- **Kick** ngắt thiết bị ngay nhưng nó có thể nối lại. **Cấm** chặn MAC lâu dài và có thể reload radio ngắn. **Bỏ cấm** hoạt động cả với mục blocklist offline.
- Có thể chặn MAC chưa kết nối, bật auto-refresh 5–60 giây hoặc xuất danh sách đang lọc ra CSV UTF-8.

Dashboard phía trên bảng cho biết số online, tín hiệu yếu, đã chặn và tổng lưu lượng.

---

## 07 · Backup & Rollback

Router **tự sao lưu** trước mỗi lần "Áp" hay "đổi sock". Ngoài ra bạn có thể chủ động:

1. Bấm **🗂 Backup / Rollback**.
2. **💾 Tạo backup ngay** để lưu một mốc thủ công (nên làm trước khi thay đổi lớn).
3. Bản Web có thể tải snapshot về máy; với app native dùng thêm `pc/backup.ps1` nếu cần bản sao ngoài router.
4. Để quay lui: chọn một bản → dùng **Rollback backup đang chọn** trong khung sát danh sách → đọc cảnh báo và xác nhận.

> **Rất quan trọng — tải backup về máy:** backup lưu **trên router**. Nếu router phải cài lại firmware hoặc bị hỏng, các backup đó **mất theo**. Vì vậy: định kỳ, và **bắt buộc trước khi cập nhật firmware**, hãy bấm **⭳ Về máy**.

> **Lưu ý:** Khôi phục sẽ **ghi đè** cấu hình hiện tại. Nếu chưa chắc, tạo một backup mới trước khi khôi phục.

---

## 08 · Khi gặp sự cố

| Hiện tượng | Bạn có thể tự làm |
|---|---|
| Một WiFi báo `fail` | Đổi SOCKS cho WiFi đó (đổi host/cổng: bản web nút ⚡, bản desktop chuột phải → **Đổi SOCKS**). Nhiều sock cùng fail → báo quản trị viên. |
| Sau khi "Áp" bị lỗi/mất mạng | Vào **🗂 Backup / Rollback** → khôi phục bản "mới nhất" (nhãn `pre-apply`). |
| Router treo / không vào được sau update firmware | Việc của quản trị viên (recovery). Cung cấp **file backup đã tải về máy** để họ khôi phục nhanh. |
| Console báo "Mất kết nối" | Mở lại đúng `http://<router>/sbproxy/`; kiểm tra token; hỏi quản trị viên. |
| Latency toàn bộ tăng cao | Có thể do đường mạng/nhà cung cấp SOCKS. Theo dõi biểu đồ; báo admin nếu kéo dài. |
| Client vẫn thấy nhau / gọi video hỏng | Kiểm tra cột *Isolate*/*WebRTC* của WiFi đó và chỉnh cho đúng nhu cầu. |

---

## 09 · An toàn token quản trị

- **Không chia sẻ token**. Token agent là bí mật dùng chung và có toàn quyền cấu hình router.
- Khoá máy khi rời đi. Bản Web lưu token trong trình duyệt; app native mã hóa token bằng Windows DPAPI cho đúng tài khoản hiện tại.
- Chỉ mở console tại địa chỉ LAN của router; không dán token vào website bên ngoài.
- Nghi lộ token → báo quản trị viên xoá `/etc/sbproxy/token` và chạy lại `agent/install-agent.sh`.
- **Không gửi ảnh chụp màn hình** chứa token, mật khẩu, hay IP/tài khoản SOCKS ra ngoài.

> Project không có tài khoản hoặc phân quyền theo người. Ai có token agent đều có toàn quyền, vì vậy chỉ dùng trên LAN/VPN quản trị tin cậy.
