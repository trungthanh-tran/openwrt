# TESTING — Kiểm thử từng yêu cầu

**Ngôn ngữ:** Tiếng Việt | [English](TESTING.en.md)

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
> DNS của SSID proxy được hijack vào sing-box (fake-IP, remote resolve qua SOCKS). Kiểm tra nhanh trên client: `nslookup example.com` phải trả IP trong dải `198.18.0.0/15`. Nếu trả IP thật → rule hijack chưa nạp, chạy lại `sh scripts/apply.sh` và `sh scripts/verify.sh`.

### B3. WebRTC — kết quả tuỳ chế độ
Mở https://browserleaks.com/webrtc. Đạt hay không phụ thuộc cột `webrtc` của SSID đó:

| Chế độ | Đạt khi |
|---|---|
| `0` giữ nguyên | Không kiểm tra — không có rule nào được áp. |
| `1` chặn | Không lộ IP public thật ("Public IP" trống). Gọi video P2P hỏng là đúng thiết kế. |
| `2` bypass | "Public IP" hiện **IP của proxy**, không phải IP thật của router, và cuộc gọi vẫn chạy. |

Kiểm tra ngược trên router:
```sh
nft list chain inet sbproxy webrtc            # webrtc=1: thấy rule drop STUN cho br-wIDX
nft list chain inet sbproxy w<IDX>            # webrtc=2: thấy rule tproxy STUN đứng TRÊN mọi rule return
```
> `webrtc=2` cần proxy relay được UDP và `SOCKS_UDP=1`. Nếu proxy từ chối UDP
> ASSOCIATE thì WebRTC không tìm được candidate — nhìn ra ngoài giống hệt
> `webrtc=1`. Xem B7 để kiểm tra UDP trước.

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

