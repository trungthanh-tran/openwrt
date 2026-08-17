# sbproxy — Multi-WiFi → SOCKS5 trên OpenWrt (GL-MT6000)

Tạo nhiều WiFi (SSID), **mỗi WiFi định tuyến toàn bộ traffic qua một SOCKS5 riêng**, MAC ngẫu nhiên, cách ly client, chặn WebRTC — điều khiển bằng **một file config duy nhất** + vài script.

> Đi kèm bản plan tổng thể: [`../plan-mt6000-socks5-multi-wifi.md`](../plan-mt6000-socks5-multi-wifi.md)

## ⚠️ Trạng thái & cảnh báo
- **v0.2 — pre-production.** Hỗ trợ GL-MT6000 trên OpenWrt 24.10 (`opkg`) và 25.12 (`apk`); firmware GL.iNet OEM là experimental. **Phải kiểm thử trên router thật**, đặc biệt TPROXY, DNS và giới hạn BSSID.
- Hiện chỉ proxy **IPv4**; IPv6 bị tắt trên các SSID sbproxy để tránh đi thẳng. DNS per-SSID qua đúng SOCKS vẫn là hạng mục cần hoàn tất trước production.
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
  backup.sh / rollback.sh   # snapshot & khôi phục
  uninstall.sh              # gỡ mọi thứ project tạo
  lib.sh                    # helpers + generator sing-box/nftables
etc/init.d/sbproxy          # nạp nftables TPROXY + policy routing khi boot
ui/control-panel.html       # UI: soạn SSID→SOCKS, sinh config; + chế độ Live qua agent
agent/                      # KIẾN TRÚC B: CGI trên uhttpd + health-check latency realtime
  cgi/sbproxy               #   REST API gọi các script trên router
  sbproxy-healthd           #   daemon probe SOCKS, đo latency
  install-agent.sh          #   cài agent + self-host UI + tạo token
pc/                         # CHẠY TỪ MÁY QUẢN TRỊ (Windows/Linux): update, backup, restore qua SSH
  update.ps1 / update.sh    #   đẩy code lên router (giữ nguyên config đang dùng)
  backup.ps1 / backup.sh    #   backup router rồi kéo snapshot về máy
  restore.ps1 / restore.sh  #   đẩy snapshot lên router + rollback
docs/                       # GUIDE, INSTALL, ROLLBACK, TESTING, user-guide, admin-guide
```

## 2 chế độ dùng local
- **Offline (mặc định):** UI soạn `wifi-socks.conf` + preview sing-box/nft → bạn tự `apply.sh`. Chạy ở bất kỳ đâu.
- **Live LAN (agent kiến trúc B):** cài `agent/install-agent.sh`, mở UI từ `http://<router>/sbproxy/` → áp thẳng lên router, xem **latency SOCKS realtime**. Xem [agent/README.md](agent/README.md).

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

## Tài liệu
- **[docs/admin-guide.md](docs/admin-guide.md) — Hướng dẫn QUẢN TRỊ local theo bước: firmware → cấu hình → agent LAN → bảo mật. Bắt đầu ở đây.**
- **[docs/user-guide.md](docs/user-guide.md) — Hướng dẫn NGƯỜI DÙNG: vận hành console hằng ngày, không cần dòng lệnh.**
- Bản HTML đọc offline: [docs/admin-guide.html](docs/admin-guide.html) · [docs/user-guide.html](docs/user-guide.html)

> **Sửa tài liệu:** chỉ sửa file **`.md`** (nguồn duy nhất), rồi chạy `node tools/build-docs.js` để sinh lại `.html`. Đừng sửa tay file `.html` (sẽ bị ghi đè).
- [docs/GUIDE.md](docs/GUIDE.md) — Hướng dẫn toàn tập (một mạch): từ flash firmware → cấu hình → test → xử lý lỗi.
- [docs/INSTALL.md](docs/INSTALL.md) — cài chi tiết + giải thích từng bước
- [docs/TESTING.md](docs/TESTING.md) — cách test từng yêu cầu (IP đúng sock, DNS leak, WebRTC, isolation)
- [docs/ROLLBACK.md](docs/ROLLBACK.md) — khi lỗi thì khôi phục thế nào (nhiều mức)
