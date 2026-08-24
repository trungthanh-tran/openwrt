# sbproxy — Hướng dẫn Quản trị (theo bước)

**Ngôn ngữ:** Tiếng Việt | [English](admin-guide.en.md)

Làm tuần tự từ trên xuống: tải firmware → backup → update → cài đặt → cấu hình → cài agent LAN → kiểm tra → vận hành → bảo mật.

> Bổ trợ: [GUIDE.md](GUIDE.md), [INSTALL.md](INSTALL.md), [TESTING.md](TESTING.md), [ROLLBACK.md](ROLLBACK.md).

## ★ Best practices — đọc trước khi bắt đầu
- **Luôn cắm LAN dây dự phòng** khi động vào firmware/mạng — hỏng WiFi vẫn SSH vào cứu được.
- **Tải backup RA MÁY TÍNH trước mỗi lần update firmware** — backup trên router mất sạch nếu reflash/brick (Bước 3).
- **Verify sha256** mọi image firmware. Giữ sẵn 1 image "biết-chạy-tốt" trên máy.
- **Ghi lại phiên bản firmware hiện tại** (`cat /etc/openwrt_release`) trước khi đổi.
- **Xem trước bằng `DRYRUN=1`** trước khi `apply.sh`. Test **1–2 SSID** rồi mới nhân lên 20–30.
- **Không expose** uhttpd/agent/SSH/LuCI ra WAN. Giữ **token** agent bí mật (Bước 9).
- **Chốt số SSID theo `iw list`** (giới hạn BSSID), đừng giả định cứng 30 (Bước 6).

## Kiến trúc tổng thể
```
WiFi Alpha ─(br-w1, 192.168.11.0/24)─┐
WiFi Bravo ─(br-w2, 192.168.12.0/24)─┤  nftables TPROXY theo iifname
WiFi ...   ─(br-wN, ...)─────────────┘        │  (mỗi WiFi → cổng 12000+idx)
                                              ▼
                                      sing-box (tproxy in → socks out) ──▶ WAN
UI http://router/sbproxy/ ─▶ CGI /cgi-bin/sbproxy ─▶ apply/set-sock/rollback
sbproxy-healthd (procd) ─ curl socks5h ─▶ /tmp/sbproxy-health.json (latency realtime)
```

## Script tương ứng theo từng bước

| Bước | Script | Phạm vi |
|---|---|---|
| 1, 5 | `scripts/inventory.sh` | Thu thập phiên bản, board, radio, dung lượng và địa chỉ; chỉ đọc. |
| 2 | `pc/verify-firmware.ps1` hoặc `pc/verify-firmware.sh` | So khớp SHA-256 firmware với giá trị công bố. Việc tải/chọn image vẫn làm thủ công từ nguồn chính thức. |
| 3 | `pc/backup.ps1` / `pc/backup.sh`, `scripts/backup.sh` | Tạo và tải backup ra máy quản trị. |
| 4 | — | Flash/U-Boot là thao tác vật lý, có nguy cơ brick nên không tự động hóa. |
| 5–10 | `console/desktop` **Cài đặt sau khi flash** | Một chuỗi chạy qua SSH: đẩy mã nguồn, cài phụ thuộc, đẩy cấu hình, chạy preflight/dry-run/apply, cài agent và lấy token — từng bước cập nhật ngay trên giao diện. |
| 6 | `scripts/preflight.sh`, `scripts/install-deps.sh` | Kiểm tra phần cứng rồi cài dependency. |
| 7, 8 | `scripts/apply.sh`, `scripts/uninstall.sh` | Validate/apply cấu hình hoặc gỡ cấu hình do project tạo. |
| 9 | `agent/install-agent.sh`, `scripts/rotate-token.sh` | Cài agent local và xoay token. |
| 10 | `scripts/verify.sh` | Chạy nghiệm thu phía router; kiểm tra leak phía client vẫn cần trình duyệt. |
| 11 | `scripts/set-sock.sh`, `scripts/backup.sh` | Đổi SOCKS và backup vận hành. |
| 12 | `scripts/rollback.sh`, `pc/restore.ps1` / `pc/restore.sh` | Rollback hoặc khôi phục snapshot. Failsafe/U-Boot vẫn thủ công. |
| 13 | `scripts/diagnose.sh` | Gom bằng chứng chẩn đoán, không restart hay sửa trạng thái. |
| 10, 13 | `scripts/doctor.sh` | Báo cáo trạng thái tổng thể (chỉ đọc): gói, sing-box + fake-IP DNS, tproxy/hijack, Wi-Fi, agent; exit ≠ 0 nếu có FAIL. |
| 10, 13 | `scripts/gateway.sh` | Kiểm tra read-only default route, đối chiếu `wwan`, link, DNS và HTTP trực tiếp. |
| 14 | `agent/cgi/sbproxy` | Hiện thực API LAN được UI gọi. |
| 14 | `scripts/clients.sh`, `scripts/{kick,ban,unban}.sh` | Liệt kê thiết bị theo SSID và kick/cấm/bỏ cấm theo MAC. |
| — | `console/desktop/build.ps1` (Windows) / `build.sh` (Linux/macOS) | Build app Tkinter native `console/desktop/main.py` thành `.exe` / binary Linux; không dùng HTML/WebView. Xem [../console/desktop/README.vi.md](../console/desktop/README.vi.md). |
| 15 | `scripts/security-audit.sh` | Audit quyền file, SSH và dấu hiệu mở quản trị; chỉ đọc. |

