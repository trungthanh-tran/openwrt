# Web console trên router — đăng nhập, giao diện, và map tính năng với bản desktop

> Bản tiếng Anh: [web-console.en.md](web-console.en.md)

Web console là trang quản trị **được phục vụ ngay từ router**, không cần cài gì
trên máy tính và không cần Internet:

```
http://<ip-router>/sbproxy/          (ví dụ: http://192.168.8.1/sbproxy/)
```

- Giao diện kiểu **AdminLTE nhẹ**: sidebar trái (điều hướng + hành động), thanh
  trên (tài khoản, trạng thái Live, ngôn ngữ VI/EN, theme sáng/tối), nội dung
  ở giữa (thẻ thống kê, bảng WiFi, xem trước cấu hình).
- Nền tảng CSS là **Bootstrap offline**: file `bootstrap.min.css` nằm ngay trên
  router tại `/www/sbproxy/assets/`, không tải từ CDN — router không có
  Internet vẫn hiển thị đúng. Nếu vì lý do nào đó thiếu file assets, trang vẫn
  chạy được bằng stylesheet dựng sẵn của chính nó.
- Toàn bộ trang là **một file HTML** (`console/web/control-panel.html` trong
  repo) + thư mục `assets/`. `install-agent.sh` và `self-update.sh` tự deploy
  cả hai vào `/www/sbproxy/`.

## 1. Đăng nhập — tài khoản riêng của sbproxy

Web console có **username/password riêng**, không dùng tài khoản root của
router và không phải dán token thủ công.

### Tài khoản được tạo khi nào? (first-run setup)

**Ở lần mở web đầu tiên.** Khi router chưa có tài khoản, trang tự mở form
**"Tạo tài khoản quản trị đầu tiên"** (user mặc định `admin`; mật khẩu ≥ 8 ký
tự, nhập 2 lần) — tạo xong là đăng nhập luôn. Phía agent, action
`setup_account` **chỉ chạy được khi chưa có tài khoản nào**: đã có tài khoản
thì mọi yêu cầu tạo đều bị từ chối (403), nên không ai "tạo đè" được; đường
khôi phục duy nhất là SSH (`sbproxy-webauth`).

Cài đặt tự động (không cần mở web) vẫn có thể tạo sẵn tài khoản bằng biến môi
trường khi chạy `install-agent.sh`:

```sh
SBPROXY_WEB_USER=admin SBPROXY_WEB_PASS='mat-khau-cua-ban' sh agent/install-agent.sh
```

### Đổi mật khẩu

- **Trong UI**: 🔌 Kết nối router → nút **🔑 Đổi mật khẩu** (hiện khi đã kết
  nối) → nhập mật khẩu hiện tại + mật khẩu mới (2 lần). Cần cả token đang
  đăng nhập **lẫn** mật khẩu hiện tại, nên trình duyệt chỉ giữ token không tự
  chiếm được tài khoản. Sai mật khẩu hiện tại bị chờ ~1 giây và ghi syslog.
- **Trên router (SSH)**: `sbproxy-webauth set <user>` — đây cũng là cách
  khôi phục khi quên mật khẩu.

### Đăng nhập trên trang

Bấm **🔌 Kết nối router** → nhập **Tên đăng nhập / Mật khẩu** → **Kết nối**.
Trang gọi `?action=login`; đúng mật khẩu thì agent trả về token API, trang lưu
token đó trong trình duyệt (localStorage) và từ đây mọi thao tác dùng token như
trước. Tên tài khoản hiện ở góc phải thanh trên (👤).

- **Đăng xuất**: trong hộp Kết nối — xoá token + tên tài khoản khỏi trình
  duyệt; người dùng sau phải biết mật khẩu.
- **Ngắt**: chỉ tạm ngừng kết nối, token vẫn được nhớ.
- **Nâng cao**: vẫn có ô Token để dán token trực tiếp (cách cũ), và ô Base URL
  khi mở trang từ nơi khác thay vì từ router.

