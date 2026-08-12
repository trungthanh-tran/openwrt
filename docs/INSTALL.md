# INSTALL — Cài đặt chi tiết

## 0. Yêu cầu trước
- Router **GL-MT6000** đã chạy **OpenWrt** (vanilla/ImmortalWrt). Nếu còn firmware GL.iNet stock, cân nhắc theo mục 2 của plan.
- Truy cập **SSH** vào router (`ssh root@192.168.8.1` hoặc IP LAN của bạn).
- **QUAN TRỌNG:** làm lần đầu khi **có đường mạng dự phòng** (cắm LAN trực tiếp) để nếu WiFi/định tuyến hỏng vẫn vào lại được router.

## 1. Đưa project lên router
Từ máy tính (PowerShell):
```powershell
scp -r .\openwrt-multiwifi-socks5 root@192.168.8.1:/root/sbproxy
```
Rồi SSH vào:
```sh
ssh root@192.168.8.1
cd /root/sbproxy
```

## 2. Chuẩn bị config
```sh
cp config/wifi-socks.conf.example config/wifi-socks.conf
vi config/wifi-socks.conf
```
Mỗi dòng 1 WiFi: `name|band|idx|wifi_key|sock_host|sock_port|sock_user|sock_pass|isolate|webrtc`
- `idx` phải **duy nhất** và **ổn định** (đừng đổi idx của WiFi đã chạy — sẽ đổi subnet).
- subnet tự tính = `192.168.(10+idx).0/24`.

Chỉnh tunables:
```sh
vi config/settings.sh
```
- `RADIO_2G` / `RADIO_5G`: **phải khớp** phần cứng — xác nhận ở bước 3.
- `BSSID_LIMIT`: xem `iw list`.
- `ZONE_INPUT`: để `ACCEPT` (mặc định, chạy chắc). Xem giải thích trong file.

## 3. Preflight (chỉ đọc, không đổi gì)
```sh
sh scripts/preflight.sh
```
Đọc kỹ:
- **Radio ↔ băng tần**: sửa `settings.sh` nếu radio0 không phải 2.4G.
- **valid interface combinations**: đây là **số AP tối đa/radio thực tế**. Chốt số SSID ≤ số này.
- Các gói **[THIẾU]** sẽ được cài ở bước 4.

## 4. Cài gói + init
```sh
sh scripts/install-deps.sh
```
Cài: `nftables kmod-nft-tproxy kmod-nft-core ip-full iw-full sing-box`, cài `/etc/init.d/sbproxy` và bật autostart.

> Nếu opkg không có `sing-box`: tải binary aarch64 (MT7986) từ release chính thức sing-box, đặt vào `/usr/bin/sing-box`, và tạo `/etc/init.d/sing-box` (procd) trỏ tới `config.json`. Xem docs sing-box.

## 5. Xem trước rồi áp
```sh
DRYRUN=1 sh scripts/apply.sh | less      # xem UCI + sing-box + nft sẽ tạo
sh scripts/apply.sh                       # áp thật (tự backup trước)
```
`apply.sh` làm tuần tự: backup → nạp UCI (network/dhcp/firewall/wireless) → sinh `config.json` + `sbproxy.nft` → reload network/dnsmasq/firewall/sbproxy/sing-box/wifi.

## 6. Kiểm thử
Theo [TESTING.md](TESTING.md). Tối thiểu: nối thử 1 WiFi → kiểm tra IP public đúng SOCKS, không leak DNS/WebRTC, 2 client không thấy nhau.

## 7. Thay đổi về sau
- **Đổi SOCKS 1 WiFi (không rớt WiFi):** `sh scripts/set-sock.sh <idx> <host> <port> [user] [pass]`
- **Thêm/bớt/sửa WiFi:** sửa `wifi-socks.conf` → `sh scripts/apply.sh`.
  - *Lưu ý:* khi **xoá** 1 dòng, `apply.sh` không tự dọn section cũ. Chạy `sh scripts/uninstall.sh` (gỡ hết) rồi `apply.sh` lại, hoặc xoá tay `wireless.wIDX` v.v.
- **Gỡ toàn bộ:** `sh scripts/uninstall.sh`.

## 8. Bảo mật (nên làm)
- Đổi mật khẩu root, chỉ cho SSH/LuCI trên LAN quản trị.
- Không mở quản trị ra WAN.
- `settings.sh` mặc định đã chặn cổng admin (`22/80/443`) từ các zone khách.
