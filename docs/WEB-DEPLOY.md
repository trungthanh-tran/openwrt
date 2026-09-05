# Deploy và sử dụng sbproxy Web từ đầu

Tài liệu này dành cho người muốn cài sbproxy lên router OpenWrt và vận hành
hoàn toàn bằng trình duyệt. Ví dụ dùng router `192.168.8.1`; nếu router của bạn
dùng IP khác, thay IP đó trong tất cả lệnh.

Web console sau khi cài:

```text
http://192.168.8.1/sbproxy/
```

![Tổng quan Web Console](images/web-dashboard.png)

> Chỉ mở web trong LAN/VLAN quản trị. Không NAT hoặc công khai uhttpd, CGI hay
> cổng quản trị của router ra Internet.

## 1. Chuẩn bị

- Router GL-MT6000 chạy OpenWrt và có kết nối Internet qua WAN.
- Máy tính nối LAN dây với router. LAN dây là đường cứu hộ nếu cấu hình Wi-Fi
  chưa đúng.
- Đã đặt mật khẩu `root` và SSH được vào router.
- Máy tính có Git, SSH và `tar`. Windows 10/11 đã có OpenSSH và `tar`; chạy các
  lệnh bên dưới bằng PowerShell.

Kiểm tra SSH:

```powershell
ssh root@192.168.8.1
```

Nếu đây là router đang sử dụng, hãy backup trước khi cài:

```powershell
ssh root@192.168.8.1 "sysupgrade -b /tmp/openwrt-before-sbproxy.tar.gz"
scp root@192.168.8.1:/tmp/openwrt-before-sbproxy.tar.gz .
```

## 2. Cách nhanh: dùng gói deploy theo hệ điều hành

Tải một trong các file:

- Windows x64 chạy ngay: `sbproxy-web-deployer-<version>-windows-x64.exe`.
- Windows x64 quản lý đầy đủ + tài liệu: `sbproxy-console-<version>-windows-x64.zip`.
- Linux: `sbproxy-web-deploy-<version>-linux-<arch>.tar.gz`.

Chạy `sbproxy-web-deployer.exe` trên Windows hoặc `./sbproxy-web-deployer` trên
Linux. Đây là tiện ích triển khai riêng,
không phải console điều khiển và không có chức năng sửa Wi-Fi, device hay proxy.

1. Điền **Router IP / host**, **SSH port**, **Username** và **Password**.
2. Bấm **Kiểm tra router** để xác nhận SSH và xem thành phần đang có.
3. Bấm **Cài / Cập nhật**. EXE tự đẩy gói sbproxy đã nhúng, cài phần còn thiếu,
   deploy Web/Agent và kiểm tra Agent API.
4. Khi hoàn tất, trình duyệt tự mở `http://<router>/sbproxy/`. Có thể mở lại bằng
   nút **Mở Web Console**.

Mật khẩu SSH chỉ nằm trong bộ nhớ của phiên chạy và không được lưu xuống máy.
Khi cập nhật router đã cài, công cụ giữ nguyên `wifi-socks.conf`,
`proxy-pools.conf`, `settings.sh`, không apply lại Wi-Fi. Khi cài router mới,
công cụ tạo cấu hình rỗng an toàn rồi cài đủ Web/Agent.

Build trọn gói từ mã nguồn:

```powershell
.\console\deployer\package-windows.ps1
```

```sh
sh console/deployer/package-linux.sh
```

Kết quả nằm tại `dist/release/`. Máy sử dụng gói không cần Git, Python hay source
code; chỉ cần SSH client và kết nối LAN tới router. Xem thêm
[hướng dẫn Web Deployer bằng hình ảnh](WEB-DEPLOYER.md),
[cấu trúc gói release](RELEASE-ARTIFACTS.md) và
[README của Web Deployer](../console/deployer/README.md).

## 3. Cài mới thủ công từ Windows

### 3.1 Lấy mã nguồn và đưa lên router

```powershell
git clone https://github.com/trungthanh-tran/openwrt.git sbproxy
cd sbproxy
.\pc\update.ps1 -RouterHost 192.168.8.1
```

Mã nguồn được đặt tại `/root/sbproxy`. Lệnh này chưa thay đổi Wi-Fi đang chạy.

### 3.2 Kiểm tra phần cứng và mã quốc gia

```powershell
ssh root@192.168.8.1
```

Chạy trên router:

```sh
cd /root/sbproxy
sh scripts/preflight.sh
```

Kiểm tra hai mục trong kết quả:

- `radio0`/`radio1` có đúng với 2.4 GHz và 5 GHz không. Nếu sai, sửa
  `RADIO_2G` và `RADIO_5G` trong `config/settings.sh`.
- `valid interface combinations` cho biết số SSID tối đa trên mỗi radio.

Đặt `WIFI_COUNTRY` thành mã quốc gia nơi router hoạt động, ví dụ:

```sh
sed -i 's/^WIFI_COUNTRY=.*/WIFI_COUNTRY="VN"/' config/settings.sh
```

### 3.3 Tạo cấu hình rỗng và cài các thành phần