### Quản lý tài khoản trên router (`sbproxy-webauth`)

```sh
sbproxy-webauth set admin          # đổi mật khẩu (hỏi trên terminal)
echo 'mat-khau-moi' | sbproxy-webauth set admin -   # đặt qua pipe
sbproxy-webauth show               # in ra username đang cấu hình
sbproxy-webauth disable            # tắt đăng nhập mật khẩu (chỉ còn token)
```

- File lưu: `/etc/sbproxy/webauth`, quyền `600`, dạng
  `user:salt:sha256(salt:password)` — **mật khẩu thật không bao giờ được ghi
  ra đĩa**.
- Mật khẩu tối thiểu 8 ký tự.
- **Quên mật khẩu**: SSH vào router và chạy `sbproxy-webauth set admin`;
  hoặc `sbproxy-webauth disable` rồi mở lại web — trang sẽ yêu cầu tạo tài
  khoản mới như lần đầu.

### Chống dò mật khẩu

- Mỗi lần sai mật khẩu, agent chờ ~1 giây rồi mới trả lời và ghi một dòng vào
  syslog (`logger -t sbproxy`).
- Sai **5 lần trong 5 phút** → `429 Too Many Requests`, khoá thao tác login
  (kể cả nhập đúng) cho tới khi hết cửa sổ 5 phút. Đăng nhập thành công xoá
  bộ đếm.
- `login` là action **duy nhất** không cần token; mọi action khác vẫn đòi
  `Authorization: Bearer <token>` như cũ.

### Lưu ý bảo mật

- Chỉ mở web console trong **LAN quản trị**. Tuyệt đối không expose port 80
  của router ra WAN.
- Trang chạy qua **http** (uhttpd mặc định). Nếu mở bản console từ một trang
  https khác, trình duyệt sẽ chặn gọi router (mixed content) — hãy mở đúng
  `http://<router>/sbproxy/`.
- Token API vẫn là chìa khoá gốc (desktop dùng trực tiếp). Đổi token: xoá
  `/etc/sbproxy/token` rồi chạy lại `install-agent.sh`.

## 2. Bố cục màn hình

| Vùng | Nội dung |
|---|---|
| **Sidebar — Cấu hình** | ＋ Thêm WiFi · ⤓ Nhập .conf · ⭳ Tải wifi-socks.conf · ⭳ Tải JSON · ✕ Xoá hết (chỉ xoá trên trình duyệt) |
| **Sidebar — Router** (hiện khi đã kết nối) | ⇪ Đẩy & Áp · 📱 Thiết bị · ⭳ Tải từ router · 🗂 Backup/Rollback · 🌐 Đường ra · ⬆ Cập nhật · ⟲ Reset toàn bộ |
| **Thanh trên** | ☰ menu (mobile) · phiên bản UI/agent · 👤 tài khoản · Live · ngôn ngữ · 🔌 Kết nối · ◐ Theme |
| **Nội dung** | Thẻ thống kê (số WiFi, BSSID theo băng, SOCKS, cách ly/WebRTC) · bảng WiFi (health, sparkline, ⚡ đổi sock, 🩺 chẩn đoán, sửa/nhân bản/xoá) · tab xem trước `wifi-socks.conf` / `sing-box config.json` / `sbproxy.nft` |

## 3. Map tính năng: desktop (.exe) ↔ web console

Cả hai bản nói chuyện với **cùng một agent CGI** trên router, nên tính năng là
tương đương trừ vài mục ghi chú dưới đây.

