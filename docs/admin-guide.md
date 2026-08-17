# sbproxy — Hướng dẫn Quản trị (theo bước)

**Ngôn ngữ:** Tiếng Việt | [English](admin-guide.en.md)

Làm tuần tự từ trên xuống: tải firmware → backup → update → cài đặt → cấu hình → cài agent LAN → kiểm tra → vận hành → bảo mật.

> Bản HTML đọc offline: [admin-guide.html](admin-guide.html). Bổ trợ: [GUIDE.md](GUIDE.md), [INSTALL.md](INSTALL.md), [TESTING.md](TESTING.md), [ROLLBACK.md](ROLLBACK.md).

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

---

## Bước 1 — Chuẩn bị
- Router **GL-MT6000 (Flint 2)**. Xác định IP quản trị (GL stock: `192.168.8.1`).
- Cáp **LAN** nối máy tính ↔ router (đường cứu hộ). SSH client + trình duyệt.
- Không thử nghiệm lần đầu trên router đang phục vụ việc quan trọng.
- **Firmware nên dùng:** OpenWrt vanilla mới nhất (hoặc ImmortalWrt nếu cần GUI proxy). Tránh firmware lạ chưa xác thực nguồn.

## Bước 2 — Tải firmware & verify
1. Vào **firmware-selector.openwrt.org** → `GL.iNet GL-MT6000` (target `mediatek/filogic`, profile `glinet,gl-mt6000`).
2. Tải bản **sysupgrade** mới nhất + ghi lại **sha256**.
3. Verify (không khớp → KHÔNG flash):
   ```powershell
   Get-FileHash .\openwrt-*-glinet_gl-mt6000-*-sysupgrade.bin -Algorithm SHA256
   ```
4. Ghi lại phiên bản + ngày tải.

## Bước 3 — Backup RA MÁY TÍNH (trước khi update)
> **Vì sao bắt buộc:** backup mặc định ở `/root/sbproxy-backups/` trên router — reflash/brick là mất theo.
```sh
# Cách 1 — UI: 🗂 Backup / Rollback → ⭳ Về máy
# Cách 2 — LuCI: System → Backup/Flash Firmware → Generate archive
# Cách 3 — từ máy tính (PowerShell):
scp -r root@192.168.1.1:/root/sbproxy-backups .\sbproxy-backups
sh scripts/backup.sh before-fw-upgrade    # (nếu đã cài project) tạo mốc
```
Đảm bảo backup chuẩn OpenWrt giữ được config sbproxy (đã tự đăng ký bởi install-deps/install-agent):
```sh
cat /etc/sysupgrade.conf   # phải có /etc/sing-box/, /etc/sbproxy.nft, /etc/sbproxy/, config/
```

## Bước 4 — Update / flash firmware
**Cách A — U-Boot recovery (an toàn nhất, khi đổi họ firmware):**
1. Tắt nguồn. Máy tính đặt IP tĩnh `192.168.1.2 / 255.255.255.0`.
2. Giữ **Reset**, cấp nguồn, giữ tới khi đèn nháy nhanh rồi thả.
3. Mở `http://192.168.1.1` → U-Boot → upload image → flash → chờ reboot.

**Cách B — Local Upgrade từ GL GUI:** `http://192.168.8.1` → System → Upgrade → Local Upgrade → chọn image → **BỎ TICK "Keep settings"** khi đổi họ → Upgrade.

> **Giữ settings?** Cùng họ firmware có thể "keep settings". Đổi họ (GL→OpenWrt) thì không → khôi phục bằng backup (Bước 12) hoặc cấu hình lại (Bước 7).
> **Router treo/không lên sau flash?** Xem Bước 12 (Failsafe / U-Boot).

## Bước 5 — Truy cập router sau update
- IP đổi về mặc định OpenWrt `192.168.1.1`. Đưa máy tính về DHCP / cùng dải.
- Đặt mật khẩu root: LuCI → System → Administration, hoặc SSH rồi `passwd`.
- SSH: `ssh root@192.168.1.1`. Host key đổi → xoá dòng cũ trong `~/.ssh/known_hosts`.

