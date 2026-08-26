# Console Desktop — Hướng dẫn Người dùng

**Ngôn ngữ:** Tiếng Việt | [English](desktop-user-guide.en.md)

Hướng dẫn dùng **ứng dụng desktop** (`sbproxy-console.exe` trên Windows,
`sbproxy-console` trên Linux/macOS) trong công việc hằng ngày: mở app, kết nối
router, thêm/sửa WiFi và SOCKS5, xem thiết bị, sao lưu. Không cần dòng lệnh.

- Cài router mới từ đầu: [QUICKSTART.md](QUICKSTART.md) (4 bước).
- Dùng bản console web trong trình duyệt: [user-guide.md](user-guide.md).
- Việc quản trị sâu (firmware, script, bảo mật): [admin-guide.md](admin-guide.md).

---

## 1 · Mở app lần đầu

Chỉ có **một file** duy nhất, không cần cài đặt gì thêm:

- Windows: bấm đúp `sbproxy-console.exe`.
- Linux/macOS: `chmod +x ./sbproxy-console` rồi `./sbproxy-console`.

App nhớ token nên **lần sau mở là vào thẳng màn hình điều khiển**. Lần đầu (chưa
có token) app **tự mở form cài đặt** và hỏi thông tin SSH của router:

| Ô | Điền gì |
|---|---|
| **Router (IP)** | Địa chỉ LAN của router, ví dụ `192.168.8.1` |
| **Tài khoản SSH** | `root` |
| **Port SSH** | `22` |
| **Mật khẩu SSH** | Mật khẩu root đã đặt trên router (hoặc chọn SSH key) |
| **Mã nguồn hoặc gói .tar.gz** | **Để nguyên** — bản exe đã có sẵn gói cài |
| **wifi-socks.conf** | Để trống nếu chưa có; thêm Wi-Fi trong app sau khi cài xong |

Điền xong bấm **Kiểm tra tình trạng**. App đăng nhập SSH và xem router đang có
gì (thao tác **chỉ đọc**, không đổi gì trên router), rồi:

- **Router chưa có agent** → app hỏi *“Cài ngay bây giờ?”*
  - **Có** → chạy luôn toàn bộ chuỗi cài đặt, lấy token và mở màn hình điều khiển.
  - **Không** → app báo **KHÔNG CẤU HÌNH ĐƯỢC ROUTER**, làm mờ toàn bộ phần điều
    khiển và chỉ để lại một nút **Cài agent ngay**. Không có agent thì app thật
    sự không điều khiển được gì, nên đây là lối ra duy nhất; bấm nút đó là cài
    ngay bằng thông tin SSH vừa nhập, cài xong app tự mở khoá.
- **Router đã có agent và token** → app báo không cần cài lại; đóng form và bấm
  **Kết nối**.

> Chưa có `wifi-socks.conf` thì console tạo giúp một file trống (kèm chú thích
> từng cột) rồi cài bình thường. Vào tab **Wi-Fi / SOCKS5** thêm SSID rồi bấm
> **Đẩy cấu hình & Apply** là router chạy đầy đủ.

> Mật khẩu SSH chỉ nằm trong bộ nhớ của phiên làm việc: không ghi ra file cấu
> hình, không xuất hiện trên dòng lệnh, và bị che trong log.

## 2 · Kết nối hằng ngày

Hàng trên cùng luôn có sẵn:

- **Router** — `http://<IP-router>`, ví dụ `http://192.168.8.1`.
- **Agent token** — token do quản trị viên cấp (app cài xong thì tự điền).
- **Kết nối** / **Làm mới** — kết nối lại và nạp lại dữ liệu từ router.
- **Cài đặt sau khi flash…** — mở lại form cài đặt bất cứ lúc nào (router vừa
  flash lại chẳng hạn).

Kết nối xong, thanh trạng thái báo sing-box đang chạy và app hiện phiên bản agent
bên cạnh phiên bản app. Hai bản lệch nhau thì app xử lý luôn:

- **Agent cũ hơn app** → app hỏi có nâng cấp không; đồng ý thì hiện cửa sổ chạy
  **từng bước có nhật ký** (chuẩn bị gói → kiểm tra phiên bản → đẩy gói → kiểm
  tra lại agent), **giữ nguyên cấu hình WiFi/SOCKS**. Lỗi ở bước nào là dừng
  ngay ở đó và nói rõ lý do; nếu vẫn không được thì cài lại agent bằng
  **Cài đặt sau khi flash… → Cài lại agent dù đã có**.
- **Agent mới hơn app** → app chuyển sang **chỉ đọc** và yêu cầu dùng bản app mới
  hơn, tránh việc bản cũ ghi sai định dạng cấu hình.

Khung **CỔNG RA INTERNET** cho biết đường ra thật của router (thiết bị, next-hop,
IP nguồn), trạng thái link và độ trễ HTTP.

