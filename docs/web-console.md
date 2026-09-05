# Web console trên router — khởi tạo, kết nối, cập nhật và sử dụng

> Bản tiếng Anh: [web-console.en.md](web-console.en.md)
>
> Muốn một quy trình độc lập có thể copy từng lệnh từ router mới đến vận hành
> hằng ngày, xem [Deploy và sử dụng sbproxy Web từ đầu](WEB-DEPLOY.md).

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

## 1. Khởi tạo router từ đầu (5 bước)

Phần này dành cho người **không dùng file .exe**: từ một router vừa flash đến
lúc mở được web console. Bản desktop làm toàn bộ những việc này giúp bạn trong
một màn hình — nếu có sẵn file exe thì đi theo
[QUICKSTART.md](QUICKSTART.md) (4 bước) sẽ nhanh hơn; các lệnh dưới đây là
**chính xác những gì file exe chạy qua SSH**.

> **Trước khi bắt đầu**: cắm **LAN dây** từ máy tính vào router (đường cứu hộ
> nếu WiFi hỏng giữa chừng), và **tải backup về máy** nếu router đang chạy gì
> đó — backup nằm trên router sẽ mất khi flash.

### Bước 1 — Flash firmware và đặt mật khẩu root

Hai việc này phải làm tay vì có rủi ro vật lý (chọn sai image là brick router).
Làm theo **Bước 2 và Bước 3** của [QUICKSTART.md](QUICKSTART.md).

Kiểm tra xong bước này bằng: `ssh root@192.168.8.1` — đăng nhập được là đạt.

> IP quản trị: firmware GL.iNet mặc định `192.168.8.1`; OpenWrt vanilla vừa
> flash thường là `192.168.1.1`. Dùng đúng IP thực tế ở các bước sau.

### Bước 2 — Đưa mã nguồn lên router

Từ máy tính có sẵn mã nguồn (thư mục repo này):

```sh
sh pc/update.sh --host 192.168.8.1          # Linux/macOS/Git Bash
```
```powershell
pc\update.ps1 -Host 192.168.8.1             # Windows PowerShell
```

Lệnh này đóng gói repo, đẩy lên `/root/sbproxy` và **giữ nguyên**
`wifi-socks.conf` + `settings.sh` nếu router đã có.

Chỉ có file package (`sbproxy-update-<version>.tar.gz`) thì làm tay:

```sh
scp sbproxy-update-*.tar.gz root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'mkdir -p /root/sbproxy && tar xzf /tmp/sbproxy-update-*.tar.gz -C /root/sbproxy'
```

### Bước 3 — Kiểm tra phần cứng (chỉ đọc, không đổi gì)

```sh
ssh root@192.168.8.1
cd /root/sbproxy
sh scripts/preflight.sh
```

Đọc hai mục quan trọng:

- **Radio ↔ băng tần**: nếu `radio0` không phải 2.4 GHz, sửa `RADIO_2G` /
  `RADIO_5G` trong `config/settings.sh`.
- **valid interface combinations**: số AP tối đa mỗi radio. Số SSID định tạo
  phải ≤ số này.

Đặt luôn mã quốc gia trong `config/settings.sh` (bắt buộc):
`WIFI_COUNTRY="VN"`.

### Bước 4 — Cài và khởi tạo (3 lệnh)

```sh
cd /root/sbproxy
# Cấu hình rỗng: SSID sẽ thêm từ web console sau, không cần soạn tay.
grep '^#' config/wifi-socks.conf.example > config/wifi-socks.conf
sh scripts/install-deps.sh      # nftables, sing-box, ip-full, iw-full… + init script
sh scripts/apply.sh             # tự backup trước, rồi áp cấu hình
sh agent/install-agent.sh       # CGI + web console + healthd + assignd
```

`install-deps.sh` là bước lâu nhất (vài phút, router phải ra được Internet để
tải gói). Cả bốn lệnh đều **chạy lại được nhiều lần** — phần nào đã xong sẽ
được bỏ qua.

Cuối màn hình `install-agent.sh` in ra địa chỉ web console và ghi rõ rằng
**tài khoản sẽ được tạo ở lần mở web đầu tiên**.

### Bước 5 — Mở web console và tạo tài khoản

Mở `http://192.168.8.1/sbproxy/` → trang tự hiện form **"Tạo tài khoản quản
trị đầu tiên"** → đặt user (mặc định `admin`) và mật khẩu ≥ 8 ký tự → xong là
vào thẳng màn hình điều khiển.