Chạy các script router từ thư mục project: `cd /root/sbproxy`. Script có thay đổi trạng thái vẫn yêu cầu quyết định rõ của quản trị viên; các script kiểm kê/audit không tự sửa để tránh khóa mất SSH.

---

## Bước 1 — Chuẩn bị
> **Script tương ứng (router, chỉ đọc):** `sh scripts/inventory.sh > inventory-before.txt` — lưu phiên bản, board, radio, dung lượng và địa chỉ hiện tại. Các việc cắm LAN, chọn router và chuẩn bị đường cứu hộ vẫn làm thủ công.

- Router **GL-MT6000 (Flint 2)**. Xác định IP quản trị (GL stock: `192.168.8.1`).
- Cáp **LAN** nối máy tính ↔ router (đường cứu hộ). SSH client + trình duyệt.
- Không thử nghiệm lần đầu trên router đang phục vụ việc quan trọng.
- **Firmware nên dùng:** OpenWrt vanilla mới nhất (hoặc ImmortalWrt nếu cần GUI proxy). Tránh firmware lạ chưa xác thực nguồn.

## Bước 2 — Tải firmware & verify
> **Script tương ứng (máy tính):** PowerShell: `.\pc\verify-firmware.ps1 -File .\firmware.bin -ExpectedSha256 <SHA256-CÔNG-BỐ>`; Linux/macOS: `sh pc/verify-firmware.sh ./firmware.bin <SHA256-CÔNG-BỐ>`. Script chỉ verify file đã tải, không tự chọn hoặc flash firmware.

1. Vào **firmware-selector.openwrt.org** → `GL.iNet GL-MT6000` (target `mediatek/filogic`, profile `glinet,gl-mt6000`).
2. Tải bản **sysupgrade** mới nhất + ghi lại **sha256**.
3. Verify (không khớp → KHÔNG flash):
   ```powershell
   Get-FileHash .\openwrt-*-glinet_gl-mt6000-*-sysupgrade.bin -Algorithm SHA256
   .\pc\verify-firmware.ps1 -File .\firmware.bin -ExpectedSha256 <SHA256-CÔNG-BỐ>
   ```
4. Ghi lại phiên bản + ngày tải.

## Bước 3 — Backup RA MÁY TÍNH (trước khi update)
> **Script tương ứng (máy tính):** `.\pc\backup.ps1 -Label before-fw-upgrade` hoặc `sh pc/backup.sh before-fw-upgrade`. Script gọi backup trên router rồi tải snapshot về `pc/backups/`; đây là cách khuyến nghị thay cho chuỗi `ssh/scp` thủ công bên dưới.

> **Vì sao bắt buộc:** backup mặc định ở `/root/sbproxy-backups/` trên router — reflash/brick là mất theo.
```powershell
# Run on the Windows administration computer.
.\pc\backup.ps1 -Label before-fw-upgrade
```
```sh
# Run on a Linux/macOS administration computer.
sh pc/backup.sh before-fw-upgrade

# Router-only alternative: creates a snapshot but does not download it.
sh scripts/backup.sh before-fw-upgrade
```
Ngoài script: UI có **🗂 Backup / Rollback → ⭳ Về máy**; LuCI có **System → Backup/Flash Firmware → Generate archive**.

Đảm bảo backup chuẩn OpenWrt giữ được config sbproxy (đã tự đăng ký bởi install-deps/install-agent):
```sh
cat /etc/sysupgrade.conf   # phải có /etc/sing-box/, /etc/sbproxy.nft, /etc/sbproxy/, config/
```

## Bước 4 — Update / flash firmware
> **Script tương ứng:** **không có**. Chọn đúng image, vào U-Boot/GUI, upload và chờ flash là thao tác vật lý có nguy cơ brick; project cố ý không tự động hóa bước này.