Ô **Đường ra** liệt kê mọi interface router đang có (`wan`, `wwan`, `lan`, …).
Mặc định là **Tự động** — app bám theo interface nào đang thật sự ra được
Internet, nên không phải chỉnh gì. Muốn ép đúng một đường ra thì chọn tên
interface trong danh sách; lựa chọn được lưu trên router, giữ nguyên cả khi cài
lại agent. Chọn lại **Tự động** là bỏ ghim.

Thấy vàng/đỏ thì bấm **Kiểm tra cổng ra** và báo quản trị viên trước khi Apply.

## 3 · Tab Wi-Fi / SOCKS5

Đây là nơi làm việc chính. Bảng liệt kê từng WiFi kèm băng tần, SOCKS5 đang gán,
chế độ cách ly và độ trễ proxy đo theo thời gian thực.

| Muốn làm gì | Làm thế nào |
|---|---|
| Thêm WiFi | **＋ Thêm SSID** → đặt tên, mật khẩu, chọn băng tần, nhập SOCKS5 |
| Sửa WiFi | Bấm đúp dòng, chuột phải → **Sửa cấu hình**, hoặc nút **Sửa cấu hình** ở khung *CHỈNH SỬA SSID ĐANG CHỌN* dưới bảng |
| Đổi nhanh SOCKS5 | Chuột phải → **Đổi SOCKS** (không phải mở cả form sửa) |
| Đổi MAC ngẫu nhiên | Chuột phải → **Random MAC** (giả MAC theo hãng) |
| Xoá WiFi | Chọn dòng → nút **Xoá SSID** (app hỏi lại trước khi xoá) |
| Sắp xếp bảng | Bấm vào tiêu đề cột |
| Ghi xuống router | **Đẩy cấu hình & Apply** |

**Đẩy cấu hình & Apply** luôn chạy *dry-run* trước: cấu hình sai thì app báo lỗi
và **không** ghi gì lên router. Mọi lần Apply đều tự backup trước, nên luôn có
đường lùi ở tab Backup.

Sau khi Apply, nối thử một thiết bị vào WiFi vừa tạo và kiểm tra:

- `https://ipinfo.io/ip` phải ra IP của SOCKS5 tương ứng.
- `nslookup example.com` phải trả IP trong dải `198.18.0.0/15` (fake-IP — đúng
  nghĩa là DNS đã đi qua proxy).

## 4 · Tab thiết bị

Xem thiết bị đang nối vào từng WiFi: MAC, IP, thời gian online, lưu lượng, cường
độ sóng. Bộ lọc phía trên giúp tìm nhanh theo SSID, trạng thái, băng tần, mức
sóng, lưu lượng hoặc thời lượng.

Chọn một dòng rồi dùng khung **ĐIỀU KHIỂN THIẾT BỊ ĐANG CHỌN** ở dưới:

- **Chi tiết** — xem đầy đủ thông tin thiết bị.
- **Copy IP/MAC** — chép nhanh ra clipboard.
- **Kick** — ngắt thiết bị, nó có thể nối lại ngay.
- **Cấm** — chặn MAC lâu dài; danh sách cấm được giữ qua mỗi lần Apply và cả sau
  khi khởi động lại router.
- **Bỏ cấm** — gỡ khỏi danh sách.

Trên thanh công cụ còn có **Chặn MAC…** (cấm một MAC tự nhập, không cần nó đang
online) và **Xuất CSV** (xuất danh sách đang lọc ra file). Tick **Tự làm mới** để
bảng tự cập nhật theo chu kỳ chọn ở ô bên cạnh (5s–60s).

## 4.1 · Nhiều proxy cho một Wi-Fi

**Xem và thay pool.** Ở tab Wi-Fi, chọn một SSID rồi bấm **Pool proxy…**. Bảng
hiện từng slot theo đúng thứ tự, kèm **số thiết bị đang dùng slot đó**. Ô bên
dưới nhận danh sách dán vào, mỗi dòng một proxy:

```
socks5://user:pass@1.2.3.4:1080
http://5.6.7.8:8080
user:pass@9.9.9.9:1080
10.0.0.1:3128:user:pass
10.0.0.2:1080
```

Dòng trống và dòng bắt đầu bằng `#` bị bỏ qua. Dòng nào không đọc được thì được
**liệt kê ra kèm lý do** chứ không bị âm thầm cắt bỏ.

Ghi pool **không ngắt Wi-Fi**. Máy nào đang dùng một proxy vẫn còn trong danh
sách thì **giữ nguyên proxy đó**, kể cả khi vị trí của nó trong danh sách đổi.
Chỉ máy nào có proxy bị bỏ đi mới bị chuyển.

**Đổi proxy cho nhiều máy cùng lúc.** Ở tab Thiết bị, chọn các máy (Ctrl/Shift,
hoặc Ctrl+A), rồi bấm **Đổi proxy…**. Hộp thoại hiện **bảng xem trước từng máy
sẽ đi proxy nào**; bấm Áp dụng thì đúng bảng đó được gửi đi, không tính lại.
Số máy trên mỗi proxy chênh nhau tối đa 1.

