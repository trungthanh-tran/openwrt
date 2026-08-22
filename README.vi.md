# sbproxy — Multi-WiFi → SOCKS5 trên OpenWrt (GL-MT6000)

**Ngôn ngữ:** Tiếng Việt | [English](README.md)

Tạo nhiều WiFi (SSID), **mỗi WiFi định tuyến toàn bộ traffic qua một SOCKS5 riêng**, MAC ngẫu nhiên, cách ly client, chặn WebRTC — điều khiển bằng **một file config duy nhất** + vài script.

## ⚠️ Trạng thái & cảnh báo
- **0.4.x — pre-production** (version hiện tại nằm ở [VERSION](VERSION) và trên header console). Hỗ trợ GL-MT6000 trên OpenWrt 24.10 (`opkg`) và 25.12 (`apk`); firmware GL.iNet OEM là experimental. **Phải kiểm thử trên router thật**, đặc biệt TPROXY, DNS và giới hạn BSSID.
- Hiện chỉ proxy **IPv4**; IPv6 bị tắt trên các SSID sbproxy để tránh đi thẳng. DNS cổng 53 được hijack vào fake-IP và reverse-map hostname để SOCKS thực hiện remote resolve.
- Luôn có **backup tự động** trước mỗi thay đổi và **rollback 1 lệnh** — xem [docs/ROLLBACK.md](docs/ROLLBACK.md).
- Chỉ dùng cho mục đích hợp pháp; đảm bảo tuân thủ điều khoản của nhà cung cấp SOCKS.

## Cách hoạt động (tóm tắt)
```
WiFi Alpha ─(br-w1, 192.168.11.0/24)─┐
WiFi Bravo ─(br-w2, 192.168.12.0/24)─┤  nftables TPROXY theo iifname
WiFi ...   ─(br-wN, ...)─────────────┘        │  (mỗi WiFi -> 1 cổng)
                                              ▼
                                      sing-box (tproxy in -> socks out)
                                      in-w1 -> SOCKS A
                                      in-w2 -> SOCKS B
                                              │
                                              ▼  WAN
```
Mỗi WiFi = 1 bridge + subnet + DHCP + firewall zone riêng. nftables bắt traffic theo `iifname` đẩy vào cổng TPROXY tương ứng của sing-box; sing-box route sang đúng outbound SOCKS5.

## Cấu trúc
```
config/
  wifi-socks.conf.example   # bảng SSID→SOCKS (copy thành wifi-socks.conf rồi sửa)
  settings.sh               # tunables: radio↔băng tần, giới hạn BSSID, cổng, firewall
scripts/
  preflight.sh              # kiểm tra phần cứng/gói/iw list  (chỉ đọc)
  install-deps.sh           # apk/opkg install + cài init sbproxy
  apply.sh                  # backup + áp toàn bộ config (hỗ trợ DRYRUN=1)
  set-sock.sh               # đổi SOCKS không reload WiFi; phiên đang mở có thể gián đoạn
  gateway.sh                # kiểm tra default route/wwan, link, DNS và HTTP trực tiếp
  backup.sh / rollback.sh   # snapshot & khôi phục
  uninstall.sh              # gỡ mọi thứ project tạo
  lib.sh                    # helpers + generator sing-box/nftables
etc/init.d/sbproxy          # nạp nftables TPROXY + policy routing khi boot
console/                    # Hai frontend độc lập dùng chung Agent API
  web/control-panel.html    #   UI Web self-host trên router
  desktop/                  #   App Windows Tkinter native, không dùng HTML/WebView
    main.py / build.ps1 / build.sh  # code native + build 1 lệnh -> dist/sbproxy-console(.exe)
agent/                      # KIẾN TRÚC B: CGI trên uhttpd + health-check latency realtime
  cgi/sbproxy               #   REST API gọi các script trên router
  sbproxy-healthd           #   daemon probe SOCKS, đo latency
  install-agent.sh          #   cài agent + self-host UI + tạo token
pc/                         # CHẠY TỪ MÁY QUẢN TRỊ (Windows/Linux): update, backup, restore qua SSH
  update.ps1 / update.sh    #   đẩy code lên router (giữ nguyên config đang dùng)
  backup.ps1 / backup.sh    #   backup router rồi kéo snapshot về máy
  restore.ps1 / restore.sh  #   đẩy snapshot lên router + rollback
docs/                       # GUIDE, INSTALL, ROLLBACK, TESTING, user-guide, admin-guide
tests/                      # test chạy trên máy trạm, không cần router
  run-all.sh                #   chạy toàn bộ suite (make test)
Makefile · .editorconfig · .shellcheckrc · CI (.github, .gitlab-ci.yml)
```

## 2 chế độ dùng local
- **Offline (mặc định):** UI soạn `wifi-socks.conf` + preview sing-box/nft → bạn tự `apply.sh`. Chạy ở bất kỳ đâu.
- **Live LAN (agent kiến trúc B):** cài `agent/install-agent.sh`, mở UI → áp thẳng lên router, xem **latency SOCKS realtime**, quản lý thiết bị (kick/cấm). Xem [agent/README.md](agent/README.md).