**Cách A — U-Boot recovery (an toàn nhất, khi đổi họ firmware):**
1. Tắt nguồn. Máy tính đặt IP tĩnh `192.168.1.2 / 255.255.255.0`.
2. Giữ **Reset**, cấp nguồn, giữ tới khi đèn nháy nhanh rồi thả.
3. Mở `http://192.168.1.1` → U-Boot → upload image → flash → chờ reboot.

**Cách B — Local Upgrade từ GL GUI:** `http://192.168.8.1` → System → Upgrade → Local Upgrade → chọn image → **BỎ TICK "Keep settings"** khi đổi họ → Upgrade.

> **Giữ settings?** Cùng họ firmware có thể "keep settings". Đổi họ (GL→OpenWrt) thì không → khôi phục bằng backup (Bước 12) hoặc cấu hình lại (Bước 7).
> **Router treo/không lên sau flash?** Xem Bước 12 (Failsafe / U-Boot).

## Bước 5 — Truy cập router sau update
> **Script tương ứng (router, sau khi SSH được):** `sh scripts/inventory.sh > inventory-after.txt`, rồi so với file ở Bước 1. Đặt IP máy tính, mật khẩu root và xử lý SSH host key vẫn làm thủ công.

- Với GL.iNet firmware, IP quản trị MT6000 mặc định là `192.168.8.1`. OpenWrt vanilla mới flash có thể dùng `192.168.1.1`; luôn kiểm tra IP LAN thực tế trước khi chạy script.
- Đặt mật khẩu root: LuCI → System → Administration, hoặc SSH rồi `passwd`.
- SSH trong cấu hình MT6000 của tài liệu này: `ssh root@192.168.8.1`. Host key đổi → xoá dòng cũ trong `~/.ssh/known_hosts`.

> **Làm nhanh Bước 6–10 bằng console desktop** (toàn bộ đường đi 4 bước: [QUICKSTART.md](QUICKSTART.md)): mở app, bấm **Cài đặt sau khi flash…**, nhập địa chỉ router + thông tin SSH rồi bấm chạy. Chuỗi chạy qua SSH:
>
> 1. kiểm tra hiện trạng router (mã nguồn, cấu hình, phụ thuộc, agent, token) — phần nào đã có thì dùng lại;
> 2. đẩy mã nguồn + `wifi-socks.conf`, cài phụ thuộc;
> 3. chạy `preflight.sh`, dry-run rồi `apply.sh`;
> 4. cài agent, đọc `/etc/sbproxy/token`, kiểm tra `?action=status`.
>
> Gặp lỗi thì dừng ngay ở bước đó kèm thông báo của router; chạy hết thì token được lưu và màn hình điều khiển mở ra.
>
> Máy không có mã nguồn chỉ cần mang `sbproxy-console.exe` (đã nhúng gói router đúng version), thêm gói `sbproxy-update-<version>.tar.gz` khi muốn cài version khác — xem mục *Chạy tại hiện trường* trong [../console/desktop/README.vi.md](../console/desktop/README.vi.md).
>
> Các bước bên dưới là cách làm tay tương đương và vẫn là tài liệu gốc.

## Bước 6 — Đưa project lên router & cài gói
> **Script tương ứng (router):** `sh scripts/preflight.sh` để kiểm tra chỉ đọc; sau khi xử lý cảnh báo, chạy `sh scripts/install-deps.sh` để cài dependency và đăng ký dữ liệu cần giữ khi sysupgrade.

```sh
# từ máy tính
scp -r .\openwrt-multiwifi-socks5 root@192.168.8.1:/root/sbproxy
# trên router
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
sh scripts/preflight.sh        # kiểm tra phần cứng (chỉ đọc)
sh scripts/install-deps.sh     # cài gói + đăng ký sysupgrade.conf
```
**Preflight — 3 điều phải xác nhận:** (1) mapping radio ↔ băng tần — preflight tự liệt kê radio thật của board và **báo thẳng giá trị đúng** cho `RADIO_2G/5G` nếu `settings.sh` sai; (2) `iw list` "valid interface combinations" = số AP tối đa/radio → chốt số SSID ≤ số này; (3) các gói `[THIẾU]`.

## Bước 7 — Cấu hình WiFi / SOCKS
> **Script tương ứng:** cấu hình bằng `config/wifi-socks.conf` hoặc UI; chạy `DRYRUN=1 sh scripts/apply.sh` để validate toàn bộ mà chưa ghi UCI hay `/etc`. Không có script tự sinh credential vì mật khẩu và SOCKS là đầu vào của quản trị viên.

**File nguồn `config/wifi-socks.conf`** — mỗi dòng:
```
name|band|idx|wifi_key|sock_host|sock_port|sock_user|sock_pass|isolate|webrtc
```
`idx` duy nhất & ổn định (quyết định subnet `192.168.(10+idx).0/24`, cổng tproxy `12000+idx`). Có thể soạn bằng UI rồi copy/tải.

