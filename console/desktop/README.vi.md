# sbproxy Console Native

**Ngôn ngữ:** Tiếng Việt | [English](README.md)

Ứng dụng desktop Tkinter chạy độc lập, gọi thẳng Agent API trên router. Ứng
dụng **không dùng HTML, WebView hay WebView2** — console web tại
`console/web/control-panel.html` là ứng dụng riêng dùng chung API. Windows là
nền tảng chính; cùng mã nguồn build được cho Linux và macOS.

Hai việc console web không làm được: cài router vừa flash qua SSH (**Cài đặt
sau khi flash**) và chạy chỉ với một file thực thi, máy không cần Python cũng
không cần mã nguồn.

## Chức năng

**Cấu hình**

- Quản lý danh sách Wi-Fi/SSID và SOCKS5, lưu cấu hình rồi apply.
- Thêm/xoá SSID; mỗi lần Apply đều dry-run cấu hình tạm trước khi ghi, và Agent
  dry-run lần cuối trước khi router đổi trạng thái.
- Đổi SOCKS5 của một SSID mà không cần sửa toàn bộ.
- Nhấp chuột phải lên một dòng SSID để sửa, đổi SOCKS, random MAC hoặc xoá.
  **Random MAC** hỏi tiếp hãng router/OUI (TP-Link, Netgear, ASUS, Xiaomi,
  Huawei, …); hãng và BSSID mới được lưu lại.

**Thiết bị**

- Xem client và kick, cấm, bỏ cấm; thiết bị trong blocklist dù offline vẫn hiện
  để có thể bỏ cấm.
- Lọc theo SSID, IP/tên/MAC, band, online/offline, quyền truy cập, RSSI, lưu
  lượng và thời gian kết nối. Bấm tiêu đề cột bất kỳ trong bảng Wi-Fi hoặc
  Thiết bị để sắp xếp; bấm lại để đảo chiều.
- Dashboard số liệu, auto-refresh 5–60 giây, xem chi tiết, chọn nhiều thiết bị,
  copy IP/MAC và xuất CSV UTF-8.

**Vận hành**

- Khung Internet Gateway: route thực tế, `wwan`/device, next-hop, IP nguồn,
  link, DNS và HTTP latency; cảnh báo khi đường ra không qua `wwan`.