| Tính năng | Desktop (sbproxy-console) | Web (`/sbproxy/`) | Action agent |
|---|---|---|---|
| Kết nối / xác thực | Token (tự lấy qua SSH khi cài router) | **User/pass riêng** (`login`) hoặc token (Nâng cao) | `login`, `status` |
| Cài router từ đầu qua SSH (đẩy code, deps, agent) | ✅ | ❌ (việc của desktop/CLI) | — (SSH) |
| Thêm / sửa / xoá / nhân bản SSID | ✅ | ✅ | — (local) + `save_conf` |
| Nhập / xuất `wifi-socks.conf`, JSON | ✅ | ✅ | `get_conf` |
| Đẩy & Áp (validate rồi apply) | ✅ | ✅ | `dryrun_conf`, `save_conf`, `apply` |
| Đổi SOCKS 1 SSID không reload WiFi (⚡) | ✅ | ✅ | `set_sock` |
| Health + độ trễ từng SSID, sparkline | ✅ | ✅ | `status` |
| Chẩn đoán đường dữ liệu 1 SSID (🩺) | ✅ | ✅ | `diagnose_ssid` |
| Test 1 proxy từ router, kèm lý do fail (🧪) | ✅ (Pool, thêm proxy) | ✅ (nút trong form Thêm/Sửa WiFi) | `probe_proxy` |
| Thiết bị: xem, kick, cấm, bỏ cấm | ✅ | ✅ | `clients`, `kick`, `ban`, `unban` |
| Backup / tải backup về máy / rollback | ✅ | ✅ | `backups`, `backup`, `download_backup`, `rollback` |
| Đường ra Internet: xem + đổi uplink | ✅ | ✅ | `gateway`, `switch_gateway` |
| Reset toàn bộ (kick hết, xoá hết, apply) | ✅ | ✅ (hành vi được test giống hệt desktop) | `kick`, `save_pool`, `save_conf`, `apply` |
| Cập nhật agent bằng package .tar.gz/.zip | ✅ | ✅ | `update` |
| Đổi MAC/BSSID (rotate) | ✅ | ❌ (API có sẵn, UI chưa có) | `rotate_mac` |
| **Pool proxy** per-SSID: slots, gán MAC, rebalance | ✅ (màn hình Pool) | ❌ (chỉ xoá pool khi Reset; UI pool chưa có) | `get_pool`, `save_pool`, `assign_proxy`, `rebalance` |
| Sửa lỗi SSH host key (dialog hướng dẫn) | ✅ | — (web không dùng SSH) | — |
| Ngôn ngữ VI/EN, theme sáng/tối | ✅ | ✅ | — |

Hai chỗ web còn thiếu (rotate MAC, màn hình Pool) đều đã có API phía agent —
chỉ là chưa có UI; dùng bản desktop cho các thao tác đó.

## 4. Khắc phục sự cố

| Hiện tượng | Nguyên nhân / cách xử lý |
|---|---|
| `403 — chưa có tài khoản web` (`setup_required`) | Router chưa có `/etc/sbproxy/webauth`: trang sẽ tự mở form **Tạo tài khoản quản trị đầu tiên**. Nếu không thấy form: SSH `sbproxy-webauth set admin`, hoặc dùng token ở mục Nâng cao. |
| `401 — mật khẩu hiện tại không đúng` (đổi mật khẩu) | Nhập lại mật khẩu đang dùng; quên → SSH `sbproxy-webauth set <user>`. |
| `401 — sai tên đăng nhập hoặc mật khẩu` | Kiểm tra lại; mật khẩu in ra lúc cài agent. Quên → `sbproxy-webauth set admin`. |
| `429 — sai mật khẩu quá 5 lần` | Chờ 5 phút, hoặc SSH xoá `/tmp/sbproxy-weblock`. |
| Trang trắng kiểu chữ đơn giản, không có sidebar đẹp | Thiếu `/www/sbproxy/assets/bootstrap.min.css` — chạy lại `install-agent.sh` hoặc `self-update`. Trang vẫn dùng được. |
| `Mất kết nối … mixed-content?` | Đang mở trang qua https. Mở đúng `http://<router>/sbproxy/`. |
| Agent cũ không có action `login` | Cập nhật agent (⬆ Cập nhật bằng token, hoặc `self-update.sh`), hoặc đăng nhập bằng token. |
