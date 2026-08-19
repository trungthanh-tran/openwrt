# Runbook debug cho 4 commit gần nhất

Tài liệu này bàn giao bối cảnh cho người phát triển hoặc Codex khi clone dự án
trên một máy khác. Phạm vi được chốt theo bốn commit sau (mới nhất trước):

| Commit | Thay đổi cần nhớ khi debug |
|---|---|
| `9717744` | Mở rộng `tests/run.sh` lên **75 assertion**, gồm integration test cho `clients.sh`; `jq` thiếu thì 2 nhóm test được skip. |
| `2b38708` | Thêm test/CI/tooling và metadata dự án: `Makefile`, GitHub/GitLab CI, lint, docs freshness, `VERSION`, changelog. |
| `6d9cbdc` | Chuyển UI nguồn từ `ui/` sang `console/web/`, desktop từ `desktop/` sang `console/desktop/`; đường dẫn runtime trên router không đổi. |
| `2bc4aca` | Thêm `scripts/doctor.sh`, `console/desktop/run.ps1` và tài liệu cho Devices, vendor MAC, fake-IP DNS. |

Mốc trước thay đổi là parent của `2bc4aca`. Xem lại toàn bộ phạm vi bằng:

```sh
git log --reverse --stat 2bc4aca^..9717744
git diff --name-status 2bc4aca^..9717744
```

## 1. Dựng môi trường trên máy debug

Máy Linux/WSL là môi trường gần OpenWrt nhất. Cần `git`, POSIX `sh`, `jq`,
`shellcheck`, Node.js 20+, `make` và `hexdump` (thường thuộc `bsdextrautils`).
Không cần router để chạy unit/integration test; các lệnh `uci`, `ubus` và `iw`
đã được stub trong test.

```sh
git clone <repo-url>
cd openwrt-multiwifi-socks5
git rev-parse --short HEAD
git status --short
sh tests/run.sh
```

Kết quả chuẩn tại `9717744` khi có `jq` là `75 pass, 0 fail`. Nếu thiếu `jq`,
hai nhóm phụ thuộc `jq` được ghi `skip` và tiến trình vẫn trả exit code 0. Cài
`jq` trước khi kết luận generator sing-box hoặc `clients.sh` không lỗi. Chạy đầy
đủ giống CI bằng `make check`.

`make check` gồm ShellCheck, test, sinh lại HTML rồi kiểm tra `docs/` không có
diff. GitHub CI chạy Ubuntu; GitLab CI chạy Alpine/BusyBox ash, gần shell thật
trên router hơn. Không dùng Git Bash trộn với tiện ích Windows làm baseline:
khác biệt `sed`/`sort` và việc thiếu `hexdump` có thể tạo false failure. Trên
Windows, dùng WSL cho test shell; desktop chạy riêng bằng:

```powershell
cd console\desktop
.\run.ps1
```

## 2. Bản đồ vùng thay đổi

- Logic chính và generator: `scripts/lib.sh`.
- Test hồi quy: `tests/run.sh`. Test dùng thư mục tạm và stub `uci`, `ubus`,
  `iw`; không đọc hay sửa cấu hình router thật.
- Liệt kê thiết bị: `scripts/clients.sh`; dữ liệu thật đến từ hostapd/ubus,
  `iw` và `/tmp/dhcp.leases`.
- Health report chỉ đọc: `scripts/doctor.sh`.
- Evidence thô chỉ đọc: `scripts/diagnose.sh`.
- UI Web: `console/web/control-panel.html`.
- Desktop native: `console/desktop/main.py` (Tkinter, không dùng WebView); hai
  frontend dùng chung Agent API nhưng không dùng chung mã giao diện. Không sửa
  đường dẫn cũ `ui/` hay `desktop/` vì chúng không còn tồn tại.
- Bản web được cài lên router tại `/www/sbproxy/index.html`; đổi layout trong
  repo không đổi URL `/sbproxy/` và không đổi đường dẫn sysupgrade.

## 3. Trình tự khoanh vùng lỗi

### Lỗi test trên máy phát triển

1. Ghi lại `git rev-parse HEAD`, hệ điều hành, phiên bản `sh`, `jq`, Node và
   ShellCheck, cùng lệnh bị lỗi.
