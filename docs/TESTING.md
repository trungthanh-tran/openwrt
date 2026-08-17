# TESTING — Kiểm thử từng yêu cầu

Chạy sau `apply.sh`. Cột "Đạt khi" là tiêu chí pass. Nhiều test cần **một máy client nối vào WiFi cần kiểm**.

## A. Kiểm tra trên router (SSH)

### A1. WiFi/SSID đã lên đúng
```sh
wifi status
iw dev | grep -E 'Interface|ssid|addr'      # xem các AP + MAC
ubus call network.wireless status | grep -i ssid
```
**Đạt khi:** thấy đủ số SSID trong `wifi-socks.conf`, mỗi cái MAC khác nhau (random).

### A2. MAC ngẫu nhiên & ổn định
```sh
for i in 1 2 3; do echo -n "w$i: "; uci -q get wireless.w$i.macaddr; done
```
**Đạt khi:** MAC bắt đầu `02:` và khác nhau. Chạy `apply.sh` lại → MAC **không đổi** (ổn định).

### A3. Mạng/subnet/DHCP
```sh
ip -4 addr | grep 192.168                    # mỗi br-wIDX có .1 riêng
ifstatus w1 | grep address
cat /tmp/dhcp.leases                          # có lease khi client nối
```
**Đạt khi:** mỗi interface `w<idx>` có IP `192.168.(10+idx).1`.

### A4. sing-box hợp lệ & đang chạy
```sh
sing-box check -c /etc/sing-box/config.json && echo OK
pgrep -f sing-box && echo running
logread -e sing-box | tail -20
```
**Đạt khi:** `check` OK, tiến trình chạy, log không spam lỗi.

### A5. TPROXY + policy routing
```sh
nft list table inet sbproxy                   # thấy chain prerouting + rule iifname
ip rule | grep 0x1                             # fwmark 1 -> table 100
ip route show table 100                         # local default dev lo
```
**Đạt khi:** có bảng `sbproxy`, có ip rule fwmark, có route table 100.

## B. Kiểm tra từ client (nối vào từng WiFi)

### B1. Ra internet & ĐÚNG SOCKS (IP public khớp)
Trên client đã nối WiFi cần test:
```sh
curl -s https://ipinfo.io/ip      # hoặc mở https://ipinfo.io trên trình duyệt
```
**Đạt khi:** IP trả về = **IP của SOCKS gán cho WiFi đó**, không phải IP nhà mạng của bạn.
Đối chiếu: nối WiFi Alpha (sock A) và WiFi Bravo (sock B) phải ra **2 IP khác nhau**.

### B2. Không leak DNS
Mở https://dnsleaktest.com (Extended test).
**Đạt khi:** DNS server hiện ra **không phải** ISP thật của bạn.
> ⚠️ v0.1: DNS mặc định đi qua dnsmasq của router → **có thể vẫn leak**. Đây là hạn chế đã biết. Để chống leak: cấu hình dnsmasq forward qua DoH/proxy, hoặc bật DNS trong sing-box (sẽ bổ sung ở bản sau). Ghi nhận kết quả test để quyết định.

### B3. Không leak WebRTC (các WiFi bật webrtc=1)
Mở https://browserleaks.com/webrtc
**Đạt khi:** không lộ IP public thật qua WebRTC (mục "Public IP" trống hoặc = IP sock).
Kiểm tra ngược trên router:
```sh
nft list chain inet sbproxy webrtc            # thấy rule drop STUN cho br-wIDX
```

### B4. Cách ly client trong cùng WiFi (isolate=1)
Nối **2 thiết bị** vào cùng 1 WiFi (isolate=1). Từ máy 1 ping máy 2:
```sh
ping <IP-máy-2>
```
**Đạt khi:** **không ping được** (bị cô lập).

### B5. Cách ly giữa các WiFi khác nhau
Máy 1 ở WiFi Alpha (192.168.11.x), máy 2 ở WiFi Bravo (192.168.12.x). Ping chéo.
**Đạt khi:** không thấy nhau (zone forward=REJECT).

### B6. Client không vào được trang admin router
Từ client khách mở `http://192.168.(10+idx).1` (LuCI) và thử `ssh`.
**Đạt khi:** bị từ chối (rule chặn admin `22/80/443`).

## C. Kịch bản đổi SOCKS không gián đoạn
```sh
# Trên router:
sh scripts/set-sock.sh 1 <sock_mới> 1080 user pass
```
Trên client **đang nối WiFi Alpha**, đang mở 1 tab:
**Đạt khi:** WiFi association/DHCP giữ nguyên, reload trang → `ipinfo.io` đổi sang IP sock mới.
Các phiên TCP/UDP đang mở có thể gián đoạn vì sing-box được restart; đây không phải zero-downtime migration.

## D. Bảng tổng hợp nhanh
| # | Yêu cầu | Test | Đạt khi |
|---|---------|------|---------|
| 1 | SOCKS5 per WiFi | B1 | IP public = sock tương ứng |
| 2 | 20–30 SSID | A1 + preflight `iw list` | đủ SSID, ≤ giới hạn BSSID |
| 3 | Đổi sock không reload WiFi | C | WiFi/DHCP giữ nguyên, IP đổi; ghi nhận gián đoạn phiên |
| 4 | Random MAC | A2 | MAC `02:` khác nhau, ổn định |
| 5 | Chặn WebRTC | B3 | không lộ IP qua WebRTC |
| 6 | Cách ly client | B4 + B5 | không ping được nhau |

## Ghi chú
- Nếu **B1 fail** (không ra net): xem [ROLLBACK.md](ROLLBACK.md) Mức 5 (debug sing-box/tproxy). Thường do: SOCKS sai/chết, `ZONE_INPUT=REJECT` chặn tproxy (đổi về `ACCEPT`), hoặc thiếu `kmod-nft-tproxy`.
- Ghi lại kết quả mỗi test vào 1 file để so sánh giữa các lần thay đổi.