Từ đây thêm WiFi và proxy hoàn toàn trong trình duyệt: xem
[§5.1 Thêm và áp một WiFi mới](#51-thêm-và-áp-một-wifi-mới).

### Kiểm tra sau khi cài

```sh
sh scripts/doctor.sh        # báo cáo trạng thái toàn hệ thống, chỉ đọc
```

Nối một thiết bị vào SSID vừa tạo rồi kiểm tra:
`https://ipinfo.io/ip` phải ra IP của proxy tương ứng, và `nslookup
example.com` phải trả IP trong dải `198.18.0.0/15` (fake-IP). Danh sách kiểm
tra đầy đủ: [TESTING.md](TESTING.md).

### Nếu hỏng giữa chừng

| Hiện tượng | Xử lý |
|---|---|
| `ssh` không vào được | Sai IP, chưa đặt mật khẩu root, hoặc SSH chưa bật. |
| `install-deps.sh` dừng khi tải gói | Router chưa ra được Internet (cần WAN). Kiểm tra uplink rồi chạy lại. |
| `preflight.sh` báo sai mapping radio | Sửa `RADIO_2G`/`RADIO_5G` trong `config/settings.sh` đúng như preflight gợi ý. |
| `apply.sh` báo lỗi | Router **đã tự backup trước khi áp**: `sh scripts/rollback.sh` để quay lại. Xem [ROLLBACK.md](ROLLBACK.md). |
| Mất mạng sau khi áp | Vào bằng LAN dây rồi `sh scripts/rollback.sh`. |
| Muốn gỡ sạch | `sh scripts/uninstall.sh`. |

## 2. Kết nối và đăng nhập — tài khoản riêng của sbproxy

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

## 3. Cập nhật

Có ba đường cập nhật, dùng cái nào tuỳ chỗ bạn đang đứng.

### 3.1 Từ web console (không cần SSH)

Cách thông thường cho người vận hành:

1. Trên máy có mã nguồn, tạo package: `make package` (hoặc
   `sh pc/make-package.sh`) → ra file `sbproxy-update-<version>.tar.gz`.
2. Web console → **⬆ Cập nhật** → chọn file → **⬆ Cập nhật**.

Router **tự backup trước**, kiểm tra package hợp lệ, **chặn hạ version** (trừ
khi tick *Cho phép hạ version*), rồi thay mã nguồn và deploy lại CGI, giao
diện web, `sbproxy-webauth`, healthd.

**Được giữ nguyên**: `wifi-socks.conf`, `proxy-pools.conf`, `settings.sh`
(khoá mới của phiên bản mới được *thêm* vào, giá trị bạn đặt không bị ghi đè),
token, tài khoản web, danh sách cấm, ghim proxy và lịch sử thiết bị.

**Cập nhật KHÔNG reload WiFi.** Cấu hình chỉ thực sự đổi khi bạn bấm
**⇪ Đẩy & Áp** sau đó.

### 3.2 Từ máy tính qua SSH

Khi bạn đang sửa mã nguồn và muốn đẩy thẳng:

```sh
sh pc/update.sh --host 192.168.8.1            # chỉ đẩy code
sh pc/update.sh --host 192.168.8.1 --apply    # đẩy code rồi chạy apply.sh luôn
```

Mặc định giữ nguyên `wifi-socks.conf` và `settings.sh` trên router; thêm
`--with-settings` nếu thực sự muốn thay `settings.sh`.

Sau khi đẩy code mới mà agent/giao diện web chưa đổi theo, chạy lại
`sh agent/install-agent.sh` trên router (không đụng tới token, tài khoản hay
cấu hình đang chạy).

### 3.3 Ngay trên router

```sh
cd /root/sbproxy
sh scripts/self-update.sh /tmp/sbproxy-update-<version>.tar.gz
```

Đây chính là script mà nút **⬆ Cập nhật** gọi, nên hành vi giống hệt mục 3.1.

### Sau khi cập nhật

- Thanh trên hiện `v<UI> · agent v<agent>`. Hai số **khác nhau** thì dòng này
  chuyển màu vàng — nghĩa là trình duyệt còn giữ bản UI cũ: tải lại trang
  (Ctrl+F5) là hết.
- Muốn chắc chắn: **🗂 Backup / Rollback → 💾 Tạo backup ngay** trước khi cập
  nhật, và **⭳ Về máy** trước khi nâng cấp *firmware* (backup nằm trên router
  sẽ mất nếu reflash).

## 4. Bố cục màn hình

| Vùng | Nội dung |
|---|---|
| **Sidebar — Cấu hình** | ＋ Thêm WiFi · ⤓ Nhập .conf · ⭳ Tải wifi-socks.conf · ⭳ Tải JSON · ✕ Xoá hết (chỉ xoá trên trình duyệt) |
| **Sidebar — Router** (hiện khi đã kết nối) | ⇪ Đẩy & Áp · 📱 Thiết bị · ⭳ Tải từ router · 🗂 Backup/Rollback · 🌐 Đường ra · ⬆ Cập nhật · ⟲ Reset toàn bộ |
| **Thanh trên** | ☰ menu (mobile) · phiên bản UI/agent · 👤 tài khoản · Live · ngôn ngữ · 🔌 Kết nối · ◐ Theme |
| **Nội dung** | Thẻ thống kê (số WiFi, BSSID theo băng, SOCKS, cách ly/WebRTC) · bảng WiFi (health, sparkline, ⚡ đổi sock, 🩺 chẩn đoán, 🎲 đổi MAC, pool, sửa/nhân bản/xoá) · tab xem trước `wifi-socks.conf` / `sing-box config.json` / `sbproxy.nft` |

## 5. Dùng hằng ngày

### 5.1 Thêm và áp một WiFi mới

1. **＋ Thêm WiFi** → điền tên, băng tần, idx, mật khẩu WiFi (≥ 8 ký tự) và
   proxy. Ô **Nhập nhanh proxy** nhận `host:port:user:password`, bấm **Tách**
   là tự điền vào 4 ô.
2. Bấm **🧪 Test proxy** (khi đã kết nối router) để thử proxy đó **từ router**
   trước khi lưu — kết quả nói rõ lý do fail, không chỉ "fail".
3. **Lưu** → **⇪ Đẩy & Áp lên router**. Quy trình 3 bước giống hệt bản desktop:
   dry-run → ghi conf → apply. Dry-run hỏng thì cấu hình đang chạy **không bị
   đụng tới**.

### 5.2 Đổi proxy nhanh, không reload WiFi

- **⚡** trên hàng WiFi: đổi SOCKS của riêng SSID đó (`set_sock`). WiFi không
  reload, chỉ phiên đang mở có thể gián đoạn.
- **🎲**: cấp BSSID/MAC ngẫu nhiên mới cho SSID đó, chọn được hãng (OUI) như
  bản desktop. WiFi này reload nên **mọi thiết bị trên nó phải kết nối lại**.

### 5.3 Pool proxy cho một SSID

Mở bằng nút **pool** trên hàng WiFi.

- **Dán proxy**: mỗi dòng một proxy. Chọn **định dạng nhà cung cấp** (tự động
  nhận dạng, `host:port:user:pass`, `user:pass@host:port`, `host:port`,
  `host,port,user,pass`, `host;port;user;pass`, `socks5://user:pass@host:port`)
  và loại proxy (SOCKS5/HTTP), rồi **Thêm vào pool**. Dòng không đọc được sẽ
  được liệt kê ra để bạn quyết định, không bị bỏ qua âm thầm.
- **Test proxy**: thử toàn bộ pool từ router, mỗi slot hiện OK/FAIL.
- **Xoá slot đã nhập**: gõ số slot (`0,2,5`) rồi bấm. Slot đang có thiết bị
  online dùng sẽ **bị từ chối** — đúng như bản desktop, tránh việc âm thầm đẩy
  máy người khác sang proxy lạ.
- **Xóa pool**: xoá sạch pool của SSID này.
- **Rebalance client**: chia đều thiết bị đang online của SSID lên các slot.

### 5.4 Màn hình Thiết bị

Danh sách gồm **mọi máy đã từng vào WiFi**, không chỉ máy đang kết nối:

| Trạng thái | Ý nghĩa |
|---|---|
| `đang kết nối 5p 12s` | Đang liên kết, kèm thời lượng phiên hiện tại |
| `đã ngắt 2g 15p` | Từng vào, hiện không liên kết, kèm thời gian đã rời đi |
| `bị cấm` | MAC nằm trong danh sách chặn của SSID |

- **Lọc**: theo WiFi, theo trạng thái, và ô tìm kiếm (MAC/IP/tên máy/SSID).
  Lọc và sắp xếp chạy trên dữ liệu đã tải — không gọi lại router.
- **Sắp xếp**: bấm vào tiêu đề cột (bấm lần nữa để đảo chiều).
- **Tự làm mới**: bật/tắt và chọn nhịp 5/10/30/60 giây.
- **Dòng tóm tắt**: số máy đang hiện / đang kết nối / bị cấm / tổng đã từng vào
  / tổng lưu lượng.
- Nút trên mỗi hàng: **Kick** (ngắt tạm, chỉ máy đang online), **Cấm** (chặn
  MAC lâu dài — reload băng tần đó), **Bỏ cấm**, **Đổi proxy** (chọn slot pool
  hoặc `none` để bỏ ghim), **ℹ Chi tiết** (IP, tên máy, lần đầu/lần cuối thấy,
  sóng, lưu lượng, proxy đang ghim, interface).
- **⛔ Chặn MAC…**: cấm trước một MAC **chưa từng kết nối**.
- **⭳ Xuất CSV**: xuất đúng những dòng đang hiển thị (UTF-8 có BOM, mở Excel
  không lỗi font).

> **Lịch sử thiết bị đến từ đâu?** Router ghi mỗi lần thấy máy vào
> `/tmp/sbproxy.seen` (RAM, ghi mỗi lần poll nên không mòn flash) và chỉ chép
> sang `/etc/sbproxy.seen` **khi có máy mới lần đầu** — nên lịch sử sống sót
> qua reboot và qua sysupgrade với vài lần ghi flash mỗi máy. Giới hạn mặc
> định 400 máy (`SEEN_MAX` trong `config/settings.sh`), máy cũ nhất bị loại
> trước.

### 5.5 Đường ra Internet

- **Đổi đường ra**: chọn interface rồi bấm — interface đó nhận metric tốt nhất,
  các đường khác lùi lại, network reload. WiFi và proxy không đổi.
- **📌 Ghim**: chỉ ghi nhớ interface nào là đường ra **mong đợi**; không đổi gì
  trên router, nhưng nếu router trôi sang đường khác thì phần kiểm tra sẽ báo
  sai lệch.
- **Tự động**: bỏ ghim, chấp nhận bất kỳ đường ra nào default route đang dùng.

### 5.6 Backup, cập nhật, reset

- **🗂 Backup / Rollback**: tạo backup (có hỏi nhãn, chỉ nhận chữ/số/`. _ -`),
  **⭳ Về máy** (tải file backup về máy tính — làm việc này **trước khi flash
  firmware**), **↩ Khôi phục**.
- **⬆ Cập nhật**: đẩy package `.tar.gz`/`.zip` lên router. Không reload WiFi.
- **⟲ Reset toàn bộ**: đá mọi thiết bị, xoá mọi SSID và pool, apply. Đọc cấu
  hình thật từ router trước khi cảnh báo, và phải gõ `RESET` mới chạy.

### 5.7 Nhật ký debug

- Mở **▤ Nhật ký** trong nhóm Router, chọn ngày để xem hoặc **Copy**.
- Bấm **Tải gói debug** để lấy file `sbproxy-debug-YYYY-MM-DD.txt`; có thể gửi
  file này sang máy khác để phân tích mà không cần truy cập trực tiếp router.
- Log được tách theo ngày trong `/etc/sbproxy/logs`, chỉ giữ 7 ngày và tự xoá
  file cũ. Log không ghi mật khẩu Wi-Fi, mật khẩu proxy hoặc token API.
- Gói debug gồm phiên bản, uptime, dung lượng, route, trạng thái dịch vụ, log
  sbproxy theo ngày và syslog gần nhất của sbproxy/sing-box.

## 6. Map tính năng: desktop (.exe) ↔ web console

Cả hai bản nói chuyện với **cùng một agent CGI** trên router, nên tính năng là
tương đương trừ vài mục ghi chú dưới đây.

| Tính năng | Desktop (sbproxy-console) | Web (`/sbproxy/`) | Action agent |
|---|---|---|---|
| Kết nối / xác thực | Token (tự lấy qua SSH khi cài router) | **User/pass riêng** (`login`) hoặc token (Nâng cao) | `login`, `status` |
| Cài router từ đầu qua SSH (đẩy code, deps, agent) | ✅ | ❌ (việc của desktop/CLI) | — (SSH) |
| Thêm / sửa / xoá / nhân bản SSID | ✅ | ✅ | — (local) + `save_conf` |
| Nhập / xuất `wifi-socks.conf`, JSON | ✅ | ✅ | `get_conf` |
| Đẩy & Áp: dry-run → ghi → apply | ✅ | ✅ | `dryrun_conf`, `save_conf`, `apply` |
| Đổi SOCKS 1 SSID không reload WiFi (⚡) | ✅ | ✅ | `set_sock` |
| Đổi MAC/BSSID ngẫu nhiên, chọn hãng (🎲) | ✅ | ✅ | `rotate_mac` |
| Health + độ trễ từng SSID, sparkline | ✅ | ✅ | `status` |
| Chẩn đoán đường dữ liệu 1 SSID (🩺) | ✅ | ✅ | `diagnose_ssid` |
| Test 1 proxy từ router, kèm lý do fail (🧪) | ✅ | ✅ (form WiFi + Test cả pool) | `probe_proxy` |
| **Pool proxy**: xem, thêm nhiều định dạng, xoá slot chọn lọc, xoá cả pool | ✅ | ✅ | `get_pool`, `save_pool` |
| Pool: gán proxy cho 1 thiết bị / bỏ ghim | ✅ | ✅ (nút **Đổi proxy** ở màn Thiết bị) | `assign_proxy` |
| Pool: chia đều thiết bị lên các slot | ✅ (chỉ trong code) | ✅ (**Rebalance client**) | `rebalance` |
| Thiết bị: xem, kick, cấm, bỏ cấm | ✅ | ✅ | `clients`, `kick`, `ban`, `unban` |
| Thiết bị: lịch sử máy đã từng kết nối + trạng thái | ✅ | ✅ | `clients` |
| Thiết bị: lọc, sắp xếp, tóm tắt, tự làm mới theo nhịp | ✅ | ✅ | — |
| Thiết bị: chi tiết một máy | ✅ | ✅ (**ℹ**) | — |
| Thiết bị: xuất CSV | ✅ | ✅ | — |
| Thiết bị: chặn trước một MAC chưa kết nối | ✅ | ✅ (**⛔ Chặn MAC…**) | `ban` |
| Backup (có nhãn) / tải về máy / rollback | ✅ | ✅ | `backups`, `backup`, `download_backup`, `rollback` |
| Đường ra: xem, đổi uplink, ghim / bỏ ghim | ✅ | ✅ | `gateway`, `switch_gateway`, `set_gateway` |
| Reset toàn bộ (kick hết, xoá hết, apply) | ✅ | ✅ (hành vi được test giống hệt desktop) | `kick`, `save_pool`, `save_conf`, `apply` |
| Cập nhật agent bằng package .tar.gz/.zip | ✅ | ✅ | `update` |
| Log theo ngày, xem/copy/tải gói debug, giữ 7 ngày | ✅ | ✅ | `logs`, `download_logs` |
| Ngôn ngữ VI/EN, theme sáng/tối | ✅ | ✅ | — |
| Sửa lỗi SSH host key, thư mục log, lưu token bằng DPAPI | ✅ | — (không áp dụng cho trình duyệt) | — |

Phần còn lại chỉ có ở desktop là những thứ **bản chất không chạy được trong
trình duyệt**: cài router qua SSH, mã hoá token bằng Windows DPAPI, mở thư mục
log cục bộ, và các chế độ dòng lệnh (`--provision`, `--probe`).
`tests/run.sh` có một khối kiểm tra riêng khoá lại từng dòng "✅" ở cột web
trong bảng trên, nên một tính năng bị gỡ đi sẽ làm đỏ test.

## 7. Khắc phục sự cố

| Hiện tượng | Nguyên nhân / cách xử lý |
|---|---|
| `403 — chưa có tài khoản web` (`setup_required`) | Router chưa có `/etc/sbproxy/webauth`: trang sẽ tự mở form **Tạo tài khoản quản trị đầu tiên**. Nếu không thấy form: SSH `sbproxy-webauth set admin`, hoặc dùng token ở mục Nâng cao. |
| `401 — mật khẩu hiện tại không đúng` (đổi mật khẩu) | Nhập lại mật khẩu đang dùng; quên → SSH `sbproxy-webauth set <user>`. |
| `401 — sai tên đăng nhập hoặc mật khẩu` | Kiểm tra lại; mật khẩu in ra lúc cài agent. Quên → `sbproxy-webauth set admin`. |
| `429 — sai mật khẩu quá 5 lần` | Chờ 5 phút, hoặc SSH xoá `/tmp/sbproxy-weblock`. |
| Trang trắng kiểu chữ đơn giản, không có sidebar đẹp | Thiếu `/www/sbproxy/assets/bootstrap.min.css` — chạy lại `install-agent.sh` hoặc `self-update`. Trang vẫn dùng được. |
| `Mất kết nối … mixed-content?` | Đang mở trang qua https. Mở đúng `http://<router>/sbproxy/`. |
| Agent cũ không có action `login` | Cập nhật agent (⬆ Cập nhật bằng token, hoặc `self-update.sh`), hoặc đăng nhập bằng token. |