## Bước 6 — Đưa project lên router & cài gói
```sh
# từ máy tính
scp -r .\openwrt-multiwifi-socks5 root@192.168.1.1:/root/sbproxy
# trên router
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
sh scripts/preflight.sh        # kiểm tra phần cứng (chỉ đọc)
sh scripts/install-deps.sh     # cài gói + đăng ký sysupgrade.conf
```
**Preflight — 3 điều phải xác nhận:** (1) mapping `radio0/1` ↔ băng tần → sửa `RADIO_2G/5G` trong `settings.sh`; (2) `iw list` "valid interface combinations" = số AP tối đa/radio → chốt số SSID ≤ số này; (3) các gói `[THIẾU]`.

## Bước 7 — Cấu hình WiFi / SOCKS
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
```sh
DRYRUN=1 sh scripts/apply.sh | less   # validate trong /tmp; không ghi UCI hay /etc
sh scripts/apply.sh                    # áp thật (tự backup trước)
sh scripts/uninstall.sh                # gỡ sạch phần project tạo
```
> **Xoá 1 WiFi:** `apply.sh` không tự dọn section cũ. Khi bỏ dòng khỏi conf: chạy `uninstall.sh` rồi `apply.sh` lại, hoặc xoá tay `wireless.wIDX`, `network.wIDX/brwIDX`, `dhcp.wIDX`, `firewall.zIDX`.

## Bước 9 — Cài agent điều khiển (kiến trúc B)
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

### 9.1 Token điều khiển là gì?
Là một **chuỗi bí mật ngẫu nhiên** (bearer token — "mật khẩu máy-với-máy"), do `install-agent.sh` sinh và lưu tại `/etc/sbproxy/token` (`chmod 600`). UI gắn token vào header `X-SB-Token` mỗi request; agent so khớp mới cho thực thi.

> **Bản chất:** bí mật **dùng chung**, KHÔNG phải hệ đăng nhập. Ai cầm token là có **toàn quyền** router, không phân biệt người, không hết hạn, không ghi "ai làm gì". Chỉ cấp token trên LAN/VPN quản trị tin cậy.

### 9.2 Bảo mật token
- **Không expose agent/uhttpd ra WAN** — chỉ LAN/VLAN quản trị (quan trọng nhất).
- Chặn SSID khách chạm tới UI/agent (firewall input zone khách = reject cổng admin).
- Ưu tiên **HTTPS nội bộ** cho uhttpd nếu LAN nhiều người.
- Giữ quyền file `/etc/sbproxy/token` = `600`. Trình duyệt lưu token trong `localStorage` → khoá máy, đừng paste trên máy chung/lạ.
- Chỉ paste vào UI của chính router (`http://<router>/sbproxy/`), không dán web lạ.

### 9.3 Quên / lấy lại / xoay token
**Còn SSH → chỉ cần đọc lại file, token không mất:**
```sh
cat /etc/sbproxy/token          # in ra token hiện tại → copy, paste lại vào UI
TOKEN=$(cat /etc/sbproxy/token)
curl -H "X-SB-Token: $TOKEN" http://192.168.1.1/cgi-bin/sbproxy?action=status
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

> **Mixed-content:** chế độ Live chỉ chạy khi mở UI qua **http** từ chính router.
> Project chỉ hỗ trợ local. Nếu cần truy cập từ ngoài, vào LAN qua VPN do bạn tự quản lý; không mở agent/uhttpd trực tiếp ra WAN.

## Bước 10 — Kiểm tra / nghiệm thu
```sh
# trên router
wifi status ; iw dev | grep -E 'Interface|ssid|addr'   # SSID + MAC random
sing-box check -c /etc/sing-box/config.json            # config hợp lệ
nft list table inet sbproxy ; ip rule | grep 0x1       # tproxy + policy routing
logread -e sing-box | tail -20
```

| Trên client (từng WiFi) | Đạt khi |
|---|---|
| `https://ipinfo.io/ip` | IP = SOCKS gán cho WiFi đó; 2 WiFi khác sock → 2 IP khác |
| `dnsleaktest.com` | DNS không phải ISP thật (xem hạn chế v0.1, Bước 15) |
| `browserleaks.com/webrtc` | Không lộ IP thật |
| 2 máy cùng WiFi ping nhau | Không ping được (isolate) |