**Tunables `config/settings.sh`:**

| Biến | Ý nghĩa |
|---|---|
| `RADIO_2G / RADIO_5G` | Ánh xạ radio ↔ băng tần (phải khớp phần cứng). |
| `BSSID_LIMIT` | Số SSID tối đa mỗi băng (theo `iw list`). |
| `ZONE_INPUT` | `ACCEPT` mặc định (đã chặn cổng admin từ zone khách). |
| `WIFI_ENCRYPTION` | `psk2` (WPA2) · `sae`/`sae-mixed` (WPA3). |
| `STUN_*_PORTS` | Cổng STUN/TURN bị chặn khi WebRTC bật. |

## Bước 8 — Áp dụng
> **Script tương ứng (router):** `DRYRUN=1 sh scripts/apply.sh` để xem trước, `sh scripts/apply.sh` để áp thật và tự backup, `sh scripts/uninstall.sh` để gỡ phần cấu hình do project quản lý.

```sh
DRYRUN=1 sh scripts/apply.sh | less   # validate trong /tmp; không ghi UCI hay /etc
sh scripts/apply.sh                    # áp thật (tự backup trước)
sh scripts/uninstall.sh                # gỡ sạch phần project tạo
```
> **Xoá 1 WiFi:** `apply.sh` không tự dọn section cũ. Khi bỏ dòng khỏi conf: chạy `uninstall.sh` rồi `apply.sh` lại, hoặc xoá tay `wireless.wIDX`, `network.wIDX/brwIDX`, `dhcp.wIDX`, `firewall.zIDX`.

## Bước 9 — Cài agent điều khiển (kiến trúc B)
> **Script tương ứng (router):** `sh agent/install-agent.sh` để cài agent local; khi cần đổi token, chạy `sh scripts/rotate-token.sh` (hoặc `--yes` trong automation đã được kiểm soát).

Cho UI áp config trực tiếp + health-check latency realtime.
```sh
cd /root/sbproxy
sh agent/install-agent.sh
# → cài curl/jq, tạo /etc/sbproxy/token, đặt CGI /www/cgi-bin/sbproxy,
#   self-host UI /www/sbproxy/, chạy daemon sbproxy-healthd. In ra URL + TOKEN.
```
Mở `http://<router>/sbproxy/` → **🔌 Kết nối router** → dán token. Cấu hình daemon ở `/etc/sbproxy/env`:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `INTERVAL` | 15 | Giây giữa các lần probe. |
| `SLOW_MS` | 800 | Ngưỡng coi là "chậm". |
| `PROBE_URL` | gstatic /generate_204 | URL đo latency. |
| `PROBE_TIMEOUT` | 8 | Timeout mỗi probe (giây). |
| `GATEWAY_EXPECTED_INTERFACE` | `wwan` | Interface logic phải là đường Internet mặc định. |
| `GATEWAY_PROBE_URL` | gstatic `/generate_204` | URL kiểm tra HTTP trực tiếp qua device của default route. |
| `GATEWAY_PROBE_TIMEOUT` | 8 | Timeout kiểm tra gateway (giây). |

### 9.1 Token điều khiển là gì?
Là một **chuỗi bí mật ngẫu nhiên** (bearer token — "mật khẩu máy-với-máy"), do `install-agent.sh` sinh và lưu tại `/etc/sbproxy/token` (`chmod 600`). App native gửi `Authorization: Bearer <token>`; agent vẫn nhận `X-SB-Token` từ UI Web để tương thích.

> **Bản chất:** bí mật **dùng chung**, KHÔNG phải hệ đăng nhập. Ai cầm token là có **toàn quyền** router, không phân biệt người, không hết hạn, không ghi "ai làm gì". Chỉ cấp token trên LAN/VPN quản trị tin cậy.

### 9.2 Bảo mật token
- **Không expose agent/uhttpd ra WAN** — chỉ LAN/VLAN quản trị (quan trọng nhất).
- Chặn SSID khách chạm tới UI/agent (firewall input zone khách = reject cổng admin).
- Ưu tiên **HTTPS nội bộ** cho uhttpd nếu LAN nhiều người.
- Giữ quyền file `/etc/sbproxy/token` = `600`. Bản Web lưu token trong `localStorage`; app Windows lưu bản mã hóa DPAPI cho đúng tài khoản Windows. Vẫn phải khóa máy và không dùng token trên máy chung/lạ.
- Chỉ paste vào UI của chính router (`http://<router>/sbproxy/`), không dán web lạ.