Với router cài mới, tạo file cấu hình chỉ chứa phần chú thích, sau đó cài phụ
thuộc và agent web:

```sh
sed -n '/^[[:space:]]*#/p' config/wifi-socks.conf.example > config/wifi-socks.conf
sh scripts/install-deps.sh
sh scripts/apply.sh
sh agent/install-agent.sh
```

Các lệnh trên thực hiện:

- Cài nftables/TPROXY, sing-box, `ip-full`, `iw-full` và init service.
- Tạo cấu hình chạy ban đầu và backup tự động.
- Cài API tại `/www/cgi-bin/sbproxy`.
- Cài web tại `/www/sbproxy/` cùng CSS offline.
- Cài và bật `sbproxy-healthd` cùng `sbproxy-assignd`.
- Tạo token API và vùng log `/etc/sbproxy/logs`.

Có thể chạy lại installer nếu bị gián đoạn; cấu hình, token và tài khoản web cũ
được giữ lại.

## 4. Cài thủ công từ Linux hoặc macOS

Các bước trên router giống mục 3. Chỉ thay lệnh upload:

```sh
git clone https://github.com/trungthanh-tran/openwrt.git sbproxy
cd sbproxy
sh pc/update.sh --host 192.168.8.1
ssh root@192.168.8.1
```

Sau đó chạy các lệnh trong mục 3.2 và 3.3 trên router.

## 5. Mở web và tạo tài khoản lần đầu

1. Mở `http://192.168.8.1/sbproxy/` bằng trình duyệt.
2. Khi hiện **Tạo tài khoản quản trị đầu tiên**, nhập username và mật khẩu tối
   thiểu 8 ký tự.
3. Đăng nhập. Góc trên phải phải hiện tài khoản và trạng thái **Live**.

Tài khoản sbproxy tách biệt với tài khoản `root` của OpenWrt. Nếu quên mật
khẩu, SSH vào router và đặt lại:

```sh
sbproxy-webauth set admin
```

Nếu trang không hiện bản mới sau khi deploy, dùng `Ctrl+F5` hoặc xóa cache của
riêng trang. Phiên bản UI và agent trên thanh trên phải giống nhau.

## 6. Tạo SSID và thêm proxy

### 6.1 Tạo Wi-Fi

1. Chọn **Thêm WiFi** trong sidebar.
2. Nhập tên SSID, băng tần, `idx` và mật khẩu Wi-Fi.
3. `idx` phải duy nhất và không nên đổi sau khi đã sử dụng. Với mặc định,
   `idx 4` dùng subnet `192.168.14.0/24`, gateway `192.168.14.1`.
4. Chọn MAC/OUI, **Cách ly client** và **Chặn WebRTC** nếu cần.
5. Bấm **Lưu**.

Lúc này SSID mới chỉ nằm trong bản cấu hình trên trình duyệt, chưa được áp lên
router.

### 6.2 Thêm proxy theo batch

1. Trên hàng SSID vừa tạo, bấm **Pool**.
2. Chọn loại proxy `SOCKS5` hoặc `HTTP`.
3. Dán mỗi proxy trên một dòng. Web hỗ trợ:

```text
host:port:user:password
user:password@host:port
host:port
host,port,user,password
host;port;user;password
socks5://user:password@host:port
```

4. Bấm **Thêm vào pool**.
5. Chọn proxy và bấm **Test proxy**, hoặc dùng menu chuột phải để test các dòng
   đã chọn.

Pool chỉ hiện hai dòng đầu; bấm **Xem thêm** để mở toàn bộ. Proxy trùng được
loại bỏ để tránh tạo slot lặp.

### 6.3 Áp cấu hình

Bấm **Đẩy & Áp lên router**. Web chạy theo thứ tự:

1. Dry-run và kiểm tra cấu hình.
2. Ghi `config/wifi-socks.conf`.
3. Chạy `scripts/apply.sh` và tạo backup trước khi thay đổi.

Chờ kết quả thành công rồi kết nối thiết bị vào SSID mới.

## 7. Sử dụng hằng ngày

### Dashboard

- Xem số SSID, số BSSID theo radio và trạng thái health.
- **Pool**: xem, thêm, test hoặc xóa proxy của một SSID.
- **Chẩn đoán**: kiểm tra toàn bộ đường đi Wi-Fi → nftables → sing-box → proxy.
- **Sửa/nhân bản/xóa**: thay đổi cấu hình Wi-Fi; sau đó phải bấm **Đẩy & Áp**.

### Trang Thiết bị

Chọn **Thiết bị** trong sidebar. Chỉ vùng nội dung chính thay đổi; header và
sidebar vẫn giữ nguyên.

- Tìm theo MAC, IP, hostname hoặc SSID.
- Lọc theo SSID và trạng thái; sắp xếp bằng tiêu đề cột.
- Chọn một hoặc nhiều thiết bị bằng checkbox.
- **Ngắt** chỉ ngắt tạm; thiết bị có thể kết nối lại.
- **Cấm** lưu MAC vào blocklist và tồn tại qua lần apply/reboot.
- **Bỏ cấm** gỡ MAC khỏi blocklist.
- Chuột phải trên desktop hoặc nhấn giữ trên mobile để mở context menu.