2. Chạy `sh tests/run.sh` để thấy tên assertion đầu tiên fail.
3. Chạy `shellcheck -S warning scripts/*.sh tests/*.sh pc/*.sh config/settings.sh agent/install-agent.sh`.
4. Nếu chỉ CI GitLab lỗi, ưu tiên tìm bashism/khác biệt BusyBox ash. Shell của
   router là POSIX/BusyBox; không dùng array hoặc `[[ ... ]]`.
5. Nếu `docs-check` lỗi, chỉ sửa Markdown nguồn rồi chạy
   `node tools/build-docs.js`; không sửa tay HTML sinh ra.

### Lỗi trên router OpenWrt

Từ đúng checkout đang deploy, chạy theo thứ tự:

```sh
sh scripts/verify.sh
sh scripts/doctor.sh
sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1
```

`doctor.sh` trả non-zero nếu có `[FAIL]`; `[WARN]` không nhất thiết làm hệ thống
hỏng. `diagnose.sh` không restart dịch vụ và lấy board, Wi-Fi, sing-box,
nftables, policy route, log, socket và trạng thái fake-IP.

| Triệu chứng | Điểm kiểm tra đầu tiên |
|---|---|
| sing-box không chạy | Phiên bản phải `>= 1.12`; chạy `sing-box check -c /etc/sing-box/config.json`, xem `logread -e sing-box`. |
| Client ra mạng nhưng leak DNS | Chain `inet sbproxy prerouting` phải có TCP/UDP `dport 53`; config phải có `fakeip`; client `nslookup example.com` trả `198.18.0.0/15`. |
| Không đi qua đúng SOCKS | Kiểm tra inbound/outbound `w<idx>`, rule TPROXY, `ip rule` mark `0x1` và route table 100. |
| Devices rỗng | Kiểm tra `ubus list` có `hostapd.*`, `iw dev <ifname> station dump` và `/tmp/dhcp.leases`. |
| Kick lỗi | Cần instance `hostapd.*` và bản `wpad/hostapd` có ubus đầy đủ. |
| Ban không giữ sau apply | Kiểm tra `/etc/sbproxy.bans` và việc `apply.sh` áp lại danh sách. |
| UI/desktop không tìm thấy file | Tìm ở `console/web/` và `console/desktop/`; loại tham chiếu tới layout cũ. |
| Vendor MAC đổi ngoài ý muốn | Kiểm tra cột 11 `mac_oui` và UCI `wireless.w<idx>.macaddr`; MAC lưu chỉ được giữ nếu còn khớp OUI. |

Sau khi sửa logic router, chạy lại `sh tests/run.sh` trên PC, rồi trên router:

```sh
DRYRUN=1 sh scripts/apply.sh
sh scripts/apply.sh
sh scripts/verify.sh
sh scripts/doctor.sh
```

`apply.sh` thay đổi trạng thái router; phải dùng cấu hình đã kiểm tra và bảo đảm
có backup/đường rollback. Các bài cần client thật nằm trong
[`TESTING.md`](TESTING.md).

## 4. Gói thông tin gửi cho Codex ở máy khác

Không gửi `config/wifi-socks.conf`, token, `/etc/sbproxy.bans`, backup hoặc
password SOCKS/Wi-Fi. Trước khi chia sẻ output, thay IP public, hostname, SSID,
MAC, token và credential bằng placeholder.

Một issue/debug prompt tối thiểu nên kèm:

```text
Commit: <git rev-parse HEAD>
Máy dev: <OS, sh, jq, node, shellcheck>
Router: <model, OpenWrt version, sing-box version>
Triệu chứng: <mong đợi / thực tế / thời điểm bắt đầu>
Lệnh tái hiện: <các lệnh chính xác>
Test đầu tiên fail: <tên assertion hoặc none>
Doctor: <các dòng WARN/FAIL đã che dữ liệu nhạy cảm>
Diagnose: <đoạn liên quan đã che dữ liệu nhạy cảm>
Diff cục bộ: <git status --short và git diff --stat>
```

Luôn nói rõ checkout có chứa đủ bốn SHA ở đầu tài liệu hay không và thay đổi
chưa commit nào đang tồn tại. Không suy luận lỗi router chỉ từ unit test:
TPROXY, hostapd ubus, giới hạn BSSID và radio chỉ xác nhận được trên thiết bị thật.
