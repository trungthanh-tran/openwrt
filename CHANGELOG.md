# Changelog

Theo [Keep a Changelog](https://keepachangelog.com/) và [SemVer](https://semver.org/).
Ngày theo định dạng YYYY-MM-DD.

## [0.3.0] — 2026-08-19

### Added
- **DNS fake-IP**: hijack DNS cổng 53 của SSID proxy vào sing-box, trả fake-IP
  (`198.18.0.0/15`) và map ngược về hostname → outbound SOCKS nhận **hostname**
  (remote resolve), hết leak DNS qua dnsmasq. Giữ map qua restart bằng
  `experimental.cache_file`.
- **Giả MAC theo hãng**: cột thứ 11 `mac_oui` trong `wifi-socks.conf` + dropdown
  "Hãng WiFi" trong Console — 3 byte đầu MAC theo hãng phổ biến, 3 byte sau random.
- **Quản lý thiết bị**: liệt kê client theo SSID (MAC/IP/thời gian/in-out/sóng),
  **kick** (deauth) và **cấm/bỏ cấm** MAC (`scripts/clients.sh`,
  `scripts/{kick,ban,unban}.sh`, endpoint agent `clients|kick|ban|unban`).
- **Console tách 2 bản**: `console/web/` (router-hosted) và `console/desktop/`
  (đóng gói .exe Windows qua WebView2, không vướng mixed-content).
- **`scripts/doctor.sh`**: báo cáo trạng thái tổng thể (chỉ đọc).
- **Hạ tầng dự án**: `tests/run.sh` (unit test POSIX sh), CI (GitHub Actions +
  GitLab CI), `Makefile`, `.editorconfig`, `.shellcheckrc`, `VERSION`, và bộ
  tài liệu meta (CHANGELOG/CONTRIBUTING/SECURITY/LICENSE).

### Changed
- Config sing-box chuyển sang **cú pháp hiện đại (1.12+)**, tương thích
  **sing-box 1.13** (rule-action `sniff`/`hijack-dns`, DNS server kiểu mới).
- Chặn query HTTPS/SVCB (type 65/64) và bỏ `inet6_range` để trình duyệt không
  né fake-IP hay treo IPv6 giả trên mạng IPv4-only.
- Tổ chức lại thư mục: gộp UI web + desktop vào `console/`.

### Security
- Bans MAC lưu bền ở `/etc/sbproxy.bans` và được `apply.sh` áp lại sau mỗi lần
  chạy nên không mất khi cấu hình lại.

## [0.2.0] — pre-production baseline

### Added
- Đa WiFi → mỗi SSID một SOCKS5 riêng qua nftables TPROXY + sing-box.
- MAC random `02:`, cách ly client, chặn WebRTC theo cổng STUN/TURN.
- Agent LAN (uhttpd CGI) + health daemon đo latency; Console web.
- Bộ script `pc/` quản trị router từ máy Windows/Linux qua SSH.
- Backup tự động trước mỗi thay đổi + rollback một lệnh.

[0.3.0]: #030--2026-08-19
[0.2.0]: #020--pre-production-baseline