### 9.3 Quên / lấy lại / xoay token
**Còn SSH → chỉ cần đọc lại file, token không mất:**
```sh
cat /etc/sbproxy/token          # in ra token hiện tại → copy, paste lại vào UI
TOKEN=$(cat /etc/sbproxy/token)
curl -H "Authorization: Bearer $TOKEN" http://192.168.8.1/cgi-bin/sbproxy?action=status
```
**Nghi lộ / đổi token mới (xoay):**
```sh
head -c 18 /dev/urandom | hexdump -v -e '/1 "%02x"' > /etc/sbproxy/token
echo >> /etc/sbproxy/token
chmod 600 /etc/sbproxy/token
cat /etc/sbproxy/token          # token MỚI → paste lại (token cũ lập tức vô hiệu)
# hoặc: rm /etc/sbproxy/token && sh agent/install-agent.sh
```
> **Không còn SSH và quên token?** Vào lại bằng LAN dây (SSH), hoặc Failsafe (Bước 12) để mount rootfs rồi `cat /etc/sbproxy/token`. Token luôn nằm trong file trên router — không mất trừ khi wipe cấu hình.

### 9.4 Console: bản Web vs bản Desktop
Hai frontend độc lập dùng chung Agent API:
- **Web (router-hosted):** `install-agent.sh` copy UI vào `/www/sbproxy/index.html`. Mở `http://<router>/sbproxy/` — same-origin. Nếu mở qua **https** thì trình duyệt chặn mixed-content khi gọi router http.
- **Desktop (.exe / Linux):** app Tkinter native, không dùng HTML/WebView/WebView2, gọi thẳng Agent API; dry-run candidate trước Apply, hiện loading/timeout, cảnh báo trước tác vụ quan trọng và có bộ lọc thiết bị nâng cao.
  - Hai bản build tách theo nền tảng (PyInstaller không cross-compile): Windows `cd console/desktop; .\build.ps1` → `dist/sbproxy-console.exe`, chạy `.\sbproxy-console.exe`; Linux/macOS `sh console/desktop/build.sh` → `dist/sbproxy-console`, chạy `./sbproxy-console`. Mỗi file tự chứa đủ mọi thứ, copy sang máy quản trị là chạy được.
  - Token lưu bằng DPAPI trên Windows, `chmod 600` trên Linux/macOS. Config/log/cache/runtime nằm dưới **một home riêng** (`SBPROXY_HOME` → thư mục `data/` cạnh file exe cho bản portable → `%LOCALAPPDATA%\sbproxy-console-native`); xem bằng `sbproxy-console --where`.
  - Cả hai script build nhúng sẵn gói `sbproxy-update-<version>.tar.gz` nên chạy được **Cài đặt sau khi flash** trên máy không có mã nguồn.
  - Console đối chiếu version với agent: agent cũ hơn thì hỏi và nâng cấp tại chỗ (giữ nguyên `wifi-socks.conf` + `settings.sh`), agent mới hơn thì console chuyển sang chỉ đọc cho tới khi được cập nhật.
  - Debug hiện trường: lấy `logs/console.log` qua nút **Thư mục log**, hoặc chạy lại với `--verbose`.
  - `logs/audit.log` ghi riêng: mỗi lần kết nối (router, version agent, sing-box) và mọi thay đổi đẩy xuống router (apply, đổi SOCKS, random MAC, kick/cấm/bỏ cấm, backup, rollback, cập nhật agent) kèm user hệ điều hành và kết quả.
  - Cả hai file xoay vòng **mỗi nửa đêm**, **giữ 7 ngày**, token/mật khẩu đã bị che; file cũ hơn bị xoá ở lần chạy kế tiếp.
  - Chi tiết: [../console/desktop/README.vi.md](../console/desktop/README.vi.md).

> **Mixed-content:** chế độ Live của **bản Web** chỉ chạy khi mở UI qua **http** từ chính router; bản Desktop không vướng giới hạn này.
> Project chỉ hỗ trợ local. Nếu cần truy cập từ ngoài, vào LAN qua VPN do bạn tự quản lý; không mở agent/uhttpd trực tiếp ra WAN.

## Bước 10 — Kiểm tra / nghiệm thu
> **Script tương ứng (router, chỉ đọc):** `sh scripts/verify.sh` (nghiệm thu, exit `0`=đạt) và `sh scripts/doctor.sh` (báo cáo trạng thái tổng thể theo từng khu vực). Khác `0` thì chạy `sh scripts/diagnose.sh` để lấy log. Các bài kiểm tra IP/DNS/WebRTC vẫn phải chạy trên client nối từng SSID.

```sh
# trên router
sh scripts/verify.sh                                  # nghiệm thu tự động (pass/fail)
sh scripts/doctor.sh                                  # báo cáo tổng thể: gói, sing-box, fake-IP DNS, tproxy, wifi, agent
wifi status ; iw dev | grep -E 'Interface|ssid|addr'   # SSID + MAC (random hoặc theo hãng)
nslookup ipinfo.io 192.168.11.1                        # từ client: phải trả IP 198.18.x.x (fake-IP)
nft list table inet sbproxy ; ip rule | grep 0x1       # tproxy + policy routing
logread -e sing-box | tail -20
```