Nếu mọi thiết bị được chọn thuộc cùng một SSID, menu có thêm **Thêm proxy &
phân phối**:

1. Dán danh sách proxy mới.
2. Proxy chưa có được nối vào pool của SSID; proxy trùng không bị thêm lại.
3. Chỉ các thiết bị đã chọn được chia đều trên tập proxy vừa dán.
4. Thiết bị khác trong SSID giữ nguyên proxy.

Nếu chọn lẫn thiết bị của nhiều SSID, tùy chọn này tự ẩn.

### Đường ra Internet

Mở **Đường ra** để xem default route, interface, DNS và độ trễ HTTP. Có thể:

- Chọn interface rồi **Đổi đường ra**.
- **Ghim** interface mong muốn.
- Chọn **Tự động** để chấp nhận default route hiện tại.

Không chọn bridge của SSID proxy làm uplink.

### Backup và rollback

- Web tự tạo backup trước Apply và các thao tác quan trọng.
- Mở **Backup / Rollback** để tạo backup, tải về máy hoặc khôi phục.
- Nên tải backup về máy trước khi nâng cấp firmware OpenWrt.

### Nhật ký debug

Mở **Nhật ký** để xem, copy hoặc tải gói debug dùng trên máy khác. Log được tách
theo ngày và tự xóa sau 7 ngày. File trên router:

```text
/etc/sbproxy/logs/YYYY-MM-DD.log
```

Gói debug tải từ web đã che token và mật khẩu proxy.

## 8. Cập nhật web/agent

Từ máy Windows đang giữ repo:

```powershell
git pull
.\pc\update.ps1 -RouterHost 192.168.8.1
ssh root@192.168.8.1 "cd /root/sbproxy && sh agent/install-agent.sh"
```

Lệnh này cập nhật code, CGI và giao diện nhưng không apply lại Wi-Fi. Cấu hình
SSID, pool, token, tài khoản, blocklist và lịch sử thiết bị được giữ nguyên.

Chỉ dùng `-Apply` khi bạn thực sự muốn chạy lại cấu hình Wi-Fi:

```powershell
.\pc\update.ps1 -RouterHost 192.168.8.1 -Apply
```

## 9. Kiểm tra và xử lý lỗi

### Kiểm tra nhanh trên router

```sh
cd /root/sbproxy
sh scripts/doctor.sh
/etc/init.d/sbproxy-healthd status
/etc/init.d/sbproxy-assignd status
logread -e sbproxy
```

Kiểm tra API mà không in token ra màn hình:

```sh
TOKEN="$(cat /etc/sbproxy/token)"
curl -s -H "Authorization: Bearer $TOKEN" \
  'http://127.0.0.1/cgi-bin/sbproxy?action=status' | jq .
unset TOKEN
```

### Lỗi thường gặp

| Hiện tượng | Cách xử lý |
|---|---|
| Không mở được `/sbproxy/` | Chạy lại `sh agent/install-agent.sh`, rồi `/etc/init.d/uhttpd restart`. |
| Web cứ Loading | `Ctrl+F5`; kiểm tra trạng thái **Live**; mở Nhật ký; chạy lệnh API ở trên. |
| UI và agent khác version | Chạy lại `install-agent.sh`, sau đó `Ctrl+F5`. |
| Test proxy fail | Kiểm tra host/port/user/pass, whitelist IP của nhà cung cấp và đường ra Internet. |
| Thiết bị có Wi-Fi nhưng không có mạng | Chạy Chẩn đoán trên SSID; kiểm tra health của slot proxy và default route. |
| Apply lỗi hoặc mất mạng | Cắm LAN dây, chạy `cd /root/sbproxy && sh scripts/rollback.sh`. |
| Quên mật khẩu web | Chạy `sbproxy-webauth set admin` qua SSH. |

## 10. Các file cần biết

| File/đường dẫn | Nội dung |
|---|---|
| `/root/sbproxy/config/wifi-socks.conf` | Danh sách SSID chính |
| `/root/sbproxy/config/proxy-pools.conf` | Pool proxy theo SSID |
| `/root/sbproxy/config/settings.sh` | Radio, subnet, port, giới hạn và chính sách |
| `/etc/sbproxy.assign` | Thiết bị được ghim vào slot proxy |
| `/etc/sbproxy.bans` | MAC bị cấm |
| `/etc/sbproxy/token` | Token API; không chia sẻ |
| `/etc/sbproxy/webauth` | Tài khoản web dạng hash |
| `/etc/sbproxy/logs/` | Log theo ngày, giữ 7 ngày |
| `/www/sbproxy/` | Web đã deploy |
| `/www/cgi-bin/sbproxy` | API CGI |

Tài liệu chuyên sâu: [Web console](web-console.md), [Kiểm thử](TESTING.md),
[Rollback](ROLLBACK.md), [Debug](DEBUGGING.md).