- Xem backup, rollback, chạy health check và đọc log thao tác.
- Cài hoặc sửa router qua SSH ngay trong app — xem
  [Cài đặt sau khi flash](#cài-đặt-sau-khi-flash).

**Giao diện và an toàn**

- Đổi trực tiếp giữa English/Tiếng Việt và Dark/Light; lựa chọn được lưu (mặc
  định English + Dark).
- Tab bo góc kiểu Chrome: tab đang mở liền màu với vùng nội dung, tab chưa chọn
  và trạng thái hover phân biệt rõ trong cả hai theme.
- Màn hình loading theo bước với timeout hữu hạn: dry-run 60 giây, lưu/backup
  45 giây, apply 120 giây.
- Tác vụ quan trọng nêu rõ ảnh hưởng và mặc định chọn **Không**.
- Khung chỉnh sửa cố định chỉ giữ Sửa và Xoá; các thao tác còn lại nằm trong
  menu chuột phải của dòng, toolbar chỉ chứa thao tác toàn cục.
- URL router và token được bảo vệ bằng Windows DPAPI cho đúng tài khoản hiện
  tại (Linux/macOS dùng `chmod 600`).

## Cài đặt sau khi flash

Router mới, làm từ đầu tới cuối? Theo
[hướng dẫn 4 bước](../../docs/QUICKSTART.md); phần này giải thích wizard làm gì.

Router vừa flash lại chưa có mã nguồn sbproxy, chưa có agent và chưa có token.
Khi chưa lưu token, console **tự mở form cài đặt** lúc khởi động, nên ngay lần
chạy đầu đã có sẵn ô nhập IP router, tài khoản SSH, port và mật khẩu — không
phải đi tìm nút. Đóng form cũng không sao: **Cài đặt sau khi flash…** mở lại
đúng cửa sổ đó, trên thanh vàng hoặc ở hàng kết nối (nút này luôn có). Từ đó
console chạy toàn bộ quy trình qua SSH và tick từng bước ngay trên giao diện:

1. Kiểm tra kết nối SSH (và báo bản OpenWrt đang chạy).
2. Kiểm tra router đang có sẵn gì: mã nguồn, `wifi-socks.conf`, sing-box, agent
   CGI, token và sing-box có chạy không.
3. Đẩy mã nguồn vào `/root/sbproxy`.
4. Cài gói phụ thuộc (`scripts/install-deps.sh`).
5. Đẩy `config/wifi-socks.conf` — và `config/settings.sh` nếu có chọn.
6. Chạy `scripts/preflight.sh` và `DRYRUN=1 scripts/apply.sh`.
7. Chạy `scripts/apply.sh` khởi tạo (tuỳ chọn bằng checkbox).
8. Cài hoặc cập nhật agent (`agent/install-agent.sh`).
9. Đọc `/etc/sbproxy/token` và lưu như token nhập tay.
10. Gọi `?action=status` để chắc chắn agent trả lời.

**Cái gì đang chạy tốt thì không làm lại.** Bước 2 quyết định phần còn lại: đã
có phụ thuộc thì không cài lại, đã có cấu hình thì giữ nguyên, agent còn tốt kèm
token thì không cài đè — token vẫn được đọc để mở thẳng màn hình điều khiển.
Muốn làm lại thì tick **Ghi đè cấu hình đã có trên router** hoặc **Cài lại agent
dù đã có**.

Chuỗi dừng ngay ở bước lỗi đầu tiên kèm đúng thông báo lỗi của router; sửa xong
chạy lại được vì mọi bước đã qua đều idempotent. Khi bước cuối đạt, cửa sổ cài
đặt đóng lại và màn hình điều khiển mở ra với token mới.

**Xác thực** dùng OpenSSH của máy: SSH key, key đã nạp sẵn trong agent, hoặc
mật khẩu router. Mật khẩu đi tới `ssh` qua askpass helper — không nằm trên dòng
lệnh — và không bao giờ ghi vào `connection.json`. Địa chỉ router, user, port và
các đường dẫn được nhớ cho lần chạy sau.

**Kiểm tra trước khi cài.** Có token sẵn thì app kết nối ngay khi mở và vào
thẳng màn hình điều khiển. Chưa có token thì app mở form cài đặt, đồng thời kiểm
tra ngầm địa chỉ router đã lưu và ghi kết quả lên thanh vàng: agent tốt, agent chạy nhưng sai token, router
sống nhưng chưa có agent, hoặc không liên lạc được. Nút **Kiểm tra tình trạng**
làm lại việc đó khi bấm và kèm bảng hiện trạng SSH ở bước 2. Cả hai đều **chỉ
đọc**, nên chỉ chạy cài đặt khi thật sự cần.

## Tương thích version

Console, gói router nó mang theo và agent trên router là **cùng một version**.
Mỗi lần kết nối, console đọc `meta.version` từ `?action=status` rồi xử lý theo
chênh lệch:

| Tình huống | Console làm gì |
|---|---|
| Cùng version | Kết nối bình thường. |
| Chưa có agent | Thanh vàng mời chạy **Cài đặt sau khi flash…** để cài. |
| Agent cũ hơn console | Hỏi có nâng cấp không; chọn **Có** thì console đẩy gói của chính nó lên `?action=update`. `scripts/self-update.sh` backup `pre-update`, **giữ nguyên `wifi-socks.conf` và `settings.sh`**, deploy lại CGI/UI/healthd và không đụng vào Wi-Fi. Từ chối thì thanh vàng giữ nút **Nâng cấp agent**. |
| Agent mới hơn console | Không cho điều khiển: báo lỗi yêu cầu dùng bản console mới hơn và khoá mọi thao tác thay đổi (Apply, đổi SOCKS, random MAC, xoá SSID, kick/cấm/bỏ cấm, backup, rollback). Xem và kiểm tra trạng thái vẫn được. |

**Cài đặt sau khi flash** áp dụng đúng luật đó qua SSH: đọc `VERSION` trên
router trước khi ghi bất cứ thứ gì và từ chối đẩy gói cũ hơn lên router mới hơn;
cài lại agent mỗi khi CGI, health daemon hoặc UI đã deploy khác với code vừa đẩy
— chỉ đổi số version thì CGI cũ vẫn chạy; và bước cuối báo lỗi nếu agent vẫn
trả về version khác với gói vừa cài.

## Chạy tại hiện trường: file exe + gói `sbproxy-update-*.tar.gz`

Cùng một quy trình nhưng có **hai bản chạy** — chọn đúng bản cho máy mang theo.
**PyInstaller không cross-compile: file `.exe` của Windows không chạy trên Linux
và ngược lại**, nên phải build (hoặc lấy) đúng bản của nền tảng đó.

| | Windows | Linux / macOS |
|---|---|---|
| File mang theo | `sbproxy-console.exe` | `sbproxy-console` (binary ELF/Mach-O) |
| Build bằng | `.\build.ps1` | `sh build.sh` |
| Chạy | `.\sbproxy-console.exe` | `./sbproxy-console` (lần đầu `chmod +x`) |
| Lưu token | DPAPI theo tài khoản Windows | `chmod 600` trong thư mục home của app |
| Thư mục home | `%LOCALAPPDATA%\sbproxy-console-native` | `~/.local/share/sbproxy-console-native` |
| Yêu cầu thêm | — | máy build phải có Tk (`python3-tk`) |

Cả hai bản đều nhúng sẵn gói router đúng version của chính nó, nên **chỉ một file
là cài được router**. Chỉ cần thêm gói `sbproxy-update-<version>.tar.gz` khi muốn
cài version khác gói nhúng; tạo từ mã nguồn bằng `make package`,
`sh pc/make-package.sh` hoặc `.\pc\make-package.ps1` (file ra ở `dist/`).

Máy nào cũng cần: OpenSSH client (`ssh` và `scp`) trong `PATH` và một đường LAN
có dây tới router. Không cần Python, không cần mã nguồn, cũng **không cần `tar`**:
gói nhúng được đẩy nguyên trạng và router tự giải nén. Chỉ khi payload là thư mục
mã nguồn (phải đóng gói trước) thì máy mới cần `tar`.

### 1. Kiểm tra file chạy và gói nó mang theo

Không có file gói nào phải giữ kèm: file thực thi đã chứa sẵn
`sbproxy-update-<version>.tar.gz` và bung ra cạnh runtime của nó khi chạy.
`--where` in ra đúng bản gói sẽ được đẩy lên router, nên dòng `payload=` vừa là
bằng chứng gói có sẵn, vừa cho biết sẽ cài version nào.

Windows (PowerShell):

```powershell
ssh -V                           # OpenSSH client phải có trong PATH
.\sbproxy-console.exe --where    # home/config/logs/runtime + payload=…-<version>.tar.gz
```

Linux/macOS (shell):

```sh
ssh -V                           # OpenSSH client phải có trong PATH
chmod +x ./sbproxy-console       # chỉ cần lần đầu
./sbproxy-console --where        # home/config/logs/runtime + payload=…-<version>.tar.gz
```

Nếu chạy từ mã nguồn thay vì bản build, `payload=` trỏ vào thư mục repo và app
tự đóng gói khi cài — đó là trường hợp duy nhất máy cần `tar`.

**Chỉ khi mang thêm một gói rời** (để cài version khác gói nhúng) mới có file để
kiểm tra:

```powershell
tar -tzf .\sbproxy-update-0.5.0.tar.gz | Select-Object -First 10   # gói chứa gì
tar -xzOf .\sbproxy-update-0.5.0.tar.gz VERSION                    # gói là version nào
```

```sh
tar -tzf ./sbproxy-update-0.5.0.tar.gz | head
tar -xzOf ./sbproxy-update-0.5.0.tar.gz VERSION
```

### 2. Kiểm tra router trước khi đụng vào

Mở app rồi đọc thanh vàng, hoặc bấm **Kiểm tra tình trạng** — cả hai đều chỉ đọc
như mô tả ở trên. Nếu cần chạy trong script: `--probe` trả 0 khi token đã lưu
vẫn dùng được.

### 3. Cài đặt hoặc sửa router

Bấm **Cài đặt sau khi flash…** rồi điền:

| Trường | Điền gì |
|---|---|
| Router (IP) | `192.168.8.1` với firmware GL.iNet, `192.168.1.1` với OpenWrt vanilla/recovery |
| Tài khoản / Port SSH | `root`, `22` |
| Mật khẩu SSH / SSH key | mật khẩu router, hoặc chọn SSH key (dùng key thì bỏ trống mật khẩu) |
| Thư mục trên router | `/root/sbproxy` trừ khi bản cài nằm chỗ khác |
| Mã nguồn hoặc gói `.tar.gz` | để nguyên nếu dùng gói nhúng; bấm `…` chọn `sbproxy-update-<version>.tar.gz` nếu muốn cài gói đó |
| `wifi-socks.conf` | file cấu hình cần đẩy; để trống nếu giữ cấu hình sẵn có trên router |
| Ghi đè / Cài lại | chỉ tick khi thực sự muốn thay cấu hình hoặc agent đang chạy |

Bấm **Bắt đầu cài đặt** và theo dõi checklist: bước nào router đã có sẵn sẽ hiện
*Bỏ qua*, gặp lỗi thì dừng ngay kèm thông báo của router, chạy hết thì app lưu
token và mở màn hình điều khiển.

Muốn cài gói khác về sau: mở lại wizard chọn `.tar.gz` mới, hoặc trỏ sẵn cho app
trước khi mở:

```powershell
$env:SBPROXY_PAYLOAD = "D:\packages\sbproxy-update-0.5.0.tar.gz"
.\sbproxy-console.exe
```

```sh
SBPROXY_PAYLOAD=/srv/packages/sbproxy-update-0.5.0.tar.gz ./sbproxy-console
```

Khi router đã chạy agent thì các lần cập nhật sau không cần SSH nữa: upload đúng
file `.tar.gz` đó trong dialog **Cập nhật** của console web
(`scripts/self-update.sh` giữ nguyên `wifi-socks.conf` + `settings.sh` và chặn hạ
version).

## Dòng lệnh và biến môi trường

| Cờ / biến | Tác dụng |
|---|---|
| `--where` | In đường dẫn home, config, logs, runtime và gói payload đang dùng |
| `--probe` | Trả 0 nếu token đã lưu vẫn gọi được agent, ngược lại trả 1 |
| `--where` … `payload=` | Gói mà console này sẽ cài lên router |
| `--provision` | Lưu `SBPROXY_BASE`/`SBPROXY_TOKEN` rồi thoát (0 nếu thành công, 2 nếu thiếu token) |
| `--verbose` | Ghi log mức DEBUG cho lần chạy này |
| `SBPROXY_HOME` | Chỉ định thư mục home riêng của app |
| `SBPROXY_PAYLOAD` | Gói router hoặc thư mục mã nguồn mà **Cài đặt sau khi flash** sẽ đẩy |
| `SBPROXY_BASE`, `SBPROXY_TOKEN` | Giá trị kết nối cho `--provision` |

Nạp sẵn kết nối mà không ghi token dạng rõ:

```powershell
$env:SBPROXY_BASE = "http://192.168.8.1"
$env:SBPROXY_TOKEN = "<token>"
.\dist\sbproxy-console.exe --provision
.\dist\sbproxy-console.exe --probe
```

```sh
SBPROXY_BASE=http://192.168.8.1 SBPROXY_TOKEN=<token> ./dist/sbproxy-console --provision
./dist/sbproxy-console --probe
```

Agent dùng `Authorization: Bearer <token>` vì uhttpd có thể loại bỏ header CGI
tuỳ biến. Chỉ dùng Agent trong LAN/VLAN quản trị; không mở ra WAN.

## Build

Yêu cầu Python 3.9+ có Tkinter. PyInstaller không cross-compile — build trên
đúng nền tảng đích.

```powershell
cd console\desktop
.\build.ps1
# -> dist\sbproxy-console.exe
```

```sh
cd console/desktop
sh build.sh
# -> dist/sbproxy-console        (Debian/Ubuntu: cài sudo apt install python3-tk trước)
```

Cả hai script nhúng gói router (`sbproxy-update-<version>.tar.gz`, đúng danh
sách file như `pc/make-package.sh`) để **Cài đặt sau khi flash** dùng được ngay
trên máy không có mã nguồn. Gói được tạo ở thư mục tạm ngoài repo và bung ra
cùng bundle khi chạy; `SBPROXY_PAYLOAD` và file chọn trong wizard vẫn được ưu
tiên hơn. Máy chạy file build ra không cần Python hay WebView2.

Trên Linux, bootloader POSIX không expand `~` hay `$HOME`, nên runtime giải nén
vào thư mục temp mặc định trừ khi chỉ định đường dẫn tuyệt đối:

```sh
SBPROXY_RUNTIME_TMPDIR=/opt/sbproxy/runtime sh build.sh
```

## Môi trường tách biệt

Mọi thứ app ghi ra đều nằm trong **một thư mục home riêng**, không lẫn với môi
trường Python bên ngoài hay với bản cài khác:

```
<home>/config/connection.json   URL router + token (DPAPI trên Windows, chmod 600 nơi khác)
<home>/logs/console.log         log debug xoay vòng (1 MB × 5 file)
<home>/cache/                   dữ liệu tạm
<home>/runtime/                 Python runtime + dependency đóng gói (Windows onefile)
```

Thứ tự xác định `<home>`:

1. Biến `SBPROXY_HOME` (tuỳ ý chỉ định).
2. Thư mục `data/` nằm cạnh file thực thi — **chế độ portable**, hợp với USB
   hoặc bản copy-anywhere; cứ tạo thư mục là app tự dùng.
3. Mặc định theo người dùng: `%LOCALAPPDATA%\sbproxy-console-native` (Windows),
   `~/.local/share/sbproxy-console-native` (Linux/macOS).

`--where` in ra đường dẫn thực tế. File `connection.json` của bản cũ được tự
động migrate vào `config/` ở lần chạy đầu.

## Log để debug

Mọi lệnh gọi agent (action, dung lượng, thời gian, lỗi HTTP/kết nối), tác vụ
nền, dòng log trên UI và exception không bắt được — cả main thread lẫn worker —
đều ghi vào `<home>/logs/console.log`, xoay vòng ở 1 MB và giữ 5 file. Token,
header Bearer, mật khẩu Wi-Fi/SOCKS được che (`***`) trước khi ghi nên file an
toàn để gửi kèm báo lỗi. Nút **Thư mục log** trên header mở thư mục này; cờ
`--verbose` ghi thêm mức DEBUG.

## Chạy khi phát triển và test

```powershell
cd console\desktop
.\run.ps1          # Linux/macOS dùng sh run.sh
```

Từ thư mục gốc repo, `sh tests/run-all.sh` (hoặc `make test`) chạy mọi suite an
toàn trên máy trạm: parse/lọc/API lõi, workflow giao diện, chuỗi cài đặt sau khi
flash (chạy với fake, không đụng router thật), và test Tk hai ngôn ngữ × hai
theme khi máy có màn hình. Xem [ma trận test đầy đủ](../../docs/TEST-MATRIX.md).