| Trên client (từng WiFi) | Đạt khi |
|---|---|
| `https://ipinfo.io/ip` | IP = SOCKS gán cho WiFi đó; 2 WiFi khác sock → 2 IP khác |
| `dnsleaktest.com` | DNS không phải ISP thật (xem phần hạn chế, Bước 15) |
| `browserleaks.com/webrtc` | Không lộ IP thật |
| 2 máy cùng WiFi ping nhau | Không ping được (isolate) |

## Bước 11 — Vận hành hằng ngày
> **Script tương ứng (router):** `sh scripts/set-sock.sh <idx> <host> <port> [user] [pass]` để đổi một SOCKS; `sh scripts/backup.sh <nhãn>` để tạo snapshot. Từ máy quản trị dùng `pc/update.*` và `pc/backup.*` để cập nhật hoặc kéo backup về máy.

```sh
sh scripts/set-sock.sh <idx> <host> <port> [user] [pass]   # đổi sock 1 WiFi, KHÔNG rớt WiFi
sh scripts/backup.sh <nhãn>                                # backup thủ công
sh scripts/rollback.sh --list                               # xem danh sách backup
```
- **Thêm/sửa WiFi:** sửa `wifi-socks.conf` (hoặc UI) → `apply.sh`.
- **Định kỳ tải backup ra máy** (nhất là trước update firmware — Bước 3).
- Trên UI: cột **Sức khỏe** latency realtime + **🗂 Backup / Rollback** + nút **⚡** đổi sock nhanh.

## Bước 12 — Rollback & cứu router treo/brick
> **Script tương ứng:** trên router dùng `sh scripts/rollback.sh --list` và `sh scripts/rollback.sh <tên>`; từ PC dùng `pc/restore.ps1` hoặc `pc/restore.sh`. Failsafe và U-Boot là thao tác cứu hộ thủ công, không có script.


| Mức | Lệnh / thao tác | Khi nào |
|---|---|---|
| 1 | `sh scripts/rollback.sh --list` · `rollback.sh [tên]` | Quay lui cấu hình. |
| 2 | `sh scripts/uninstall.sh` | Gỡ sạch phần project. |
| 3 | `sysupgrade -r <backup>.tar.gz && reboot` | UCI hỏng nặng. |
| 4 | LAN dây → Failsafe → U-Boot | Mất kết nối / brick. |
| 5 | Debug sing-box/tproxy (Bước 13·D) | Chỉ proxy lỗi. |

**Router treo / brick sau update — cứu bằng U-Boot (GL-MT6000):**
1. **Mềm:** LAN dây → SSH → `sh scripts/rollback.sh`.
2. **Failsafe (OpenWrt):** reboot, bấm Reset khi đèn nháy → máy IP `192.168.1.2` → SSH `root@192.168.1.1` (không mật khẩu) → `mount_root` rồi rollback, hoặc `firstboot && reboot`.
3. **U-Boot web (cứu brick):** tắt nguồn → máy IP `192.168.1.2` → giữ Reset khi cấp nguồn tới khi đèn nháy nhanh → `http://192.168.1.1` → upload image sạch → flash.

**Khôi phục backup đã tải về máy:**
```sh
scp .\sbproxy-<tên>.tar.gz root@192.168.8.1:/tmp/
ssh root@192.168.8.1 "sysupgrade -r /tmp/sbproxy-<tên>.tar.gz && reboot"
# hoặc LuCI: System → Backup/Flash → Restore → upload .tar.gz
```

## Bước 13 — Xử lý lỗi (theo triệu chứng)
> **Script tương ứng (router, chỉ đọc):** `sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1`. Chạy trước khi restart để giữ bằng chứng về WiFi, sing-box, nftables, policy route và log.

**D · Có WiFi + IP nhưng không ra internet (hay gặp nhất):**
```sh
pgrep -f sing-box || /etc/init.d/sing-box restart
sing-box check -c /etc/sing-box/config.json
curl -x socks5h://user:pass@HOST:PORT https://ipinfo.io/ip   # SOCKS sống?
nft list table inet sbproxy ; ip rule | grep 0x1 ; ip route show table 100
/etc/init.d/sbproxy restart
```