## Bước 11 — Vận hành hằng ngày
```sh
sh scripts/set-sock.sh <idx> <host> <port> [user] [pass]   # đổi sock 1 WiFi, KHÔNG rớt WiFi
sh scripts/backup.sh <nhãn>                                # backup thủ công
sh scripts/rollback.sh --list                               # xem danh sách backup
```
- **Thêm/sửa WiFi:** sửa `wifi-socks.conf` (hoặc UI) → `apply.sh`.
- **Định kỳ tải backup ra máy** (nhất là trước update firmware — Bước 3).
- Trên UI: cột **Sức khỏe** latency realtime + **🗂 Backup / Rollback** + nút **⚡** đổi sock nhanh.

## Bước 12 — Rollback & cứu router treo/brick

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
scp .\sbproxy-<tên>.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sysupgrade -r /tmp/sbproxy-<tên>.tar.gz && reboot"
# hoặc LuCI: System → Backup/Flash → Restore → upload .tar.gz
```

## Bước 13 — Xử lý lỗi (theo triệu chứng)
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
| DNS leak | v0.1 DNS qua dnsmasq → trỏ upstream DoH/ẩn danh, hoặc bật khối `dns` trong sing-box. |
| WebRTC lộ | Bật `webrtc=1` → `apply`; kiểm tra `nft list chain inet sbproxy webrtc`. |
| Client thấy nhau | `isolate=1`; zone `forward=REJECT`; mỗi SSID một `br-w<idx>`. |
| Agent không kết nối | `curl -H "X-SB-Token: $(cat /etc/sbproxy/token)" http://IP/cgi-bin/sbproxy?action=status`; kiểm tra `+x` của CGI; mixed-content. |

## Bước 14 — Tham chiếu API (agent LAN)
Endpoint `/cgi-bin/sbproxy?action=…`, header `X-SB-Token`.

| Method | action | Body | Trả về |
|---|---|---|---|
| GET | `status` | — | ssids[], health{probes{idx:{state,latency_ms,code}}}, meta |
| GET | `get_conf` | — | text conf |
| POST | `save_conf` | text | {ok,saved} |
| POST | `apply` | — | {ok,rc,log} |
| POST | `set_sock` | {idx,host,port,user,pass} | {ok,rc,log} |
| POST | `backup` | {label?} | {ok,rc,log} |
| GET | `backups` | — | {ok,backups[]} |
| GET | `download_backup` | ?name= | file .tar.gz |
| POST | `rollback` | {name?} | {ok,rc,log} |
| POST | `uninstall` | — | {ok,rc,log} |
| GET | `health_now` | — | probe ngay 1 lần |

## Bước 15 — Bảo mật & chống lộ (checklist)
Ba nhóm "lộ" cần chặn: **(A) lộ danh tính/IP thật**, **(B) lộ quyền điều khiển**, **(C) lộ dữ liệu nhạy cảm**.

### A · Chống lộ danh tính / IP thật
| Kênh lộ | Trạng thái | Cách bịt |
|---|---|---|
| **IPv6 bypass** | ✅ Chặn ở v0.2 | tproxy hiện chỉ bắt IPv4; `apply.sh` tắt DHCPv6/RA/NDP trên từng SSID sbproxy. Chưa hỗ trợ proxy IPv6. |
| **DNS leak** | ⚠️ v0.1 có thể lộ | `uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'; uci set dhcp.@dnsmasq[0].noresolv='1'` (tốt hơn: DoH qua `https-dns-proxy`, hoặc DNS trong sing-box đi qua proxy). |
| **WebRTC leak** | ✅ Có (nếu bật) | Đặt `webrtc=1` cho SSID cần ẩn danh (Bước 7). |
| **Rò khi proxy chết** | ✅ Fail-closed | Zone khách `forward=REJECT` → sing-box/tproxy chết thì client **mất mạng** chứ không ra thẳng. Đừng thêm rule forward guest→wan. |
| **MAC thật** | ✅ Random | MAC `02:xx` tự sinh mỗi SSID. |

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
