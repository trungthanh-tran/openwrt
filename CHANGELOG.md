# Changelog

Theo [Keep a Changelog](https://keepachangelog.com/) và [SemVer](https://semver.org/).
Ngày theo định dạng YYYY-MM-DD.

## [Unreleased]

### Added
- **Preflight tự dò radio của board** thay vì giả định `radio0`/`radio1`: đọc
  danh sách `wifi-device` từ UCI (bao nhiêu radio, tên gì cũng được), suy ra
  băng tần từ `band` hoặc `hwmode`, rồi **đối chiếu `RADIO_2G`/`RADIO_5G` trong
  `config/settings.sh` với phần cứng thật**. Sai thì báo đúng tên radio nên
  dùng (`RADIO_2G=radio0 is a 5g radio, not 2g - use radio1`), thiếu thì báo
  thiếu. Các hàm `list_radios`, `radio_band`, `radio_for_band`,
  `check_radio_mapping` nằm trong `scripts/lib.sh` và có test riêng.

### Fixed
- **Bản .exe không còn nháy cửa sổ console ở mỗi bước cài đặt.** `ssh`/`tar` là
  chương trình console; chạy từ bản build `--windowed` (không có console sẵn)
  thì Windows cấp cho mỗi lần gọi một cửa sổ mới. Mọi tiến trình con giờ chạy
  với `CREATE_NO_WINDOW` + `STARTF_USESHOWWINDOW`/`SW_HIDE`.

## [0.4.5] - 2026-08-25

### Fixed
- **Bước “Đẩy mã nguồn lên router” lỗi với một dòng usage của `scp`** (đoạn
  `[-S program] source ... target`). Việc đẩy file giờ đi qua chính `ssh`
  (`cat > <file>`) thay vì `scp`: `scp` chế độ SFTP cần sftp-server mà ảnh
  OpenWrt/dropbear thường không có, chế độ legacy cần binary `scp` trên router
  cũng không có, còn cờ `-O` để chọn chế độ legacy thì OpenSSH cũ hơn 8.6
  không hiểu nên in usage. `cat` thì ảnh nào cũng có. Sau khi đẩy, console đối
  chiếu `wc -c` trên router với kích thước file gốc nên truyền thiếu là báo lỗi
  ngay, không âm thầm đi tiếp.
- **`scripts/preflight.sh` chết giữa chừng ở mục 2 trên router hai radio.**
  `uci -q get wireless.radio2.band` trả mã lỗi cho radio không tồn tại, mà
  script chạy `set -e` nên phép gán không được bảo vệ làm dừng luôn preflight —
  console báo lỗi bằng đúng dòng tiêu đề `==== 2. Radio-to-band mapping ====`.
  Đã bảo vệ phép gán (và cả phần liệt kê gói của apk/opkg).
- **Lỗi của một bước không còn hiện ra dưới dạng dòng vô nghĩa.** Console bỏ
  qua dòng trang trí/tiêu đề mục, ưu tiên dòng `usage:` hoặc dòng có
  `[sbproxy][ERR]`, và **in toàn bộ output của lệnh hỏng vào khung nhật ký**
  cũng như `console.log` (đã che thông tin nhạy cảm).

## [0.4.4] - 2026-08-24

### Fixed
- **Bấm “Bắt đầu cài đặt” trên bản .exe báo `Security validation failure: parent
  process has different executable!` và dừng ngay.** `ssh` mới là tiến trình gọi
  helper askpass, nên app chạy với cha là `ssh.exe`; bootloader onefile của
  PyInstaller thấy biến môi trường của chính nó được kế thừa, đối chiếu tiến
  trình cha với file thực thi của mình rồi huỷ. Môi trường đưa cho `ssh` giờ
  được gỡ sạch `_PYI_*` / `_MEIPASS2` và đặt `PYINSTALLER_RESET_ENVIRONMENT=1`,
  nên lần gọi askpass khởi động như một tiến trình bình thường. Bản chạy từ mã
  nguồn không dính lỗi này.

## [0.4.3] - 2026-08-24

### Added
- Kết nối SSH thành công mà router **chưa có agent** thì app hỏi ngay *“Cài ngay
  bây giờ?”*. Chọn cài là chạy luôn chuỗi cài đặt rồi lấy token và kiểm tra
  agent; chọn không thì console báo **KHÔNG CẤU HÌNH ĐƯỢC ROUTER**, làm mờ hàng
  kết nối / khung cổng ra / toàn bộ tab và chỉ còn một nút **Cài agent ngay**.
  Nút đó dùng lại thông tin SSH vừa nhập (chỉ giữ trong bộ nhớ, không ghi ra
  đĩa) nên bấm là cài ngay; cài xong console tự mở khoá. Router đã có sẵn agent
  và token thì không bị hỏi lại.
- **Hướng dẫn người dùng cho console desktop** (`docs/desktop-user-guide.md` +
  bản EN): mở app lần đầu, kết nối hằng ngày, tab Wi-Fi/SOCKS5, tab thiết bị,
  tab backup, log và xử lý sự cố — viết cho người dùng, không cần dòng lệnh.
  `user-guide.md` giữ nguyên vai trò hướng dẫn bản console web.

### Fixed
- Lần đầu mở app khi **chưa có token**, form nhập IP router / tài khoản SSH /
  port / mật khẩu **tự mở** thay vì chỉ hiện thanh vàng — trước đây phải tự tìm
  nút **Cài đặt sau khi flash…** mới thấy form.
- Nút **Cài đặt sau khi flash…** không còn chết thầm lặng: lỗi lúc dựng cửa sổ
  được ghi log và báo bằng hộp thoại. Mở nhiều lần chỉ dùng lại đúng một cửa sổ
  thay vì chồng nhiều wizard lên nhau.

## [0.4.2] - 2026-08-24

### Added
- **Hướng dẫn cài nhanh bằng file exe** (`docs/QUICKSTART.md` + bản EN): 4 bước
  backup → flash → đặt mật khẩu root → chạy app, kèm phần chuẩn bị, kiểm tra sau
  khi cài và bảng xử lý sự cố. README gốc và các guide gom mục lục theo nhóm
  Cài đặt / Vận hành / Thành phần và trỏ thẳng vào hướng dẫn này.
- **Cài đặt sau khi flash ngay trong console desktop**: nút **Cài đặt sau khi
  flash…** chạy toàn bộ chuỗi qua SSH — kiểm tra SSH, đẩy mã nguồn vào
  `/root/sbproxy`, `install-deps.sh`, đẩy `wifi-socks.conf` (và `settings.sh`
  nếu chọn), `preflight.sh` + dry-run, `apply.sh`, `agent/install-agent.sh`,
  đọc `/etc/sbproxy/token` rồi kiểm tra `?action=status`. Từng bước hiển thị
  trạng thái/chi tiết trực tiếp trên UI và dừng ngay ở bước lỗi đầu tiên.
- Lấy token xong app lưu như token nhập tay và mở thẳng màn hình điều khiển.
- Khi chưa có token, cửa sổ chính hiện thanh **CHƯA CẤU HÌNH ROUTER** với nút
  **Cài đặt sau khi flash…** và **Kiểm tra tình trạng** (agent OK / sai token /
  chưa cài agent / không liên lạc được); có token sẵn thì app kết nối luôn.
- Mật khẩu SSH đi qua askpass helper (không nằm trên dòng lệnh, không ghi vào
  `connection.json`); host/user/port/đường dẫn được nhớ cho lần chạy sau.
- **Bản build .exe/.bin nhúng sẵn gói router**: `build.ps1` và `build.sh` đóng
  gói `sbproxy-update-<version>.tar.gz` (cùng danh sách file với
  `pc/make-package.sh`) vào file thực thi, nên chỉ cần file build là cài được
  router mới flash — không cần mã nguồn trên máy. Gói tạo ở thư mục tạm ngoài
  repo; `SBPROXY_PAYLOAD` hoặc file chọn tay vẫn được ưu tiên, và đường dẫn
  trong bundle không bị lưu lại vì mỗi lần chạy bung ra chỗ khác.
- **Kiểm tra trước khi cài**: thêm bước *Kiểm tra hiện trạng router* (chỉ đọc)
  báo router đã có mã nguồn / `wifi-socks.conf` / sing-box / agent / token và
  sing-box có chạy không. Cái gì đã có thì dùng lại — không cài lại phụ thuộc,
  giữ cấu hình đang chạy, không cài đè agent còn tốt (vẫn đọc token) — trừ khi
  tick **Ghi đè cấu hình đã có trên router** hoặc **Cài lại agent dù đã có**.
- Lần mở app sau: nếu đã biết địa chỉ router mà chưa có token, app kiểm tra ngầm
  và ghi tình trạng lên thanh vàng thay vì để người dùng cài lại từ đầu; nút
  **Kiểm tra tình trạng** kèm luôn bảng hiện trạng qua SSH.
- **Refine toàn bộ tài liệu**: `console/desktop/README.*` viết lại theo mạch
  chức năng → cài router → dòng lệnh/biến môi trường → build → môi trường/log →
  dev & test (bỏ phần trùng lặp); README gốc, `docs/GUIDE.*`, `docs/INSTALL.*`,
  `docs/admin-guide.*`, `docs/user-guide.*`, `agent/README.*` và `pc/README.*`
  bổ sung đường dẫn cài bằng console desktop và liên kết chéo; bỏ các mốc
  version cũ (v0.1/v0.2/v0.3) trong phần trạng thái và hạn chế; bản EN rút gọn
  ghi rõ bản VI là tài liệu hiện trường đầy đủ hơn.
- Tài liệu chạy tại hiện trường (`console/desktop/README.md` + `README.vi.md`):
  mang gì theo, kiểm tra `ssh`/`tar`/gói bằng `--where` và `tar -tzf`/`-xzOf`,
  kiểm tra router trước khi đụng vào, bảng điền từng trường trong wizard, cách
  cài bằng gói `.tar.gz` khác (`SBPROXY_PAYLOAD` hoặc chọn file).
- **Ràng buộc version console ↔ agent**: mỗi lần kết nối, console đọc
  `meta.version`. Chưa có agent → mời chạy cài đặt; agent cũ hơn → hỏi và nâng
  cấp tại chỗ bằng cách đẩy gói của chính console lên `?action=update`
  (giữ nguyên `wifi-socks.conf` + `settings.sh`, router tự backup `pre-update`),
  từ chối thì còn nút **Nâng cấp agent** trên thanh vàng; agent mới hơn console
  → báo lỗi yêu cầu dùng console mới hơn và khoá mọi thao tác thay đổi.
- Wizard cũng ràng buộc version: đọc `VERSION` trên router trước khi ghi và từ
  chối đẩy gói cũ hơn; cài lại agent khi CGI/healthd/UI đã deploy khác với code
  vừa đẩy (trước đây chỉ cần “đã có agent” là bỏ qua, khiến CGI cũ vẫn chạy sau
  khi nâng version); bước cuối báo lỗi nếu agent trả về version khác gói vừa cài.
- Tài liệu tách rõ hai bản chạy: `.exe` cho Windows và binary `sbproxy-console`
  cho Linux/macOS (PyInstaller không cross-compile) — bảng đối chiếu file/lệnh
  build/cách chạy/nơi lưu token, kèm ví dụ PowerShell và shell song song trong
  phần chạy tại hiện trường; README gốc, admin-guide và user-guide ghi chú tương ứng.
- Suite mới `tests/test_desktop_provision.py` và các test GUI cho wizard.

### Changed
- `scripts/release.sh` / `release.ps1` chạy toàn bộ `tests/run-all.sh` trước khi
  commit, tag và push; test hỏng thì dừng ngay, không tạo tag. Chỉ bỏ qua được
  bằng `--skip-tests` / `-SkipTests` khi thật sự cần.

### Fixed
- `release.ps1` không còn kiểm tra `$Version` trước khi biến đó được tính ra từ
  `VERSION` — lỗi khiến script luôn báo "Version must be semver" và không chạy
  được.
- Rà soát lại toàn bộ tài liệu: bảng API agent bổ sung `kick`/`ban`/`unban`,
  `update`, `backup`, `download_backup` kèm method đúng cho từng action;
  `docs/DEBUGGING.md` viết lại (bỏ phạm vi 4 commit cũ, số assertion cũ, yêu cầu
  Node.js và bước sinh HTML không còn tồn tại) và thêm bản `DEBUGGING.en.md`;
  `CONTRIBUTING.md` trỏ đúng `tests/run-all.sh` và từng suite; `docs/TEST-MATRIX.md`
  bổ sung suite `test_web_console_i18n.py`; đoạn "console builds" trong hai
  admin-guide tách thành danh sách và bỏ phần lặp; user-guide sửa chỗ nói thao tác
  Wi-Fi chỉ nằm ở khung chỉnh sửa (nay là menu chuột phải) và ghi rõ nút ⚡ là của
  bản web.
- Xoá hai file thừa `README.en.md` và `console/desktop/README.en.md` — chỉ là
  trang chuyển hướng, không tài liệu nào trỏ tới.
- Gói đẩy lên router (`pc/update.*`, `pc/make-package.*` và payload nhúng trong
  bản build) không còn kéo theo `dist/`, `build/` và `__pycache__` — trước đó
  file `.exe` vừa build trong `console/desktop/dist/` bị đóng gói vào payload,
  làm gói phình lên hàng chục MB.
- `--where` và chế độ askpass ghi ra stdout qua file descriptor/Win32 handle,
  nên bản build `--windowed` (không có `sys.stdout`) vẫn trả lời được `ssh`;
  `--where` in thêm dòng `payload=` để biết bản build đang dùng gói nào.

## [0.4.1] - 2026-08-23

### Added
- GitHub release builder publishes the Windows executable, router update
  package, agent package, and scripts/documentation package.
- Release scripts support version validation and guarded tag/push operations;
  GitHub milestones remain a separate web/workflow operation.

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
