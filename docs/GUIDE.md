# HƯỚNG DẪN SỬ DỤNG TOÀN TẬP — sbproxy (GL-MT6000)

**Ngôn ngữ:** Tiếng Việt | [English](GUIDE.en.md)

Cẩm nang xuyên suốt: **firmware → cài đặt → cấu hình (UI hoặc file) → áp dụng → kiểm tra → vận hành → xử lý lỗi → rollback**.
Đọc lướt mục lục, làm theo đúng thứ tự ở lần đầu.

- Chi tiết bổ trợ: [INSTALL.md](INSTALL.md) · [TESTING.md](TESTING.md) · [ROLLBACK.md](ROLLBACK.md)
- Plan tổng thể: [`../../plan-mt6000-socks5-multi-wifi.md`](../../plan-mt6000-socks5-multi-wifi.md)

## Mục lục
0. [Nguyên tắc an toàn](#0-nguyên-tắc-an-toàn-đọc-trước)
1. [Bước 1 — Firmware](#bước-1--firmware-đồng-bộ--flash)
2. [Bước 2 — Truy cập router](#bước-2--truy-cập-router-ssh--luci)
3. [Bước 3 — Đưa project lên router](#bước-3--đưa-project-lên-router)
4. [Bước 4 — Preflight](#bước-4--preflight-kiểm-tra-trước)
5. [Bước 5 — Cài gói](#bước-5--cài-gói-phụ-thuộc)
6. [Bước 6 — Cấu hình WiFi/SOCKS](#bước-6--cấu-hình-wifisocks)
7. [Bước 7 — Áp dụng](#bước-7--áp-dụng)
8. [Bước 8 — Kiểm tra](#bước-8--kiểm-tra-nghiệm-thu)
9. [Vận hành hằng ngày](#vận-hành-hằng-ngày)
10. [XỬ LÝ LỖI](#xử-lý-lỗi-theo-triệu-chứng)
11. [FAQ](#faq)

---

## 0. Nguyên tắc an toàn (đọc trước)
- **Luôn có đường LAN dây dự phòng.** Cắm cáp từ máy tính vào cổng LAN router. Nếu WiFi/định tuyến hỏng, bạn vẫn SSH vào cứu được.
- **Đừng thử nghiệm lần đầu trên router đang phục vụ việc quan trọng.**
- **Backup trước mọi thay đổi** — các script đã tự backup, nhưng nên tự tạo 1 mốc: `sh scripts/backup.sh baseline`.
- Làm **từng bước**, test **1–2 WiFi trước**, ổn rồi mới nhân lên 20–30.

---

## Bước 1 — Firmware (đồng bộ / flash)

### 1.1 Xác định firmware đang chạy
- Vào trang quản trị router. Mặc định GL.iNet: `http://192.168.8.1`.
- Xem model & phiên bản. Bạn cần **GL-MT6000 (Flint 2)**.

### 1.2 Chọn hướng firmware
| Hướng | Khi nào chọn |
|---|---|
| **OpenWrt vanilla** (khuyến nghị) | Muốn toàn quyền multi-SSID + routing per-SOCKS (project này) |
| **ImmortalWrt** | Muốn thêm GUI proxy (PassWall2) nhưng vẫn nền OpenWrt |
| Giữ **GL.iNet stock** | Không khuyến nghị cho bài toán này (giới hạn số SSID trên GUI) |

> Chi tiết so sánh: mục 2 & 13 của plan. Bên dưới hướng dẫn cho **OpenWrt vanilla**.

### 1.3 Tải image đúng & verify
1. Vào **firmware-selector.openwrt.org**, tìm `GL.iNet GL-MT6000` (target `mediatek/filogic`, profile `glinet,gl-mt6000`).
2. Tải bản **release ổn định mới nhất** (vd 23.05.x / 24.10.x — ưu tiên bản mới hơn nếu có).
3. Lấy 2 file: **sysupgrade** (nâng cấp) — dùng khi đang ở OpenWrt/GL; và ghi lại **sha256** trên trang.
4. **Verify** trước khi flash:
   ```powershell
   Get-FileHash .\openwrt-*-glinet_gl-mt6000-squashfs-sysupgrade.bin -Algorithm SHA256
   ```
   So khớp với sha256 trên trang tải. **Không khớp → không flash.**
5. Ghi lại: ngày tải + phiên bản (để sau này biết đang chạy gì).

### 1.4 Flash (2 cách)
**Cách A — U-Boot web recovery (an toàn nhất, khuyên dùng khi chuyển từ GL stock):**
1. Tắt nguồn router. Đặt IP tĩnh máy tính: `192.168.1.2 / 255.255.255.0`.
2. Giữ nút **Reset**, cấp nguồn, giữ đến khi đèn nhấp nháy nhanh rồi thả.
3. Mở `http://192.168.1.1` → giao diện U-Boot → upload file firmware → flash → chờ reboot.

**Cách B — Local Upgrade từ giao diện GL.iNet:**
1. `http://192.168.8.1` → **System → Upgrade → Local Upgrade**.
2. Chọn file OpenWrt sysupgrade.
3. **BỎ TICK "Keep settings"** (đổi họ firmware → không giữ được cấu hình cũ).
4. Upgrade → chờ reboot.

### 1.5 Sau khi flash
- IP quản trị mặc định của GL-MT6000 với GL.iNet firmware là **`192.168.8.1`**. OpenWrt vanilla mới flash có thể dùng `192.168.1.1`; kiểm tra IP LAN thực tế trước khi tiếp tục.
- Đặt mật khẩu root: vào trang quản trị `http://192.168.8.1` (hoặc IP LAN thực tế) → System → Administration, hoặc SSH rồi `passwd`.
- Bật SSH (thường đã bật với dropbear/OpenSSH mặc định).

> **Đồng bộ/cập nhật firmware về sau:** lặp lại 1.3–1.4 với image mới. Trước khi nâng cấp firmware, chạy `sh scripts/backup.sh before-fw-upgrade`. Sau nâng cấp, cấu hình `/etc/config` có thể được giữ (sysupgrade keep settings) — nếu KHÔNG giữ, chạy lại `apply.sh`.

---

## Bước 2 — Truy cập router (SSH & LuCI)
```powershell
ssh root@192.168.8.1          # đổi IP nếu bạn đã đặt khác
```
- LuCI (web): `http://192.168.8.1` (hoặc IP LAN thực tế).
- Nếu lần đầu báo host key đổi: xóa dòng cũ trong `~/.ssh/known_hosts` rồi thử lại.

---

## Bước 3 — Đưa project lên router
Từ máy tính (PowerShell), tại thư mục chứa `openwrt-multiwifi-socks5`:
```powershell
scp -r .\openwrt-multiwifi-socks5 root@192.168.8.1:/root/sbproxy
```
SSH vào và chuẩn bị config:
```sh
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
```

---

## Bước 4 — Preflight (kiểm tra trước)
```sh
sh scripts/preflight.sh
```
Đọc kỹ 3 điều:
1. **Radio ↔ băng tần**: nếu `radio0` không phải 2.4G, sửa `RADIO_2G/RADIO_5G` trong `config/settings.sh`.
2. **valid interface combinations** (từ `iw list`): đây là **số AP tối đa/radio** thật của máy → chốt số SSID ≤ số này.
3. Gói **[THIẾU]** → cài ở bước 5.

---

## Bước 5 — Cài gói phụ thuộc
```sh
sh scripts/install-deps.sh
```
Cài `nftables kmod-nft-tproxy kmod-nft-core ip-full iw-full sing-box`, cài `/etc/init.d/sbproxy` + bật autostart.

> Nếu opkg **không có** `sing-box`: tải binary aarch64 (MT7986) từ release chính thức, đặt `/usr/bin/sing-box`, tạo init procd. (Xem INSTALL.md mục 4.)

---

## Bước 6 — Cấu hình WiFi/SOCKS
Có 2 cách, chọn 1:

### Cách 1 — Dùng UI "sbproxy Console" (dễ nhất)
1. Mở UI (artifact web hoặc `ui/control-panel.html`).
2. **＋ Thêm WiFi**: nhập tên, băng tần, mật khẩu, SOCKS host/port/user/pass, bật/tắt cách ly & chặn WebRTC. idx tự gợi ý.
3. Theo dõi đồng hồ **BSSID mỗi băng** — đừng để vượt giới hạn (đỏ).
4. Tab **wifi-socks.conf** → **⧉ Copy** (hoặc **Tải wifi-socks.conf**).
5. Dán nội dung vào `config/wifi-socks.conf` trên router:
   ```sh
   vi /root/sbproxy/config/wifi-socks.conf   # dán, lưu
   ```

### Cách 2 — Sửa file trực tiếp
```sh
vi config/wifi-socks.conf
```
Mỗi dòng: `name|band|idx|wifi_key|sock_host|sock_port|sock_user|sock_pass|isolate|webrtc`
- `idx` duy nhất, ổn định; subnet = `192.168.(10+idx).0/24`.
- Không để khoảng trắng quanh `|`. Mật khẩu WiFi ≥ 8 ký tự.

---

## Bước 7 — Áp dụng
```sh
DRYRUN=1 sh scripts/apply.sh | less   # validate trong /tmp; không ghi UCI hay file /etc
sh scripts/apply.sh                    # ÁP THẬT (tự backup trước)
```
`apply.sh` chạy tuần tự: backup → nạp UCI → sinh `config.json` + `sbproxy.nft` → reload network/dnsmasq/firewall/sbproxy/sing-box/wifi.

---

## Bước 8 — Kiểm tra (nghiệm thu)
Tóm tắt nhanh (đầy đủ ở [TESTING.md](TESTING.md)):

**Trên router:**
```sh
sh scripts/doctor.sh                         # báo cáo tổng thể (gói, sing-box, fake-IP DNS, tproxy, wifi, agent)
wifi status                                  # SSID đã lên?
iw dev | grep -E 'Interface|ssid|addr'       # MAC mỗi AP (random 02: hoặc theo hãng)
sing-box check -c /etc/sing-box/config.json  # config hợp lệ?
nft list table inet sbproxy                  # ruleset tproxy + hijack DNS có?
ip rule | grep 0x1 ; ip route show table 100 # policy routing có?
logread -e sing-box | tail -20               # log proxy
```

**Trên client (nối vào từng WiFi):**
| Kiểm tra | Cách | Đạt khi |
|---|---|---|
| Đúng SOCKS | mở `https://ipinfo.io/ip` | IP = IP của sock gán cho WiFi đó; 2 WiFi khác sock → 2 IP khác |
| Không leak DNS | `https://dnsleaktest.com` | DNS không phải ISP thật (fake-IP: DNS resolve phía SOCKS) |
| Không leak WebRTC | `https://browserleaks.com/webrtc` | không lộ IP thật |
| Cách ly client | 2 máy cùng WiFi, ping nhau | không ping được |
| Đổi sock không reload WiFi | chạy `set-sock.sh`, reload trang | WiFi/DHCP giữ nguyên; phiên đang mở có thể rớt |

> **DNS fake-IP:** DNS (cổng 53) của các SSID proxy được hijack vào sing-box; client nhận fake-IP
> (mặc định `198.18.0.0/15`), sing-box map ngược fake-IP về hostname và gửi **hostname** cho SOCKS
> (remote resolve). Nhờ đó không leak DNS qua dnsmasq và SOCKS không nhận IP thô. Nếu vẫn lộ, xem mục [Xử lý lỗi](#dns-vẫn-lộ-isp-thật).

> **IPv6:** v0.2 chỉ proxy IPv4 và tắt RA/DHCPv6 trên các SSID sbproxy. Không bật lại IPv6
> trước khi có TPROXY + policy routing IPv6 đầy đủ, nếu không client có thể đi thẳng ra WAN.

---

## Vận hành hằng ngày

**Đổi SOCKS của 1 WiFi (không reload WiFi; phiên mạng đang mở có thể gián đoạn):**
```sh
sh scripts/set-sock.sh <idx> <host> <port> [user] [pass]
# vd: sh scripts/set-sock.sh 2 5.6.7.8 1080 user pass
```

**Thêm / sửa WiFi:** sửa `wifi-socks.conf` (hoặc dùng UI) → `sh scripts/apply.sh`.

**Xoá 1 WiFi:** vì `apply.sh` không tự dọn section cũ, chạy `sh scripts/uninstall.sh` rồi `apply.sh` lại (sạch nhất), hoặc xoá tay `wireless.wIDX`, `network.wIDX`, `network.brwIDX`, `dhcp.wIDX`, `firewall.zIDX`.

**Backup thủ công:** `sh scripts/backup.sh <nhãn>` · **Xem danh sách:** `sh scripts/rollback.sh --list`.

---

## XỬ LÝ LỖI (theo triệu chứng)

> Quy tắc chung khi hoảng: **có LAN dây → SSH vào → `sh scripts/rollback.sh`**. Xem [ROLLBACK.md](ROLLBACK.md) cho 5 mức khôi phục.

### A. Giai đoạn firmware / flash
| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Flash xong không vào được router | IP quản trị phụ thuộc firmware (`192.168.8.1` với GL.iNet; OpenWrt vanilla có thể là `192.168.1.1`) | Đặt máy tính về DHCP, xác định đúng subnet và cắm đúng cổng LAN |
| Router không lên / brick | Firmware sai/hỏng | **U-Boot recovery** (Bước 1.4 cách A) flash lại image sạch |
| sha256 không khớp | File tải lỗi | Tải lại từ nguồn chính thức, verify lại |
| Sau nâng cấp mất hết SSID | firmware không giữ settings | Chạy lại `sh scripts/apply.sh` |

### B. WiFi không lên / thiếu SSID
| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Thiếu vài SSID | Vượt **giới hạn BSSID** của chip | Giảm số SSID/băng; `iw list` xem tối đa; chia bớt sang băng kia |
| Không SSID nào lên | Sai `RADIO_2G/5G`, hoặc radio `disabled` | Sửa mapping trong `settings.sh`; `uci set wireless.radioX.disabled=0; wifi reload` |
| WiFi chậm/giật khi nhiều SSID | Quá nhiều beacon/airtime | Giảm SSID, hoặc tăng beacon interval |
| Đổi tên/idx xong bị lỗi | Đổi idx của WiFi đang chạy | Giữ idx ổn định; nếu đã lỡ → `uninstall.sh` rồi `apply.sh` |

### C. Client không có IP / không vào được mạng nội bộ
| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Client không nhận IP | DHCP chưa chạy / zone chặn 67 | `/etc/init.d/dnsmasq restart`; đảm bảo `ZONE_INPUT=ACCEPT`; xem `logread -e dnsmasq` |
| Nhận IP nhưng sai dải | Nhầm interface/bridge | Kiểm tra `ifstatus w<idx>`; `br-w<idx>` có đúng device |

### D. Có WiFi + IP nhưng KHÔNG ra internet
Đây là lỗi hay gặp nhất — thường ở lớp proxy/tproxy:
```sh
# 1) sing-box sống không?
pgrep -f sing-box || /etc/init.d/sing-box restart
sing-box check -c /etc/sing-box/config.json      # config lỗi cú pháp?
logread -e sing-box | tail -30                    # đọc lỗi cụ thể

# 2) SOCKS upstream sống không? (test trực tiếp từ router)
curl -x socks5h://user:pass@HOST:PORT https://ipinfo.io/ip

# 3) tproxy + policy routing còn không?
nft list table inet sbproxy
ip rule | grep 0x1
ip route show table 100
/etc/init.d/sbproxy restart
```
| Nguyên nhân | Cách xử lý |
|---|---|
| SOCKS chết/sai user-pass | Đổi sock: `set-sock.sh <idx> host port user pass` |
| `ZONE_INPUT=REJECT` chặn tproxy giao gói | Đổi `ZONE_INPUT="ACCEPT"` trong settings → `apply.sh` |
| Thiếu `kmod-nft-tproxy` | chạy lại `install-deps.sh` (tự chọn apk/opkg) → `sbproxy restart` |
| Mất `ip rule/route` sau reboot | `/etc/init.d/sbproxy enable` (đã bật autostart); `sbproxy restart` |
| Sai bypass IP sock | Kiểm tra `nft list table inet sbproxy` có dòng `ip daddr <sock> return` |

### E. Ra net nhưng SAI IP (không đi qua sock)
| Nguyên nhân | Cách xử lý |
|---|---|
| iifname không khớp `br-w<idx>` | `ip -br link | grep br-w`; đảm bảo wifi gắn đúng network |
| Traffic bị bypass nhầm | Rà chain `prerouting`: dải RFC1918 return có nuốt nhầm đích công cộng? |
| Route sing-box sai inbound→outbound | Xem `config.json` rule `in-w<idx> -> out-w<idx>` |

### F. DNS vẫn lộ ISP thật
Từ bản này DNS của SSID proxy được hijack vào sing-box với fake-IP (SOCKS nhận hostname). Nếu vẫn lộ:
- Kiểm tra rule hijack đã nạp: `nft list chain inet sbproxy prerouting | grep 'dport 53'` — thiếu thì chạy lại `sh scripts/apply.sh`.
- Kiểm tra config sing-box có khối `dns`/`fakeip`: `grep fakeip /etc/sing-box/config.json`; xác nhận `nslookup example.com` từ client trả IP trong dải `198.18.0.0/15`.
- Client dùng DoH/DoT (cổng 443/853) sẽ né hijack cổng 53 — traffic đó vẫn qua TPROXY nhưng đích là IP thô; sniff SNI (`sniff_override_destination`) là fallback cho TLS. Muốn chặt hơn, chặn cổng 853 và các resolver DoH phổ biến trên các zone khách.

### G. WebRTC vẫn lộ
| Nguyên nhân | Cách xử lý |
|---|---|
| WiFi đó `webrtc=0` | Bật `webrtc=1` cho dòng đó → `apply.sh` |
| Rule chưa nạp | `nft list chain inet sbproxy webrtc`; `sbproxy restart` |
| App dùng STUN cổng lạ | Bổ sung cổng vào `STUN_*_PORTS` trong `settings.sh` |

### H. Client vẫn thấy nhau
| Nguyên nhân | Cách xử lý |
|---|---|
| `isolate=0` | Bật `isolate=1` → `apply.sh` |
| Chung 1 bridge nhiều AP | Mỗi SSID phải là `br-w<idx>` riêng (đúng thiết kế); kiểm tra `network.w<idx>.device` |
| Giữa các SSID | Zone `forward=REJECT`, không có `config forwarding` giữa các zone khách |

### I. Mất kết nối hoàn toàn (không SSH/WiFi)
1. **LAN dây** → SSH `root@192.168.8.1` (hoặc IP LAN thực tế) → `sh scripts/rollback.sh`.
2. **Failsafe mode**: reboot, bấm Reset khi đèn nháy; máy tính IP `192.168.1.2`, SSH `root@192.168.1.1` (không mật khẩu) → `mount_root` → rollback, hoặc `firstboot && reboot` (reset về mặc định).
3. **U-Boot recovery**: flash lại firmware sạch (Bước 1.4 cách A).
Chi tiết: [ROLLBACK.md](ROLLBACK.md) Mức 4.

---

## FAQ
**Q: Đổi sock có làm rớt WiFi/kick client không?**
A: WiFi và DHCP giữ nguyên, nhưng `set-sock.sh` restart sing-box + tproxy nên phiên TCP/UDP đang mở có thể gián đoạn.

**Q: MAC random ở đâu?**
A: `apply.sh` tự sinh MAC `02:xx..` cho WiFi mới và **giữ ổn định** các lần apply sau. UI không cần nhập MAC.

**Q: Tối đa bao nhiêu SSID?**
A: Theo `iw list` (thường ~16/băng). Nhiều SSID làm chậm WiFi — nên 12–16/băng.

**Q: Reboot router có mất cấu hình không?**
A: Không. UCI + `/etc/sing-box/config.json` + `/etc/sbproxy.nft` đều lưu vĩnh viễn; `sbproxy` và `sing-box` autostart.

**Q: Muốn gỡ sạch để làm lại?**
A: `sh scripts/uninstall.sh` (tự backup trước).

**Q: UI có điều khiển router trực tiếp không?**
A: Có 2 chế độ. Mặc định UI sinh `wifi-socks.conf` để bạn `apply.sh`. Muốn UI **bấm-là-áp + health-check SOCKS realtime**: cài agent kiến trúc B (`sh agent/install-agent.sh`) rồi mở UI từ `http://<router>/sbproxy/`. Chi tiết: [../agent/README.md](../agent/README.md).

**Q: Có điều khiển router qua Internet không?**
A: Project chỉ hỗ trợ local. Dùng UI trực tiếp trong LAN quản trị; nếu cần truy cập từ ngoài,
hãy vào LAN bằng VPN do bạn tự quản lý. Không mở LuCI/uhttpd/agent trực tiếp ra WAN.