| Nhóm | Nguyên nhân → xử lý |
|---|---|
| Firmware/flash | Brick → U-Boot (Bước 12). sha256 lệch → tải lại. Mất SSID sau nâng cấp → `apply.sh`. |
| WiFi thiếu SSID | Vượt BSSID → giảm/chia băng. Không SSID nào lên → sai `RADIO_*` hoặc radio `disabled`. |
| Client không có IP | `/etc/init.d/dnsmasq restart`; đảm bảo `ZONE_INPUT=ACCEPT`. |
| Ra net nhưng sai IP | `iifname` không khớp `br-w<idx>`; kiểm tra route sing-box `in-w→out-w`. |
| DNS leak | DNS SSID proxy được hijack vào sing-box fake-IP. `nslookup` phải trả `198.18.x.x`; nếu không, kiểm tra rule `dport 53` trong `nft list chain inet sbproxy prerouting` rồi chạy lại `apply.sh`. |
| WebRTC lộ | Bật `webrtc=1` → `apply`; kiểm tra `nft list chain inet sbproxy webrtc`. |
| Client thấy nhau | `isolate=1`; zone `forward=REJECT`; mỗi SSID một `br-w<idx>`. |
| Agent không kết nối | `curl -H "Authorization: Bearer $(cat /etc/sbproxy/token)" http://IP/cgi-bin/sbproxy?action=status`; kiểm tra `+x` của CGI; với bản Web kiểm tra thêm mixed-content. |

## Bước 14 — Tham chiếu API (agent LAN)
> **Script tương ứng:** `agent/cgi/sbproxy` là CGI hiện thực API; quản trị viên không chạy file này trực tiếp. Ví dụ kiểm tra endpoint: `TOKEN=$(cat /etc/sbproxy/token); curl -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1/cgi-bin/sbproxy?action=status'`.

Endpoint `/cgi-bin/sbproxy?action=…`, ưu tiên header `Authorization: Bearer <token>`; `X-SB-Token` vẫn được nhận để tương thích.

| Method | action | Body | Trả về |
|---|---|---|---|
| GET | `status` | — | ssids[] (gồm `mac_oui`), health{probes{idx:{state,latency_ms,code}}}, meta |
| GET | `get_conf` | — | text conf |
| POST | `save_conf` | text | {ok,saved} |
| POST | `dryrun_conf` | text | Dry-run candidate tạm, không ghi cấu hình thật |
| POST | `apply` | — | Bắt buộc dry-run lần cuối; chỉ đạt mới apply |
| POST | `set_sock` | {idx,host,port,user,pass} | {ok,rc,log} |
| POST | `rotate_mac` | {idx,oui?} | Random BSSID/MAC theo provider, lưu config và reload radio |
| POST | `backup` | {label?} | {ok,rc,log} |
| GET | `backups` | — | {ok,backups[]} |
| GET | `download_backup` | ?name= | file .tar.gz |
| POST | `rollback` | {name?} | {ok,rc,log} |
| POST | `uninstall` | — | {ok,rc,log} |
| GET | `health_now` | — | probe ngay 1 lần |
| GET | `gateway` | — | Route/interface/device, link, DNS, HTTP code + latency; đối chiếu `wwan` |
| GET | `clients` | — | Client online + blocklist offline, gồm band/online/RSSI/traffic |
| POST | `kick` | {idx,mac} | {ok,rc,log} — deauth tạm |
| POST | `ban` | {idx,mac} | {ok,rc,log} — chặn MAC lâu dài |
| POST | `unban` | {idx,mac} | {ok,rc,log} |
| POST | `update[&force=1]` | binary `.tar.gz`/`.zip` | {ok,rc,log,from,to} — self-update code sbproxy |

**Cập nhật agent qua giao diện (self-update):** tạo package trên máy quản trị bằng `make package` (hoặc `sh pc/make-package.sh` / `pc\make-package.ps1`) → `dist/sbproxy-update-<version>.tar.gz`, rồi trên web console bấm **⬆ Cập nhật** và chọn file. Router chạy `scripts/self-update.sh`: chặn path traversal trong package, từ chối hạ version (tick "force" nếu cố ý), tự backup `pre-update`, **giữ nguyên** `config/wifi-socks.conf` + `config/settings.sh` đang dùng, deploy lại CGI/UI/healthd và reload uhttpd. Cập nhật KHÔNG reload WiFi — cấu hình chỉ đổi khi bấm "Đẩy & Áp" sau đó. Version đang chạy hiển thị ở header console (`meta.version` của `?action=status`); giới hạn upload mặc định 8 MB (`MAX_UPDATE_BYTES` trong `/etc/sbproxy/env`).