### B7. UDP đi qua proxy (SOCKS_UDP=1)
Chỉ áp dụng cho SSID dùng proxy socks5. Trên client:
```sh
nslookup example.com            # phải ra fake-IP 198.18.0.0/15 như B2
```
Mở một trang chạy QUIC/HTTP3 (ví dụ https://cloudflare-quic.com) hoặc gọi video.
**Đạt khi:** trang báo dùng HTTP/3, hoặc cuộc gọi có media hai chiều.

Kiểm tra ngược trên router:
```sh
nft list chain inet sbproxy w<IDX> | grep 'udp dport 443 drop'   # phải KHÔNG có
jq '.outbounds[]|select(.tag=="out-w<IDX>")|.network' /etc/sing-box/config.json
# null = có relay UDP · "tcp" = chỉ TCP
```
**Không đạt** (QUIC treo rồi mới rơi về TCP) thường là proxy upstream từ chối
UDP ASSOCIATE. Đặt `SOCKS_UDP=0` rồi `apply` để trình duyệt rơi về TCP ngay,
thay vì phải chờ timeout.

> SSID dùng proxy HTTP luôn giữ rule drop UDP 443, kể cả khi `SOCKS_UDP=1`:
> proxy HTTP không có kênh UDP nào để đi.

### B8. Luật direct/block theo domain/IP (routing-rules.conf)
Thêm vào `config/routing-rules.conf` rồi `apply`:
```
direct|domain_suffix|ipinfo.io
block|domain_suffix|example.com
```
Trên client: mở `https://ipinfo.io/ip` → **đạt khi** hiện IP thật của router (đi
thẳng, không qua proxy). Mở `https://example.com` → **đạt khi** không tải được.
Mở một trang bất kỳ khác → vẫn ra IP của proxy.

Kiểm tra ngược trên router:
```sh
jq '.route.rules' /etc/sing-box/config.json   # luật direct/block đứng TRÊN các rule inbound
```
**Thứ tự:** nếu một luật hẹp không có tác dụng, kiểm tra nó có đứng TRÊN luật
rộng hơn không — khớp đầu tiên thắng.

### B9. Máy chưa ghim bị chặn (POOL_UNASSIGNED=block)
Trên SSID **có pool**, đặt `POOL_UNASSIGNED=block` rồi `apply`. Cho một máy chưa
ghim vào SSID đó.
**Đạt khi:** máy vẫn nhận IP DHCP và ping được gateway của nó, nhưng
`nslookup example.com` **không trả lời** và không mở được trang nào.
Sau `sh scripts/assign.sh <IDX> <mac> auto` thì mạng chạy ngay, không cần apply.

```sh
nft list chain inet sbproxy w<IDX> | tail -3   # rule cuối phải là `drop`
```
> DNS bị chặn là **có chủ ý**. Nếu để DNS chạy, máy sẽ nhận fake-IP rồi không kết
> nối được — trông như hỏng chứ không phải như bị chặn.

### B10. Proxy cho máy trên dải LAN chính (LAN_PROXY=1)
Thêm dòng `0|socks5|...` vào `proxy-pools.conf`, đặt `LAN_PROXY=1`, `apply`.
Dùng một **máy cắm dây** trên dải LAN chính.

1. **Trước khi ghim** — mở `https://ipinfo.io/ip`: **đạt khi** hiện IP thật của
   router, và `nslookup example.com` trả IP thật (không phải fake-IP). Bật tính
   năng này không được đổi gì với máy chưa ghim.
2. `sh scripts/assign.sh 0 <mac> auto` rồi tải lại trang: **đạt khi** hiện IP của
   proxy đã ghim.
3. `sh scripts/assign.sh 0 <mac> none`: **đạt khi** quay lại IP thật của router.

```sh
nft list chain inet sbproxy w0        # chain của br-lan, map @w0map
```
> LAN không có proxy mặc định, nên bước 1 và 3 phải cho **cùng một kết quả**.

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
| 5e | Proxy cho máy LAN/dây | B10 | `LAN_PROXY=1`: ghim rồi ra IP proxy, chưa ghim thì y như trước |
| 5d | Chặn máy chưa gán proxy | B9 | `POOL_UNASSIGNED=block`: chưa ghim thì không có mạng lẫn DNS; ghim xong chạy ngay |
| 5c | Direct/block theo domain/IP | B8 | đích `direct` ra IP thật, đích `block` không tải được, còn lại vẫn qua proxy |
| 5b | UDP qua proxy | B7 | `SOCKS_UDP=1`: QUIC/media chạy được qua proxy socks5 |
| 5 | WebRTC theo chế độ | B3 | `webrtc=1` không lộ IP · `webrtc=2` lộ IP của proxy, cuộc gọi vẫn chạy |
| 6 | Cách ly client | B4 + B5 | không ping được nhau |

## Ghi chú
- Nếu **B1 fail** (không ra net): xem [ROLLBACK.md](ROLLBACK.md) Mức 5 (debug sing-box/tproxy). Thường do: SOCKS sai/chết, `ZONE_INPUT=REJECT` chặn tproxy (đổi về `ACCEPT`), hoặc thiếu `kmod-nft-tproxy`.
- Ghi lại kết quả mỗi test vào 1 file để so sánh giữa các lần thay đổi.

### B11. Rebalance trên thiết bị thật

Chạy router-side khi có client thật đang online trên SSID có proxy pool:

```sh
sh tests/test_rebalance_live.sh 4
```

Test kiểm tra client online, pool không rỗng, seed fallback khi thiếu `cksum`,
preview lặp lại được, commit thật và trạng thái pin sau commit. Trên máy
Windows đang có thêm route LAN quản trị, ép đúng interface Wi-Fi:

```powershell
.\pc\test-rebalance-client.ps1 -ClientIp 192.168.14.150 -ExpectedProxyIp 178.93.44.10
```

Đạt khi client reconnect, vẫn nhận DHCP, trạng thái `pinned`, và IP public
bằng IP proxy. Không dùng route Ethernet/management để đánh giá egress.
