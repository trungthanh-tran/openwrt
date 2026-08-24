# Hướng dẫn debug (PC và router)

**Ngôn ngữ:** Tiếng Việt | [English](DEBUGGING.en.md)

Tài liệu này dành cho người sửa code: dựng môi trường, khoanh vùng lỗi trên máy
phát triển và trên router thật, rồi báo lỗi kèm đúng thông tin cần thiết.

## 1. Môi trường phát triển

Máy Linux/WSL gần OpenWrt nhất. Cần `git`, POSIX `sh`, `jq`, `shellcheck`,
`make` và `hexdump` (thường thuộc gói `bsdextrautils`); test desktop cần
Python 3 kèm Tkinter. Không cần router: `uci`, `ubus` và `iw` đã được stub.

```sh
git clone <repo-url>
cd openwrt-multiwifi-socks5
sh tests/run-all.sh     # hoặc: make test
make check              # shellcheck + toàn bộ test, giống CI
```

Test Tk tự skip khi máy không có màn hình; các nhóm cần `jq` tự skip khi thiếu
`jq` — cài `jq` trước khi kết luận generator sing-box hoặc `clients.sh` sai.
GitHub CI chạy trên Ubuntu, GitLab CI chạy Alpine/BusyBox ash (gần shell router
nhất). Đừng lấy Git Bash trộn tiện ích Windows làm chuẩn: khác biệt
`sed`/`sort` và thiếu `hexdump` dễ tạo lỗi giả. Trên Windows nên chạy test shell
trong WSL; console desktop chạy riêng bằng `cd console\desktop; .\run.ps1`.

## 2. Bản đồ vùng code

| Vùng | File |
|---|---|
| Logic chính + generator sing-box/nftables | `scripts/lib.sh` |
| Áp cấu hình (có `DRYRUN=1`) | `scripts/apply.sh` |
| Liệt kê thiết bị (hostapd/ubus, `iw`, `/tmp/dhcp.leases`) | `scripts/clients.sh` |
| Báo cáo trạng thái chỉ đọc | `scripts/doctor.sh` |
| Gom bằng chứng chỉ đọc | `scripts/diagnose.sh` |
| API LAN | `agent/cgi/sbproxy`, `agent/sbproxy-healthd` |
| Console web (self-host tại `/www/sbproxy/index.html`) | `console/web/control-panel.html` |
| Console desktop native (Tkinter, không WebView) | `console/desktop/main.py` |
| Test | `tests/` — xem [TEST-MATRIX.md](TEST-MATRIX.md) |

Hai console dùng chung Agent API nhưng **không** dùng chung mã giao diện: sửa
một bên không tự động sửa bên kia.

## 3. Khoanh vùng lỗi

### Trên máy phát triển

1. Ghi lại `git rev-parse HEAD`, hệ điều hành, phiên bản `sh`, `jq`, Python và
   ShellCheck, cùng lệnh bị lỗi.
2. Chạy `sh tests/run-all.sh` để thấy assertion đầu tiên fail.
3. Chạy `make lint` (ShellCheck ở mức warning).
4. Nếu chỉ CI GitLab lỗi: tìm bashism hoặc khác biệt BusyBox ash. Shell router
   là POSIX/BusyBox — không dùng array hay `[[ ... ]]`.

### Trên router OpenWrt

Từ đúng checkout đang deploy, chạy theo thứ tự:

```sh
sh scripts/verify.sh
sh scripts/doctor.sh
sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1
```

`doctor.sh` trả non-zero nếu có `[FAIL]`; `[WARN]` không nhất thiết là hỏng.
`diagnose.sh` không restart dịch vụ và lấy board, Wi-Fi, sing-box, nftables,
policy route, log, socket và trạng thái fake-IP.

| Triệu chứng | Điểm kiểm tra đầu tiên |
|---|---|
| sing-box không chạy | Cần `>= 1.12`; chạy `sing-box check -c /etc/sing-box/config.json`, xem `logread -e sing-box` |
| Client ra mạng nhưng leak DNS | Chain `inet sbproxy prerouting` phải có TCP/UDP `dport 53`; config phải có `fakeip`; client `nslookup example.com` trả IP trong `198.18.0.0/15` |
| Không đi đúng SOCKS | Kiểm tra inbound/outbound `w<idx>`, rule TPROXY, `ip rule` mark `0x1` và route table 100 |
| Danh sách thiết bị rỗng | `ubus list` phải có `hostapd.*`; kiểm tra `iw dev <ifname> station dump` và `/tmp/dhcp.leases` |
| Kick lỗi | Cần instance `hostapd.*` và bản `wpad/hostapd` có ubus đầy đủ |
| Ban không giữ sau apply | Kiểm tra `/etc/sbproxy.bans` và việc `apply.sh` áp lại danh sách |
| Vendor MAC đổi ngoài ý muốn | Kiểm tra cột 11 `mac_oui` và UCI `wireless.w<idx>.macaddr`; MAC đã lưu chỉ được giữ khi còn khớp OUI |
| Console desktop báo lệch version | Xem *Tương thích version* trong [../console/desktop/README.vi.md](../console/desktop/README.vi.md) |

Sau khi sửa logic router: chạy lại test trên PC, rồi trên router chạy
`DRYRUN=1 sh scripts/apply.sh` → `sh scripts/apply.sh` → `sh scripts/verify.sh`
→ `sh scripts/doctor.sh`. `apply.sh` đổi trạng thái router nên phải có backup và
đường rollback. Các bài cần client thật nằm trong [TESTING.md](TESTING.md).

## 4. Báo lỗi cho người khác

**Không gửi** `config/wifi-socks.conf`, token, `/etc/sbproxy.bans`, file backup
hay mật khẩu SOCKS/Wi-Fi. Che IP public, hostname, SSID, MAC và credential bằng
placeholder trước khi chia sẻ output (`logs/console.log` và `logs/audit.log` của desktop đã tự che
token/mật khẩu).

Một báo lỗi đủ dùng gồm: commit đang chạy, môi trường máy dev, model router +
phiên bản OpenWrt/sing-box, mong đợi so với thực tế, lệnh tái hiện, assertion
đầu tiên fail (nếu có), các dòng WARN/FAIL của `doctor.sh`, đoạn liên quan trong
`diagnose.sh` và `git status --short`.

Đừng kết luận lỗi router chỉ từ unit test: TPROXY, hostapd ubus, giới hạn BSSID
và hành vi radio chỉ xác nhận được trên thiết bị thật.