**Quản lý thiết bị:** app native lọc theo SSID, band, online/offline, blocklist, RSSI, traffic và thời gian; hỗ trợ chọn nhiều, sort, auto-refresh, chi tiết và CSV. **Kick** deauth tạm (thiết bị có thể nối lại). **Cấm** ghi MAC vào `/etc/sbproxy.bans` + đặt `macfilter=deny` cho SSID đó rồi reload băng tần tương ứng; ban được `apply.sh` áp lại mỗi lần chạy nên không mất khi cấu hình lại. Blocklist offline vẫn hiện để bỏ cấm. Router-side: `sh scripts/clients.sh`, `sh scripts/{kick,ban,unban}.sh <idx> <mac>`.

## Bước 15 — Bảo mật & chống lộ (checklist)
> **Script tương ứng (router, chỉ đọc):** `sh scripts/security-audit.sh`. Exit code khác `0` nghĩa là có cảnh báo cần xem; script không tự sửa SSH/firewall để tránh khóa mất quyền quản trị.

Ba nhóm "lộ" cần chặn: **(A) lộ danh tính/IP thật**, **(B) lộ quyền điều khiển**, **(C) lộ dữ liệu nhạy cảm**.

### A · Chống lộ danh tính / IP thật
| Kênh lộ | Trạng thái | Cách bịt |
|---|---|---|
| **IPv6 bypass** | ✅ Đã chặn | tproxy hiện chỉ bắt IPv4; `apply.sh` tắt DHCPv6/RA/NDP trên từng SSID sbproxy. Chưa hỗ trợ proxy IPv6. |
| **DNS leak** | ✅ Chặn (fake-IP) | DNS cổng 53 của SSID proxy hijack vào sing-box; client nhận fake-IP `198.18.0.0/15`, SOCKS nhận **hostname** (remote resolve). Client dùng DoH/DoT né được hijack → fallback sniff SNI; muốn chặt hơn, chặn cổng 853/resolver DoH trên zone khách. |
| **WebRTC leak** | ✅ Có (nếu bật) | Đặt `webrtc=1` cho SSID cần ẩn danh (Bước 7). |
| **Rò khi proxy chết** | ✅ Fail-closed | Zone khách `forward=REJECT` → sing-box/tproxy chết thì client **mất mạng** chứ không ra thẳng. Đừng thêm rule forward guest→wan. |
| **MAC thật** | ✅ Random / giả hãng | Mặc định MAC `02:xx` (locally-administered) tự sinh mỗi SSID. Có thể chọn giả 3 byte đầu theo hãng WiFi phổ biến (cột 11 `mac_oui` trong `wifi-socks.conf`, hoặc dropdown "Hãng WiFi" trong Console) — 3 byte sau vẫn random. Đổi hãng rồi `apply.sh` sẽ sinh lại MAC. |

Kiểm tra lại: `ipinfo.io/ip`, `dnsleaktest.com`, `browserleaks.com/webrtc`, **`test-ipv6.com`** (không lộ IPv6 thật).

### B · Chống lộ quyền điều khiển
- **Không đưa quản trị ra WAN:** uhttpd/agent/LuCI/SSH chỉ nghe LAN/VLAN quản trị (quan trọng nhất).
- **Router:** mật khẩu root mạnh; ưu tiên SSH key + tắt password auth (`uci set dropbear.@dropbear[0].PasswordAuth='off'`).
- **Token agent** (9.1–9.3): bí mật dùng chung = toàn quyền → LAN only, file `600`, xoay khi nghi lộ.
- **Cách ly zone:** SSID khách `input=REJECT`/không forward chéo → không chạm LuCI/SSH/agent, không thấy nhau.

### C · Chống lộ dữ liệu nhạy cảm
| Dữ liệu | Ở đâu | Bảo vệ |
|---|---|---|
| User/pass SOCKS, mật khẩu WiFi | `wifi-socks.conf`, `config.json`, backups | Chỉ root đọc; **KHÔNG commit lên git/nơi công khai**; backup để nơi an toàn (mã hoá ổ đĩa). |
| Token agent | `/etc/sbproxy/token` | `chmod 600`; không log; không dán web lạ. |
| Nhật ký | `logread` | Không in token/mật khẩu ra log; chỉ root/admin được xem. |

### D · Kênh truyền & vận hành
- SOCKS5 dùng `socks5h` (DNS resolve phía proxy) — đã dùng trong health-check & sing-box.
- Nếu SOCKS không mã hoá đường tới nó, cân nhắc bọc thêm (chain qua TLS/WireGuard).
- **Cập nhật** firmware + `sing-box` để vá lỗi (Bước 3 an toàn: backup ra máy trước).
- **Xoay** token agent và mật khẩu định kỳ; rà `logread` khi có sự cố.

> **Ưu tiên nếu chỉ làm được vài việc:** 1) IPv6 tắt trên SSID khách · 2) DNS ép ẩn danh · 3) Quản trị/agent không ra WAN · 4) Xoay token khi nghi lộ · 5) Không commit file chứa mật khẩu.