Nút bị mờ khi chưa chọn máy nào, hoặc khi các máy đã chọn **không cùng một
Wi-Fi** — slot đánh số riêng theo từng Wi-Fi nên một phép chia không trải qua
hai mạng được.

**Đổi cho một máy.** Chuột phải một dòng → **Gán proxy…** → chọn slot, hoặc
*Không ghim proxy* để bỏ ghim.

**Cột Proxy** hiện nhãn của proxy, hoặc `host:port` nếu không đặt nhãn. Bốn
trạng thái cần phân biệt:

| Hiện | Nghĩa |
|---|---|
| tên hoặc `host:port` | Máy đang được ghim và proxy đó còn tồn tại |
| `chưa ghim` | Wi-Fi có pool nhưng máy này chưa được gán |
| `slot N đã biến mất` | Máy trỏ vào slot không còn trong pool — **cần xử lý** |
| `—` | Wi-Fi này không dùng pool |

## 5 · Tab Backup / Nhật ký

- **Tải danh sách** — nạp lại danh sách backup đang có trên router.
- **Tạo backup** — chụp lại cấu hình hiện tại (mỗi lần Apply cũng tự tạo một bản).
- **Rollback backup đang chọn** — quay lại bản đã chọn (app hỏi xác nhận trước).
- Cột bên phải là **Nhật ký thao tác** của phiên làm việc.

> Backup nằm **trên router** và sẽ mất khi flash lại firmware. Cần giữ bản sao
> trên máy tính thì tải về từ console web (`http://<router>/sbproxy/` → tab
> Backup → **⭳ Về máy**) hoặc dùng LuCI *Generate archive* trước khi flash.

## 6 · Ngôn ngữ, giao diện, log

Góc trên bên phải: đổi **Ngôn ngữ** (Tiếng Việt / English) và **Giao diện**
(Dark / Light) — app nhớ lựa chọn cho lần sau.

Nút **Thư mục log** mở thư mục chứa hai file:

- `console.log` — log kỹ thuật. Báo lỗi cho quản trị viên thì gửi kèm file này.
- `audit.log` — ai kết nối và đã đổi gì: mỗi lần kết nối (router, version agent,
  trạng thái sing-box) và mọi thay đổi gửi xuống router (apply, đổi SOCKS,
  random MAC, kick/cấm/bỏ cấm, backup, rollback, cập nhật agent) kèm tên user
  trên máy và kết quả thành công hay không.

Cả hai xoay vòng **mỗi nửa đêm** và **giữ 7 ngày**; file cũ hơn bị xoá ở lần mở
app kế tiếp. Token và mật khẩu đều đã bị che. Cần chi tiết hơn thì chạy app với
`--verbose`; muốn biết app lưu dữ liệu ở đâu thì chạy `sbproxy-console --where`.

## 7 · Gặp sự cố

| Hiện tượng | Xử lý |
|---|---|
| Thanh vàng **CHƯA CẤU HÌNH ROUTER** | Chưa có token hoặc router chưa cài agent. Bấm **Kiểm tra tình trạng** để biết thiếu gì. |
| Thanh đỏ **KHÔNG CẤU HÌNH ĐƯỢC ROUTER** | Bạn đã chọn không cài agent. Bấm **Cài agent ngay** để cài, app sẽ tự mở khoá. |
| Bước **Kiểm tra kết nối SSH** lỗi | Sai IP, sai mật khẩu hoặc router chưa bật SSH. Thử `ssh root@<ip>` để thấy lỗi thật. |
| Dừng ở **Cài gói phụ thuộc** | Router chưa ra được Internet để tải gói. Kiểm tra WAN rồi chạy lại. |
| Chạy lại cài đặt có sao không? | Không. Mọi bước đều idempotent, phần nào đã có app sẽ **Bỏ qua**. |
| App báo `Security validation failure: parent process has different executable!` | Lỗi của bản exe 0.4.3 trở về trước. Tải bản **0.4.4** trở lên. |
| App báo agent version khác | Xem *Tương thích version* trong [../console/desktop/README.vi.md](../console/desktop/README.vi.md). |
| Không kết nối được Agent | Kiểm tra máy tính và router cùng mạng LAN quản trị, và token còn đúng. |

## 8 · An toàn

- Token cấp cho từng người; **không chia sẻ**, không chụp màn hình gửi đi.
- Trên Windows token được mã hoá bằng DPAPI (chỉ tài khoản Windows đó đọc được);
  trên Linux/macOS file token để quyền `600`.
- Agent chỉ nên nằm trong **LAN quản trị hoặc VPN**, tuyệt đối không mở ra WAN.
- Mật khẩu WiFi và SOCKS5 không bao giờ hiện trong log.
