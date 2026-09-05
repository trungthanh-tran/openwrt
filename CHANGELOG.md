# Changelog

Theo [Keep a Changelog](https://keepachangelog.com/) và [SemVer](https://semver.org/).
Ngày theo định dạng YYYY-MM-DD.

## [Unreleased]

## [0.5.22] - 2026-09-05

### Added
- **Trạng thái sing-box ngay trên trang chính của web console** (thẻ trong
  dãy thống kê + chip cạnh badge Live), đỏ nhấp nháy khi sing-box không chạy —
  trước đây chỉ thấy trong hộp Kết nối. Nút **↻ Khởi động lại sing-box** gọi
  action mới `restart_singbox` (script `scripts/restart-singbox.sh`): bật lại
  cờ service nếu `enabled=0`, restart, **chờ tiến trình thật sự lên** và trả
  về `running/pid/enabled/config_ok/hint` cùng 15 dòng `logread` để biết vì
  sao nó chết. Mục "sing-box không chạy" trong docs/web-console.md hướng dẫn kiểm tra và khởi động lại.

### Fixed
- **Web console không bao giờ vẽ lại cả trang nữa.** Mỗi 30 giây trang từng kéo
  conf từ router rồi `render()` toàn bộ (bảng WiFi nhấp nháy, mất vị trí cuộn
  và ô đang chọn). Giờ poll `status` mỗi 10 giây chỉ vá tại chỗ các ô Sức
  khỏe, chip/thẻ sing-box và dòng version; conf được so với router mỗi 60 giây
  và chỉ vẽ lại khi nội dung thật sự khác.
- **Bảng WiFi và bảng Thiết bị được vá theo khoá thay vì dựng lại `innerHTML`.**
  Bảng Thiết bị (làm mới mỗi 5–60 giây) từng dựng lại toàn bộ mỗi nhịp, phá cả
  vị trí cuộn, đoạn text đang bôi đen và checkbox vừa tick. `patchTable()` giữ
  nguyên node của hàng không đổi, chỉ vẽ lại hàng thật sự khác, chèn hàng mới
  đúng chỗ, gỡ hàng biến mất và **di chuyển** node khi đổi thứ tự sắp xếp.
  `tests/test_web_table_patch.py` chạy chính hàm đó dưới Node với DOM giả và
  đếm số lần ghi `innerHTML` để chứng minh (payload y hệt → 0 lần ghi).
- Release Windows có thêm `sbproxy-console-<version>-windows-x64.exe`: ứng dụng
  Desktop standalone đầy đủ để quản lý SSID, pool proxy, thiết bị, gateway,
  backup và log. Asset này tách biệt với Web Deployer tối giản.
- Release Windows có thêm file standalone
  `sbproxy-web-deployer-<version>-windows-x64.exe`, chạy trực tiếp không cần giải
  nén; gói ZIP đầy đủ vẫn được phát hành song song.
- Thêm hướng dẫn riêng cho Web Deployer và ảnh chụp thật của ứng dụng Windows,
  Desktop Console, dashboard, màn hình thiết bị, proxy pool và giao diện mobile.

### Changed
- Web và Desktop tự dry-run, ghi và apply ngay sau mỗi lần thêm/sửa/xóa Wi‑Fi.
  Pool proxy và thao tác thiết bị vốn đã gọi Agent trực tiếp nên cũng cập nhật
  router ngay; các thao tác làm rớt kết nối vẫn có cảnh báo.
- Gói deploy Windows/Linux kèm cả tài liệu có ảnh; `SHA256SUMS` kiểm tra luôn các
  file nằm trong thư mục con. Hướng dẫn Web Console được rút gọn và bổ sung luồng
  sử dụng theo từng màn hình.

## [0.5.21] - 2026-09-05

### Fixed
- Windows Web Deployer không còn crash lúc mở do `BooleanVar` nhận nhầm giá trị
  boolean làm Tk master. Thêm smoke test dựng cửa sổ thật và self-test GUI cho
  executable trước khi đóng gói release.

## [0.5.20] - 2026-09-05

### Added
- **Gói deploy theo hệ điều hành**: Windows x64 phát hành dưới dạng `.zip`, Linux
  dưới dạng `.tar.gz`; mỗi gói có Web Deployer tối giản, router update package,
  checksum SHA-256 và tài liệu. GitHub Actions build/test riêng trên Windows và
  Linux rồi mới tạo release.
- **Web Deployer tối giản** chỉ dành cho kiểm tra SSH, cài/cập nhật sbproxy và mở
  Web Console. Cho phép sửa router IP/host, SSH port, username và password nhưng
  không chứa chức năng quản lý Wi-Fi/proxy; update giữ nguyên cấu hình đang chạy.
- **Danh sách thiết bị giờ có lịch sử, không chỉ máy đang kết nối.**
  `clients.sh` ghi nhớ mọi máy từng vào WiFi và trả thêm `status`
  (`online` / `blocked` / `offline`), `first_seen`, `last_seen`, `inactive_s`.
  Kho lịch sử nằm ở `/tmp/sbproxy.seen` (ghi mỗi lần poll, không mòn flash) và
  chỉ chép sang `/etc/sbproxy.seen` **khi có máy mới lần đầu**, nên sống sót
  qua reboot/sysupgrade với vài lần ghi flash mỗi máy; giới hạn `SEEN_MAX`
  (mặc định 400), máy cũ nhất bị loại trước.
- **Màn hình Thiết bị trên web ngang bằng bản desktop**: cột Trạng thái
  (`đang kết nối 5p`, `đã ngắt 2g 15p`, `bị cấm`), lọc theo WiFi/trạng thái +
  tìm kiếm, sắp xếp theo cột, dòng tóm tắt, tự làm mới chọn nhịp
  (5/10/30/60s), **ℹ Chi tiết** một máy, **⛔ Chặn MAC…** cho MAC chưa từng
  kết nối, **⭳ Xuất CSV** (UTF-8 có BOM).
- **Các tính năng desktop còn thiếu đã được port sang web**: 🎲 đổi MAC/BSSID
  ngẫu nhiên có chọn hãng (`rotate_mac`), 📌 ghim / Tự động cho đường ra
  (`set_gateway`), xoá slot pool chọn lọc (từ chối slot đang có thiết bị
  online dùng), nhận 7 định dạng proxy của nhà cung cấp như bản desktop, và
  hỏi nhãn khi tạo backup.
- `tests/test_clients.sh` (38 assert) cho `clients.sh`, cùng một khối trong
  `tests/run.sh` khoá lại từng tính năng web trong bảng parity của
  [docs/web-console.md](docs/web-console.md).
- [docs/web-console.md](docs/web-console.md) (+ bản EN) thêm hai chương:
  **Khởi tạo router từ đầu (5 bước)** — đúng chuỗi lệnh mà file exe chạy qua
  SSH, dành cho người không dùng exe, kèm bảng xử lý khi hỏng giữa chừng — và
  **Cập nhật** (từ web bằng package, từ máy tính qua `pc/update.sh`, hoặc
  `self-update.sh` ngay trên router; những gì được giữ nguyên; vì sao phải
  bấm Đẩy & Áp sau đó).

- **Web console trên router có đăng nhập riêng.** `install-agent.sh` tạo tài
  khoản (mặc định `admin` + mật khẩu ngẫu nhiên, in ra cuối màn hình cài; ghi
  đè bằng `SBPROXY_WEB_USER`/`SBPROXY_WEB_PASS`); lệnh mới `sbproxy-webauth`
  (set/show/check/disable) quản lý tài khoản trong `/etc/sbproxy/webauth`
  (salt + SHA-256, không lưu mật khẩu thật). Agent có action `login` — action
  duy nhất không cần Bearer — đổi user/pass lấy token, chờ ~1 s mỗi lần sai và
  khoá 5 phút sau 5 lần sai (429). Hộp Kết nối trên web đăng nhập bằng
  user/pass (token chuyển thành mục "Nâng cao"), hiện 👤 tài khoản trên thanh
  trên và có nút Đăng xuất (quên token + tài khoản trong trình duyệt).
- **Giao diện web kiểu AdminLTE nhẹ trên Bootstrap offline.** Bootstrap
  5.3.3 (`console/web/assets/bootstrap.min.css`) được deploy vào
  `/www/sbproxy/assets/` — không CDN, router không có Internet vẫn hiển thị
  đúng; thiếu assets thì trang tự chạy bằng stylesheet dựng sẵn. Bố cục mới:
  sidebar trái (nhóm Cấu hình + nhóm Router khi đã kết nối), thanh trên
  (menu ☰ cho mobile, phiên bản, tài khoản, Live, ngôn ngữ, theme). Toàn bộ
  id/logic JS giữ nguyên nên hành vi và các test parity không đổi.
- **Web bắt kịp desktop hai công cụ chẩn đoán**: nút 🩺 trên từng dòng WiFi
  (`diagnose_ssid` — chỉ ra mắt xích hỏng trên đường dữ liệu) và nút
  🧪 Test proxy trong form Thêm/Sửa WiFi (`probe_proxy` — test proxy đang
  nhập từ router, kèm lý do fail). `self-update.sh` deploy thêm
  `assets/` và `sbproxy-webauth` khi cập nhật.
- Tài liệu mới [docs/web-console.md](docs/web-console.md) (+ bản EN): đăng
  nhập và quản lý tài khoản, bố cục màn hình, bảng map tính năng
  desktop ↔ web theo từng action agent, khắc phục sự cố.
- **Tạo tài khoản đầu tiên và đổi mật khẩu ngay trên web.** Router chưa có
  tài khoản: trang tự mở form "Tạo tài khoản quản trị đầu tiên" (action mới
  `setup_account`, chỉ chạy khi chưa có tài khoản; `login` trả
  `setup_required:true`; `login_state` cho UI biết trạng thái). Nút
  **🔑 Đổi mật khẩu** trong hộp Kết nối (action `change_password`, cần cả
  Bearer token lẫn mật khẩu hiện tại; sai bị chờ ~1 s + ghi syslog).
  `install-agent.sh` không tự sinh tài khoản ngẫu nhiên nữa — lần mở web đầu
  tiên tạo tài khoản; provisioning tự động vẫn tạo sẵn được qua
  `SBPROXY_WEB_USER`/`SBPROXY_WEB_PASS`.

### Fixed
- **Bảng Thiết bị trên web bị lệch cột**: header có 8 cột trong khi mỗi hàng
  render 9 ô (cột Proxy được thêm vào hàng mà quên thêm header). Test đếm số
  cột header của đúng bảng này để lỗi không lặp lại.
- Màn hình Thiết bị báo "không có thiết bị" khi agent thật ra trả lỗi: kiểm
  tra `ok` giờ chạy trước khi đếm danh sách. Bỏ nhánh chết còn sót và bản
  `loadPool()` trùng lặp.
- **Đẩy & Áp trên web giờ dry-run trước khi ghi** như bản desktop: cấu hình
  router bị từ chối sẽ được phát hiện khi cấu hình đang chạy vẫn còn nguyên,
  thay vì ghi đè rồi mới hỏng lúc apply.
- Sinh salt cho tài khoản web chạy được trên cả router lẫn workstation: thử
  `hexdump`, rồi `od`, rồi lọc trực tiếp từ `/dev/urandom` — trước đó image
  thiếu một trong hai công cụ sẽ nhận salt rỗng.
- `/etc/sbproxy.bans`, `/etc/sbproxy.assign` và `/etc/sbproxy.seen` được đăng
  ký vào `/etc/sysupgrade.conf` nên lệnh cấm, ghim proxy và lịch sử thiết bị
  không mất sau khi nâng cấp firmware.

Đợt rà soát regression 0.5.9 → 0.5.19:
- **`apply.sh` chết trước khi Wi-Fi kịp lên lại**: khi sing-box không start
  được, `verify_singbox_running` từng `die` trước `wifi reload` +
  `recover_wifi_networks`, để mọi SSID biến mất và có thể mất luôn đường quản
  trị. Giờ Wi-Fi được khôi phục trước, apply vẫn báo lỗi to và rõ sau đó.
- **Che mật khẩu trong log/transcript không còn dùng sed**: mật khẩu chứa
  `|`/`[` từng làm sed lỗi (mất transcript, verdict sai), chứa `.`/`*` thì lộ
  cleartext, và một mật khẩu dạng lệnh sed có thể ghi file tuỳ ý. Thay bằng
  `mask_secret` (awk `index()`, so khớp literal) tại probe-proxy, diagnose-ssid,
  healthd và lib.sh.
- **Web Reset toàn bộ lấy trạng thái từ router**: trình duyệt mới (localStorage
  rỗng) từng hiện "Xoá TẤT CẢ 0 SSID", bỏ trống bước xoá pool nhưng vẫn wipe
  router. Cả web lẫn desktop giờ kéo `get_conf` từ router trước, đếm và xoá
  pool theo đúng cấu hình thật; test parity so khớp cả bước này.
- **`diagnose-ssid.sh` parse hỏng khi cột idx có khoảng trắng đệm**: awk rebuild
  cả dòng làm mọi `cut -d'|'` đọc sai field và lộ wifi key + proxy pass vào
  report. Giờ trim trên bản sao của field. Thêm: khi SSID chạy pool, proxy
  fallback trong conf chết không còn thành verdict — probe slot 0 của pool
  (`pool_proxy`) thay thế; verdict "blocked" nói rõ khả năng SOCKS server im
  lặng chờ handshake (nghi sai credentials/loại proxy khi port chắc chắn mở).
- **`switch-gateway.sh`**: router chỉ có một uplink (không có gì để đổi) từng
  trả 400 giả vì `jq --argjson changed ""`; `uci set` lỗi giữa chừng để lại
  thay đổi staged (bị flush bởi lần `uci commit network` sau); interface chỉ có
  trong ubus (không có section uci) làm cả thao tác thất bại. Giờ: danh sách
  rỗng → `[]`, lỗi → `uci revert network`, interface động → bỏ qua. CGI tách
  stderr khỏi stdout nên warning của uci không biến thao tác thành công thành
  lỗi 500 nữa.
- **Desktop — Test proxy không còn treo app**: probe chạy ở thread nền, kết quả
  trả về main thread qua `after()`; app không còn "Not Responding" 15–45 s.
- **Desktop — proxy chưa test không còn bị dán nhãn [FAIL]**: một predicate
  duy nhất (`ok`/`??`/`FAIL`) quyết định nhãn, hộp cảnh báo và status bar;
  trạng thái `unknown`/`skipped` hiện `[??]`, không mở dialog lỗi.
- **Desktop — auto-probe proxy vừa thêm có giới hạn** (8 proxy đầu): dán 256
  proxy không còn giữ màn hình loading cả giờ; phần còn lại ghi rõ "chưa test".
- **Desktop — màn hình Pool không crash với dòng dữ liệu lạ**: row không phải
  dict được thay bằng placeholder (giữ nguyên số slot) thay vì làm dialog
  không mở được.
- **healthd bớt phụ thuộc /tmp**: kết quả probe trả qua biến (không còn file
  tạm cho output), /tmp đầy/read-only chỉ mất chi tiết lỗi chứ không làm probe
  fail giả hay gán nhầm lỗi sang proxy khác.

## [0.5.20] - 2026-08-31

### Fixed
- Agent không còn trả HTTP 200 với body rỗng/không hợp lệ khi `jq` không dựng được
  payload `status`; lỗi nội bộ giờ luôn được trả về dưới dạng JSON. Console cũng phân
  biệt phản hồi HTML, phản hồi rỗng và text lỗi để chỉ đúng endpoint CGI bị hỏng.
- Mật khẩu proxy trong bảng Pool và hộp Chi tiết proxy luôn được che thành `****`;
  giá trị thật chỉ được giữ nội bộ để lưu cấu hình và kiểm tra proxy.

## [0.5.19] - 2026-08-30

### Tests
- `tests/test_reset_parity.py`: chạy hàm Reset thật của web (Node) và desktop
  trên cùng một fixture, so từng lời gọi agent và cả các guard (từ chối cảnh
  báo, gõ sai chữ, gõ đúng bất kể hoa/thường) để hai bản không bao giờ lệch nhau.

## [0.5.18] - 2026-08-30

### Added
- Nút **Reset toàn bộ** (desktop: thanh công cụ Wi-Fi; web: **⟲ Reset toàn bộ**
  trong thanh công cụ khi đã kết nối agent): đá mọi thiết bị đang
  kết nối, xoá mọi pool proxy, ghi `wifi-socks.conf` rỗng rồi apply. Có cảnh báo
  mặc-định-từ-chối và phải gõ `RESET` mới chạy; thiết bị đã rời mạng không làm
  hỏng quy trình; apply lỗi thì danh sách trên app giữ nguyên.

## [0.5.17] - 2026-08-30

### Fixed
- **Sau khi flash firmware, sing-box không bao giờ chạy — WAN thông nhưng mọi
  SSID proxy mất mạng.** Gói `sing-box` của OpenWrt ship `/etc/config/sing-box`
  với `option enabled '0'`; init script `start_service` trả về ngay khi cờ này
  là 0, nên `/etc/init.d/sing-box restart` thành công… mà không khởi động gì.
  Script chỉ chạy `sing-box enable` (symlink boot) nên console báo
  `singbox=stopped` từ lần connect đầu tiên. Giờ `apply.sh` và
  `install-deps.sh` đặt `sing-box.main.enabled=1` + `conffile`, và sau restart
  `apply.sh` **xác nhận tiến trình lên** (chờ tối đa 6 s); không lên thì apply
  báo lỗi kèm 15 dòng log sing-box thay vì "APPLY COMPLETE" giả. `doctor.sh` và
  `diagnose_ssid` có thêm mục `singbox_service`.

## [0.5.16] - 2026-08-29

### Fixed
- Mở màn hình Pool: đoạn ghi log health/slot không thể ném lỗi chặn mở màn hình
  nữa (dòng dữ liệu lạ được log và bỏ qua).

### Tests
- Màn hình Pool: dựng dialog thật trên Tk và kiểm tra đủ dòng/cột với mọi nhánh
  health (không có / ok / fail kèm lý do), hai ngôn ngữ, nút Test proxy có/không,
  probe lỗi, pool rỗng — chống hồi quy "bảng proxy trắng". Mở Pool: proxy đi đủ
  vào dialog, log lý do, dòng lạ không chặn mở.

## [0.5.15] - 2026-08-29

### Fixed
- `probe-proxy.sh`: phép thử TCP thô dùng `telnet://`, mà curl trên OpenWrt không
  có (exit 1) nên kết quả "TCP mở/đóng" vô nghĩa. Giờ thử bằng `http://host:port/`:
  refused / timeout / không phân giải → đóng; mọi phản hồi khác (kể cả SOCKS trả
  rác) → mở. Verdict `blocked` vì thế dựa trên bằng chứng thật.

## [0.5.14] - 2026-08-29

### Fixed
- CI shellcheck đỏ ở 0.5.13: dấu nháy đơn trong `${public_ip:-…}` của
  `probe-proxy.sh` (SC1073) và tách từ có chủ ý trong healthd (SC2046). `tests/run.sh`
  giờ chạy đúng lệnh shellcheck của CI khi máy có shellcheck, nên lỗi lint bị
  bắt trước khi tag; thêm test cho nhánh verdict khi không lấy được IP public.

## [0.5.13] - 2026-08-29

### Fixed
- Nâng cấp agent từ console xong thì agent trả `HTTP 403 Forbidden`. uhttpd từ
  chối CGI thiếu bit thực thi cho *others*; `chmod +x` trong `self-update.sh`
  và `install-agent.sh` phụ thuộc `umask` của tiến trình gọi — chạy dưới CGI
  của chính agent có thể chỉ còn `u+x`. Giờ `self-update.sh` và action `update`
  đặt `umask 022`, mọi file deploy được `chmod 755` tường minh. Router đang kẹt
  403: `chmod 755 /www/cgi-bin/sbproxy` hoặc Post-flash setup → cài lại agent.

## [0.5.12] - 2026-08-29

### Added
- **Biết vì sao proxy đỏ.** healthd giữ lại lý do curl thất bại (`curl exit N: …`,
  mật khẩu đã che) trong `error` của mỗi probe; hộp Chi tiết proxy hiện dòng
  "Lý do". Agent thêm `POST probe_proxy {host,port,user?,pass?,type?}` chạy
  `scripts/probe-proxy.sh`: curl qua proxy đó ngay lúc bấm, trả về `curl_exit`,
  `error`, `hint` (whitelist IP / sai user-pass / curl thiếu SOCKS / timeout…)
  và đuôi transcript curl. Desktop có nút **Test proxy** trong màn hình Pool.
  Để tách đúng bệnh mà PC không gặp, script còn thử: curl có nói được SOCKS
  không, TCP tới host:port có mở không (không bắt tay SOCKS), router ra Internet
  trực tiếp được không, IP public của router, và đuôi `logread` của sing-box về
  proxy đó — rồi trả `verdict`: `blocked` (nhà cung cấp whitelist IP → cần thêm
  IP public vừa đo), `auth`, `socks-refused`, `curl-no-socks`, `wan-down`, `ok`.
- **Chẩn đoán "vào được Wi-Fi mà không có Internet".** Nút **Chẩn đoán** ở
  thanh sửa SSID (desktop) gọi `GET diagnose_ssid&idx=N` → `scripts/diagnose-ssid.sh`
  đi một vòng đường đi gói tin: wifi-iface, địa chỉ bridge, lease DHCP,
  bridge-nf, bảng/chain/vmap/rule tproxy nft, ip rule fwmark + bảng route, tiến
  trình/cổng nghe/config sing-box, probe proxy (kèm verdict ở trên), log sing-box,
  conntrack. `verdict` nêu mắt xích hỏng đầu tiên; báo cáo hiện trong cửa sổ
  copy được và ghi nguyên văn vào log console.
- **Thêm proxy là tự kiểm tra ngay.** Sau khi lưu pool (kể cả luồng "thêm proxy
  và phân phối thiết bị"), console chạy `probe_proxy` cho từng proxy mới; kết quả
  từng slot ghi vào log, proxy nào không đi được từ router thì mở ngay cửa sổ
  báo cáo với kết luận (`blocked`/`auth`/…) — không phải chờ device treo mới biết.
- Mở màn hình Pool ghi vào log console trạng thái health của SSID kèm lý do
  fail và danh sách slot, để gửi thư mục log là đủ để chẩn đoán từ xa.

## [0.5.11] - 2026-08-28

### Added
- **Đổi đường ra Internet ngay từ console.** Nút **Đổi đường ra** cạnh ô Đường ra
  (desktop) và nút **🌐 Đường ra** trên web mở danh sách interface của router;
  chọn một cái rồi đổi: interface đó nhận metric route 0, các uplink khác lùi về
  metric 100, network reload, và lựa chọn được ghim làm `GATEWAY_EXPECTED_INTERFACE`.
  Agent thêm `POST switch_gateway {interface}`; `scripts/switch-gateway.sh` từ chối
  interface đang down, không có default route, hoặc là bridge SSID proxy.
  Chọn trong ô Đường ra như trước vẫn chỉ ghim kỳ vọng để kiểm tra.
- Cài đặt sau flash: gặp cảnh báo `REMOTE HOST IDENTIFICATION HAS CHANGED` (router
  vừa flash lại nên host key SSH đổi) console hiện hộp thoại giải thích và đề nghị
  xoá khoá cũ trong `known_hosts` của ứng dụng rồi chạy lại ngay.

### Fixed
- Đường ra: `wan` và `wan6` cùng nằm trên một device (`eth1`) nên cả hai bị đánh
  dấu "đang dùng" và "Tự động" trỏ vào `wan6`; chọn `wan` xong bảng vẫn báo `wan6`.
  `gateway.sh` giờ ưu tiên interface có địa chỉ IPv4 trên device đó (route kiểm tra
  là IPv4), chỉ interface ấy là "đang dùng".
- `save_conf` từ chối dòng 12 cột (`proxy_type`) với "cần đúng 10 hoặc 11 cột" trong
  khi dry-run ngay trước đó đã chấp nhận — đẩy cấu hình có proxy HTTP thất bại sau
  khi dry-run báo OK. Tiền-kiểm của agent giờ nhận 10, 11 hoặc 12 cột như `validate_conf`.
- SSH từ console: đường dẫn `known_hosts` nằm trong thư mục người dùng có khoảng
  trắng (`C:\Users\Ca Nha Vui`) bị ssh cắt ở dấu cách đầu tiên vì giá trị `-o`
  được tách theo khoảng trắng; giờ được bọc trong dấu nháy.

## [0.5.10] - 2026-08-28

### Fixed
- `build_nft` sinh `set proxy_hosts { type ipv4_addr }` thiếu dấu `;` khi
  `wifi-socks.conf` chưa có proxy nào. nftables 1.1.x trên OpenWrt 25.12 parse
  chặt hơn và báo `set definition does not specify key`, nên dry-run trong
  "Post-flash router setup" dừng ở bước preflight. Khai báo set giờ luôn kết
  thúc bằng `;` cho cả `type` lẫn `elements`.

## [0.5.0] - 2026-08-26

### Added
- **Cập nhật mang theo khoá `settings.sh` mới.** Router vẫn giữ nguyên
  `settings.sh` của mình, nhưng khoá nào bản mới giới thiệu mà router chưa từng
  có sẽ được **thêm vào cuối file kèm đoạn chú thích của nó**. Không giá trị nào
  đang đặt bị đụng tới, dòng có dấu nháy không cân bằng bị bỏ qua thay vì chép
  nửa vời, và log cập nhật liệt kê đúng những khoá đã thêm.
- `bridge_nf_ok`: `preflight.sh` và `doctor.sh` cảnh báo khi
  `bridge-nf-call-iptables=1` — TPROXY khớp gói rồi không bao giờ giao tới
  sing-box, mọi SSID có proxy treo, log sạch trơn.
- `tests/vm/datapath.sh`: kiểm gói tin thật đi đúng slot, bằng chính code
  production, hai client trong network namespace và một SOCKS5 giả mỗi slot.
- **Một SSID mang được nhiều proxy.** `config/proxy-pools.conf` khai báo pool
  cho từng Wi-Fi (`idx|proxy_type|host|port|user|pass|label`); mỗi proxy là một
  *slot* với cổng TPROXY và outbound sing-box riêng. Thiết bị nào dùng proxy nào
  do **một map nftables** quyết định — đổi proxy cho một máy chỉ là
  `nft add element`, không sinh lại config, không restart, không ngắt Wi-Fi.
- **Ghim dính theo thiết bị.** Máy vào mạng được gán một slot và **giữ nguyên
  proxy đó qua các lần vào lại**, vì IP ra ngoài nhảy liên tục sẽ làm hỏng phiên
  đăng nhập. Chọn slot theo `POOL_ASSIGN_POLICY`: `random` (mặc định),
  `round-robin`, `least-loaded`, `sticky-hash`.
- **Chia đều một danh sách proxy cho các thiết bị đã chọn.** Dán danh sách vào
  console, chọn máy, xem trước bảng ánh xạ, rồi áp dụng. Số máy trên mỗi proxy
  chênh nhau tối đa 1. Bảng xem trước **chính là** thứ được gửi đi — cùng một
  phép chia, không tính hai lần.
- **Ghim ngay khi cấp lease.** `/usr/libexec/sbproxy-dhcp-assign` được dnsmasq
  gọi lúc cấp DHCP, tức trước mọi lưu lượng ứng dụng. `apply.sh` tự trỏ
  `dhcpscript` vào đó, nhưng **không bao giờ chiếm** `dhcpscript` đang thuộc về
  script khác.
- **Daemon `sbproxy-assignd`** làm lưới an toàn cho ba trường hợp móc DHCP không
  bắt được: máy đặt IP tĩnh, `dhcpscript` đã có chủ, và bảng nftables bị xoá do
  restart. Nó cũng tự phát hiện map lệch với file state rồi nạp lại.
- Console desktop: khu **Pool proxy** ở tab Wi‑Fi (bảng slot kèm số máy đang
  dùng), cột **Proxy** và menu chuột phải ở tab Thiết bị.
- Agent: `get_pool`, `save_pool`, `assign_proxy`, `rebalance`. `clients` trả
  thêm `slot`, `proxy_label`, `proxy_host`, `proxy_state`, `pool_size`.
  `status.meta` trả thêm `pool_port_base`, `pool_port_stride`.
- `tests/vm/spike.sh` — nạp luật **thật** vào nhân để trả lời những câu mà bộ
  test workstation không trả lời được. Chạy được trên máy ảo OpenWrt hoặc thẳng
  trên router. Xem [tests/vm/README.md](tests/vm/README.md).

### Fixed
- **Cập nhật ghi đè pool của router bằng pool của người đóng gói.**
  `make-package.sh` đóng cả thư mục `config/`, còn `self-update.sh` chỉ giữ lại
  `wifi-socks.conf` và `settings.sh`. Người build package thường chính là người
  chạy router, nên `proxy-pools.conf` của họ đi theo gói và thay thế file trên
  router — mọi SSID có pool bị trỏ sang proxy khác, còn số slot trong
  `/etc/sbproxy.assign` vẫn ghim thiết bị vào những dòng giờ mang nghĩa khác.
- **Ruleset pool sinh ra không nạp được.** SSID có pool nhưng chưa ghim thiết bị
  nào sinh ra `map w1map { … size 512 }` — thiếu dấu `;` trước `}`, và nft từ
  chối *cả file*. Mọi pool đều bắt đầu ở đúng trạng thái đó, nên `apply.sh` sẽ
  hỏng trên router đầu tiên dùng pool. Không assertion nào thấy được vì tất cả
  đều đọc file dưới dạng chuỗi; giờ output được đưa thẳng cho `nft -c`.
- **`ALLOW_UNSUPPORTED_BOARD=1` trên dòng lệnh không có tác dụng.** `settings.sh`
  gán đè `0` sau khi env đã có, đúng lệnh mà hướng dẫn VM bảo chạy.
- **SSID nào khai `proxy_type` đều bị `apply.sh` phá.** `validate_conf` chấp
  nhận 10, 11 hoặc 12 cột nhưng `desired_idx` chỉ khớp 10 hoặc 11, mà cột thứ 12
  chính là `proxy_type`. `desired_idx` nuôi `emit_stale_uci`, thứ xoá section
  `wireless`/`network`/`dhcp`/`firewall` của mọi idx không còn trong danh sách —
  nên lần apply kế tiếp phá đúng những SSID dùng proxy HTTP.
- **Snapshot không chứa pool và pin.** `backup.sh` chỉ chép `wifi-socks.conf` và
  `sbproxy.nft`. Mà `pool.sh replace` chụp snapshot *ngay trước* khi thay pool,
  nên bản backup ấy là thứ duy nhất không thể hoàn tác được thao tác nó được tạo
  ra để hoàn tác. Giờ cả hai script đi qua cùng một danh sách, và hai tên file cũ
  giữ nguyên để snapshot cũ vẫn khôi phục được.
- `security-audit.sh` không kiểm quyền `proxy-pools.conf`, file chứa credential
  của mọi proxy trong mọi pool.

### Changed
- `install-deps.sh` cài thêm **`kmod-nft-socket`** — phụ thuộc mới duy nhất của
  cả tính năng. Nó cho phép luật *divert*, thứ chuyển việc tra map từ **mỗi gói**
  sang **mỗi kết nối**. Thiếu gói này thì `POOL_DIVERT="auto"` tự tắt divert và
  mọi thứ vẫn chạy, chỉ chậm hơn.
- `preflight.sh` kiểm thêm số học cổng pool, `socket transparent` nhân có nhận
  không, và `dhcpscript` đang thuộc về ai.


## [0.4.12] - 2026-08-25

### Fixed
- **Nâng cấp agent từ console báo `package is not a .tar.gz or .zip file` dù gói
  hoàn toàn bình thường.** `self-update.sh` nhận diện gói **chỉ bằng `od`** —
  một applet BusyBox mà nhiều image không build vào. Thiếu `od` là chuỗi magic
  rỗng và mọi gói đều bị từ chối. Giờ thử `od`, rồi `hexdump`, cuối cùng hỏi
  thẳng `tar tzf` / `unzip -l`; câu từ chối cũng in kèm kích thước và 4 byte đầu
  để lần sau biết ngay lý do.
- `set -e` + `hexdump` không tồn tại từng làm `self-update.sh` chết ngang với
  mã 127 mà không in gì (phép gán trong nhánh `||` mang mã lỗi 127).

### Added
- **Nâng cấp agent giờ chạy theo từng bước có checklist và nhật ký**, thay cho
  một tác vụ đơn không rõ trạng thái: chuẩn bị gói → kiểm tra phiên bản → đẩy
  gói → kiểm tra agent sau nâng cấp. Mỗi bước hiện trạng thái riêng, **toàn bộ
  log của router** được in ra khung nhật ký, và **lỗi thì dừng ngay tại bước
  hỏng** (không treo, không đóng cửa sổ giữa chừng) kèm gợi ý cài lại agent qua
  SSH.
- Console **kiểm tra gói trước khi đẩy lên**: thiếu file, rỗng, hoặc không phải
  .tar.gz/.zip đều bị chặn tại chỗ với thông báo rõ ràng thay vì để router trả
  về câu khó hiểu.

## [0.4.11] - 2026-08-25

### Added
- **`DNS_UPSTREAM` trong `config/settings.sh`** (mặc định `1.1.1.1`): resolver mà
  sing-box hỏi thật. Trước đây địa chỉ này nằm cứng trong `lib.sh`, không có
  cách nào đổi ngoài sửa code — ai bị chặn 1.1.1.1 hoặc phải dùng DNS nội bộ đều
  kẹt. Nhận IP hoặc hostname; ký tự lạ bị `validate_settings` từ chối vì giá trị
  đi thẳng vào cấu hình sing-box.
- **`ALLOW_UNSUPPORTED_BOARD` trong `config/settings.sh`** (mặc định `0`): đặt
  `1` để `validate_platform` chỉ cảnh báo thay vì dừng trên thiết bị không phải
  GL-MT6000. Thông báo lỗi cũ giờ chỉ luôn cách bật tham số này.
- `status` trả thêm `meta.net_base`, `meta.tproxy_port_base`, `meta.bssid_limit`
  — đúng giá trị `config/settings.sh` router đang dùng.

### Fixed
- **Hai console không còn tự chép hằng số của router.** Console desktop hiển thị
  subnet bằng `192.168.{10 + idx}` và console web đặt cứng
  `NET_BASE = 10, TPROXY_BASE = 12000, BSSID_LIMIT = 16`, trong khi router đọc
  các giá trị này từ `config/settings.sh` và chúng **được phép sửa** — đổi
  `NET_BASE` là cả hai console hiện sai subnet, sai gateway, sai cổng TPROXY và
  web console kiểm tra sai giới hạn BSSID. Giờ cả hai lấy từ `status.meta`, chỉ
  dùng hằng số cũ khi agent quá cũ không gửi.

### Added
- **Chọn interface làm đường ra ngay trên console.** Khung Internet Gateway có
  thêm ô **Đường ra** liệt kê mọi interface router báo về (tên, device, IP,
  đang dùng / không hoạt động / SSID proxy). Mặc định là **Tự động** — bám theo
  interface đang thật sự ra Internet — và chọn một tên là ghim lại. Danh sách
  lấy từ router chứ không có tên nào viết sẵn trong code.
- `gateway` trả thêm mảng `interfaces[]` (name, device, proto, ipv4, up,
  default_route, current, proxied) và agent có endpoint mới
  **POST `set_gateway`** `{interface}` (`""` = tự động) để lưu lựa chọn vào
  `/etc/sbproxy/env`. Tên interface chỉ nhận `A-Za-z0-9._-` tối đa 32 ký tự vì
  file đó được agent `.` source — mọi ký tự shell hiểu được đều bị từ chối.
- `install-agent.sh` **giữ lại lựa chọn đường ra** khi cài lại agent (trước đây
  file env bị ghi đè toàn bộ), và không còn ghi sẵn tên interface nào.

## [0.4.10] - 2026-08-25

### Fixed
- **Khung Internet Gateway luôn báo “degraded · NOT VIA wwan” trên router dùng
  WAN dây.** `install-agent.sh` ghi cứng `GATEWAY_EXPECTED_INTERFACE=wwan` vào
  `/etc/sbproxy/env`, nên mọi đường ra không phải Wi-Fi-as-WAN đều bị coi là
  sai — kể cả khi link, DNS và HTTP đều tốt. Mặc định giờ là **không ghim
  interface nào**: uplink nào mà default route chọn cũng được chấp nhận (WAN
  dây, PPPoE, LTE, Wi-Fi as WAN). Vẫn ghim được bằng
  `GATEWAY_EXPECTED_INTERFACE` trong `/etc/sbproxy/env` nếu muốn ép một đường
  ra duy nhất.
- **Nâng cấp agent tại chỗ giờ gỡ được luôn dòng ghim cũ trong
  `/etc/sbproxy/env`.** Agent nạp file env trước mọi script, nên giá trị nằm đó
  luôn thắng mặc định trong code: nếu chỉ thay `gateway.sh` thì router đã cài từ
  trước vẫn đọc `GATEWAY_EXPECTED_INTERFACE=wwan` và tiếp tục báo degraded.
  `self-update.sh` (đường mà nút **Nâng cấp agent** dùng) giờ xử lý dòng đó theo
  **thực tế của router**: còn đang đi ra bằng `wwan` thì giữ nguyên (ghim đó vô
  hại, và có thể là lựa chọn cố ý); chỉ khi router đi đường khác — tức ghim đang
  báo sai — mới comment dòng đó lại, **giữ nguyên giá trị** và ghi lý do ngay
  bên cạnh để bật lại chỉ mất một lần sửa. Giá trị khác `wwan` không bao giờ bị
  đụng tới, các biến còn lại trong file giữ nguyên.
- Đường ra **vòng qua bridge của SSID được proxy** (`br-w<idx>`) — tức routing
  loop — giờ bị bắt và gọi đúng tên, đây mới là trường hợp luôn sai bất kể WAN
  dựng kiểu gì. `gateway` trả thêm trường `egress_problem`
  (`""` / `proxied-bridge` / `not-expected`) và console hiển thị theo đó thay vì
  luôn in “KHÔNG QUA wwan”.

### Added
- `tests/test_gateway.sh`: bộ test đầu tiên cho `scripts/gateway.sh` (stub
  `ip`/`ubus`/`curl`/`nslookup`) phủ WAN dây, Wi-Fi as WAN, interface bị ghim,
  routing loop qua SSID, mất route, DNS hỏng và HTTP hỏng.

## [0.4.9] - 2026-08-25

### Added
- **Router chưa có `wifi-socks.conf` thì console tạo sẵn một file trống** kèm
  nguyên phần chú thích các cột lấy từ `wifi-socks.conf.example` (chỉ dòng
  comment, không lấy 3 SSID mẫu — chúng có mật khẩu mẫu và SOCKS giả). Nhờ vậy
  `apply.sh` chạy được ngay trong lúc cài (đặt country code, dựng bảng nftables,
  ghi cấu hình sing-box), và mở file lên là biết luôn từng cột nghĩa là gì. File
  đã có sẵn thì không bao giờ bị ghi đè.

### Fixed
- **Cấu hình không có SSID nào sinh ra JSON sing-box hỏng.** `route.rules` thừa
  một dấu phẩy khi danh sách rule rỗng, nên `sing-box check` từ chối và
  `apply.sh` chết với "The sing-box configuration is invalid". Lỗi này xảy ra
  với router vừa cài xong lẫn khi người dùng **xoá hết SSID rồi bấm Apply**.

## [0.4.8] - 2026-08-25

### Fixed
- **Cài đặt hỏng ở bước “Chạy preflight và dry-run” khi chưa có
  `wifi-socks.conf`** với lỗi `[sbproxy][ERR] Missing configuration:
  /root/sbproxy/config/wifi-socks.conf`. Để trống ô cấu hình là đường đi được
  hướng dẫn (thêm Wi-Fi trong app sau khi cài xong), nhưng `apply.sh` lại đòi
  phải có file đó, nên dry-run chết và cả chuỗi dừng ngay trước khi cài agent.
  Console giờ hỏi router xem đã có `wifi-socks.conf` chưa: chưa có thì **bỏ qua
  dry-run và apply** (ghi rõ lý do trên checklist) rồi chạy tiếp tới cài agent,
  lấy token và mở màn hình điều khiển. Thêm SSID trong app rồi bấm **Đẩy cấu
  hình & Apply** là router được cấu hình đầy đủ.

## [0.4.7] - 2026-08-25

### Added
- **Nhật ký kiểm toán `logs/audit.log`**: ghi mỗi lần **kết nối** (router,
  version agent, console, sing-box đang chạy hay không) và **mọi thay đổi** gửi
  xuống router — `apply`, `save_conf`, đổi SOCKS, random MAC, kick/cấm/bỏ cấm,
  backup, rollback, cập nhật/gỡ agent — kèm user trên máy, kết quả (ok /
  http-4xx / không liên lạc được) và thời gian phản hồi. Chuỗi cài đặt sau khi
  flash cũng ghi `provision.start` / `finished` / `failed` / `cancelled` kèm
  bước hỏng. Thao tác chỉ đọc (status, clients, gateway, backups) không ghi để
  nhật ký khỏi bị ngập.
- Nội dung audit vẫn đi qua bộ che bí mật, nên token/mật khẩu không lọt vào file.

### Changed
- **Log xoay vòng theo ngày và tự xoá sau 7 ngày.** `console.log` và
  `audit.log` xoay vòng lúc nửa đêm (`console.log.YYYY-MM-DD`), giữ đúng 7 bản.
  Mỗi lần khởi động app còn dọn mọi file log cũ hơn 7 ngày — kể cả file
  `console.log.1..5` do cơ chế xoay vòng theo dung lượng cũ để lại, và trường
  hợp app không mở lúc nửa đêm nên chưa bao giờ xoay vòng.

## [0.4.6] - 2026-08-25

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
