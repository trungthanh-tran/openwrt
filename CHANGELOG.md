# Changelog

Theo [Keep a Changelog](https://keepachangelog.com/) và [SemVer](https://semver.org/).
Ngày theo định dạng YYYY-MM-DD.

## [Unreleased]

## [0.4.0] - 2026-08-20

### Added
- **Versioning xuyên suốt**: agent trả `meta.version` trong `?action=status`;
  web console hiển thị `v<UI> · agent v<router>` và cảnh báo khi lệch version
  (test CI ép `UI_VERSION` khớp file `VERSION`).
- **Cập nhật agent qua giao diện**: endpoint `POST ?action=update[&force=1]`
  nhận package `.tar.gz`/`.zip`; `scripts/self-update.sh` chặn path traversal,
  chặn hạ version (trừ `--force`), backup `pre-update`, giữ nguyên
  `wifi-socks.conf` + `settings.sh`, deploy lại CGI/UI/healthd và reload dịch vụ.
- Nút **⬆ Cập nhật** + modal upload package trên web console (chọn file, force,
  log kết quả `from → to`).
- Tool đóng gói `pc/make-package.sh` / `pc/make-package.ps1` và target
  `make package` → `dist/sbproxy-update-<version>.tar.gz`.
- Giao diện web control panel hiện đại hóa: header kính mờ sticky, gradient,
  focus ring, animation modal/toast, segmented tabs, dark mode giữ nguyên.
- **Web console song ngữ Anh/Việt**: mặc định tiếng Anh, chọn ngôn ngữ ngay trên
  header, lưu vào localStorage và đổi trực tiếp không cần tải lại trang. Chuỗi
  tĩnh dịch qua `EN_TEXT`/`EN_ATTR`/`EN_HTML` (khối có thẻ inline được thay cả
  block), chuỗi động qua `pick(en, vi)`. Có test tự động chống bỏ sót bản dịch,
  key trùng và nhãn có tiền tố icon.
- Desktop hiển thị version: title bar + subtitle `v<APP_VERSION>`, dòng trạng
  thái thêm `agent v<x.y.z>` (đánh dấu `khác app` khi lệch); `APP_VERSION`
  được CI ép khớp file `VERSION`.
- **Desktop chạy trong môi trường tách biệt**: mọi file ghi ra nằm dưới một
  home riêng (`config/`, `logs/`, `cache/`, `runtime/`); thứ tự xác định là
  `SBPROXY_HOME` → thư mục `data/` cạnh file exe (portable) → mặc định theo
  user. Windows onefile giải nén Python runtime + dependency vào
  `%LOCALAPPDATA%\sbproxy-console-native\runtime` thay vì temp hệ thống
  (`--runtime-tmpdir`). Có `--where` để in đường dẫn và tự migrate
  `connection.json` của bản cũ.
- **Log debug**: `logs/console.log` xoay vòng 1 MB × 5 file, ghi mọi call agent
  (action/kích thước/thời gian/lỗi), tác vụ nền, log UI và exception không bắt
  được ở cả worker thread; token/mật khẩu được che trước khi ghi; nút
  **Thư mục log** trên header và cờ `--verbose`.
- Build desktop cho Linux/macOS: `console/desktop/build.sh` + `run.sh`
  (PyInstaller, cần `python3-tk`). Không có DPAPI thì token lưu
  `token_plain` trong `~/.config/sbproxy-console-native/connection.json`
  với `chmod 600` (thư mục `700`).

### Changed
- `pc/update.sh` / `pc/update.ps1` đóng gói thêm file `VERSION` lên router.
- Suite test: +22 assertion agent self-update, +14 assertion POSIX
  (manifest/versioning/self-update guard).

### Added — console native (gộp vào bản phát hành này)
- Console Windows **Tkinter native** gọi trực tiếp Agent API, không phụ thuộc
  HTML/WebView/WebView2; token được bảo vệ bằng Windows DPAPI.
- Pipeline thay đổi cấu hình trong app: dry-run candidate, loading theo bước,
  timeout hữu hạn, chỉ Apply khi kiểm tra đạt.
- Quản lý thiết bị nâng cao: lọc theo SSID/band/online/blocklist/RSSI/traffic/
  thời gian, sắp xếp, chọn nhiều, auto-refresh, chi tiết, copy và xuất CSV.
- Random BSSID/MAC theo provider OUI, block MAC thủ công và hiển thị cả thiết bị
  blocklist đang offline.
- Theo dõi Internet gateway: route/device/next-hop/source, đối chiếu `wwan`,
  trạng thái link, DNS và HTTP latency trực tiếp.
- Cảnh báo mặc định **Không** trước Apply, đổi SOCKS, random MAC, xóa SSID,
  kick/ban/unban và rollback.

### Changed
- Agent ưu tiên `Authorization: Bearer`; vẫn nhận `X-SB-Token` để tương thích.
- SOCKS outbound dùng TCP; nftables chặn UDP/443 để trình duyệt fallback từ
  QUIC/HTTP3 sang TCP/HTTPS qua SOCKS5.
- Các thao tác phụ thuộc item được chuyển khỏi toolbar vào khung chỉnh sửa của
  bảng Wi-Fi, thiết bị hoặc backup.

### Fixed
- Giới hạn rule `block-admin-wN` vào đúng gateway `192.168.(10+N).1`, tránh
  chặn nhầm toàn bộ HTTP/HTTPS đã đi qua TPROXY.
- Xóa sạch `macfilter`/`maclist` khi blocklist rỗng và giữ blocklist qua Apply.
- Bổ sung log DNS/fake-IP và trạng thái client online/offline để chẩn đoán.

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