### Console: bản Web và bản Desktop native
- **Bản Web** — mở từ `http://<router>/sbproxy/` (cài qua `install-agent.sh`), same-origin. Nếu mở qua **https** thì bị chặn mixed-content khi gọi router http.
- **Bản Desktop (.exe)** — ứng dụng Tkinter native gọi trực tiếp Agent API qua LAN, không dùng HTML/WebView/WebView2. App lưu token bằng Windows DPAPI, dry-run trước Apply, có cảnh báo tác vụ quan trọng và quản lý thiết bị nâng cao. Build 1 lệnh: Windows `cd console/desktop; .\build.ps1`, Linux/macOS `sh console/desktop/build.sh`.
- **Cài router vừa flash ngay trong bản Desktop** — chức năng **Cài đặt sau khi flash** chạy qua SSH: kiểm tra router đang có sẵn gì, đẩy mã nguồn và cấu hình, cài phụ thuộc và agent, chạy script khởi tạo rồi đọc token về và mở màn hình điều khiển; phần nào đã cài thì dùng lại và từng bước hiện ngay trên giao diện. File build đã nhúng sẵn gói router nên máy chạy không cần mã nguồn. Bản build tách theo nền tảng vì PyInstaller không cross-compile: Windows dùng `console/desktop/dist/sbproxy-console.exe` (build bằng `.\build.ps1`), Linux/macOS dùng `console/desktop/dist/sbproxy-console` (build bằng `sh console/desktop/build.sh`); mỗi file tự chứa đủ mọi thứ, chạy bằng `.\sbproxy-console.exe` hoặc `./sbproxy-console`. Chi tiết: [console/desktop/README.vi.md](console/desktop/README.vi.md).

## Quickstart
```sh
# 0. Copy repo lên router (vd /root/sbproxy), rồi:
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
vi config/wifi-socks.conf        # điền WiFi + SOCKS của bạn
vi config/settings.sh            # chỉnh RADIO_2G/RADIO_5G cho đúng
# bắt buộc đặt WIFI_COUNTRY (ví dụ VN) trong settings.sh

# 1. Kiểm tra môi trường (không đổi gì)
sh scripts/preflight.sh

# 2. Cài gói
sh scripts/install-deps.sh

# 3. XEM TRƯỚC (không thực thi)
DRYRUN=1 sh scripts/apply.sh | less

# 4. Áp thật (tự backup trước)
sh scripts/apply.sh

# 5. Kiểm thử  ->  docs/TESTING.md
# 6. Đổi SOCKS (không reload WiFi; phiên đang mở có thể gián đoạn):
sh scripts/set-sock.sh 2 5.6.7.8 1080 user pass

# Lỗi? Rollback:
sh scripts/rollback.sh
```

## Quản lý từ máy Windows/Linux (không cần SSH tay)
```powershell
# Windows (PowerShell) — cài 1 lần: copy pc\sbproxy-pc.conf.example pc\sbproxy-pc.conf rồi điền IP router
.\pc\update.ps1 -Apply     # đẩy code mới lên router + áp cấu hình (tự backup trước)
.\pc\backup.ps1            # backup router, kéo snapshot về pc\backups\
.\pc\restore.ps1           # khôi phục router từ snapshot mới nhất trên máy
```
Bản Linux/macOS tương đương: `sh pc/update.sh` / `pc/backup.sh` / `pc/restore.sh`. Chi tiết: [pc/README.md](pc/README.md).

## Phát triển
```sh
make test    # unit test (không cần router; phần cần jq tự skip)
make lint    # shellcheck
make check   # lint + test (giống CI)
```
CI (GitHub Actions + GitLab CI) chạy test + lint trên mỗi push. Quy ước & ràng buộc: [CONTRIBUTING.md](CONTRIBUTING.md) · lịch sử thay đổi: [CHANGELOG.md](CHANGELOG.md) · bảo mật: [SECURITY.md](SECURITY.md) · phiên bản: [VERSION](VERSION).

## Tài liệu
- **[docs/admin-guide.md](docs/admin-guide.md) — Hướng dẫn QUẢN TRỊ local theo bước: firmware → cấu hình → agent LAN → bảo mật. Bắt đầu ở đây.**
- **[docs/user-guide.md](docs/user-guide.md) — Hướng dẫn NGƯỜI DÙNG: vận hành console hằng ngày, không cần dòng lệnh.**

> **Sửa tài liệu:** sửa trực tiếp file **`.md`**. Dự án chỉ dùng Markdown, không sinh bản HTML.
- [docs/GUIDE.md](docs/GUIDE.md) — Hướng dẫn toàn tập (một mạch): từ flash firmware → cấu hình → test → xử lý lỗi.
- [docs/INSTALL.md](docs/INSTALL.md) — cài chi tiết + giải thích từng bước
- [docs/TESTING.md](docs/TESTING.md) — cách test từng yêu cầu (IP đúng sock, DNS leak, WebRTC, isolation)
- [docs/DEBUGGING.md](docs/DEBUGGING.md) — runbook bàn giao/debug 4 commit gần nhất trên máy khác (PC + router)
- [docs/ROLLBACK.md](docs/ROLLBACK.md) — khi lỗi thì khôi phục thế nào (nhiều mức)
- [console/desktop/README.vi.md](console/desktop/README.vi.md) — console desktop: cài router sau khi flash, chạy bằng file exe + gói `.tar.gz`
- [agent/README.md](agent/README.md) — agent LAN trên router (CGI + healthd)
- [pc/README.md](pc/README.md) — script quản trị từ máy tính qua SSH
- [docs/TEST-MATRIX.md](docs/TEST-MATRIX.md) — ma trận test tự động
