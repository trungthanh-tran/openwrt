# ROLLBACK — Khi có lỗi thì khôi phục thế nào

Có nhiều mức, từ nhẹ tới nặng. **Luôn còn đường LAN dự phòng** khi thao tác định tuyến/WiFi.

## Cơ chế backup
Mỗi lần `apply.sh` / `set-sock.sh` / `uninstall.sh` chạy đều **tự backup trước** vào:
```
/root/sbproxy-backups/<timestamp>-<nhãn>/
  ├── etc-config.tar.gz          # /etc/config + /etc/sing-box
  ├── sbproxy.nft                # ruleset nftables
  ├── wifi-socks.conf            # config nguồn
  └── sysupgrade-backup.tar.gz   # backup chuẩn OpenWrt
```
`/root/sbproxy-backups/latest` trỏ tới bản mới nhất. Giữ tối đa 20 bản.

## ⚠️ Backup RA MÁY TÍNH (off-device) — bắt buộc trước khi update firmware
Backup trên nằm **trên router** → mất sạch nếu reflash/brick. Luôn tải một bản xuống máy:
```sh
# trên UI: 🗂 Backup / Rollback → ⭳ Về máy
# hoặc từ máy tính:
scp -r root@192.168.1.1:/root/sbproxy-backups .\sbproxy-backups
```
Đăng ký giữ config khi nâng cấp (đã tự làm bởi install-deps/install-agent):
```sh
cat /etc/sysupgrade.conf   # phải có /etc/sing-box/, /etc/sbproxy.nft, /etc/sbproxy/, config/
```
**Quy trình update firmware an toàn:** ghi lại version hiện tại → tải backup về máy → `sh scripts/backup.sh before-fw-upgrade` → nâng cấp → nếu mất config thì `sysupgrade -r <backup>` rồi `apply.sh`.

Khôi phục bản đã tải về máy:
```sh
scp .\sbproxy-<tên>.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sysupgrade -r /tmp/sbproxy-<tên>.tar.gz && reboot"
```

---

## Mức 1 — Rollback bằng script (thường dùng)
```sh
sh scripts/rollback.sh --list          # xem các bản backup
sh scripts/rollback.sh                  # về bản 'latest'
sh scripts/rollback.sh 20260812-101500-pre-apply   # về bản cụ thể
```
Script sẽ: phục hồi `/etc/config` + `/etc/sing-box` + `sbproxy.nft` + `wifi-socks.conf`, rồi reload network/dnsmasq/firewall/sbproxy/sing-box/wifi.

## Mức 2 — Gỡ sạch phần project tạo (giữ nguyên phần còn lại của router)
```sh
sh scripts/uninstall.sh
```
Xoá mọi `wireless.wIDX / network.wIDX / br-wIDX / dhcp.wIDX / firewall.zIDX`, dừng tproxy, xoá bảng nft `sbproxy`, dừng sing-box. Router trở về mạng LAN/WiFi gốc.

## Mức 3 — Khôi phục backup chuẩn OpenWrt (khi UCI hỏng nặng)
```sh
sysupgrade -r /root/sbproxy-backups/latest/sysupgrade-backup.tar.gz
reboot
```
Hoặc qua LuCI: **System → Backup / Flash Firmware → Restore backup** (upload file `sysupgrade-backup.tar.gz`).

## Mức 4 — Mất kết nối hoàn toàn (không SSH/WiFi được)
1. **Cắm dây LAN** vào 1 cổng LAN của router, đặt IP tĩnh máy tính cùng dải (vd `192.168.8.2`), SSH lại `root@192.168.8.1` → chạy Mức 1/2.
2. Nếu vẫn không vào được LAN: **Failsafe mode** của OpenWrt
   - Rút điện, cắm lại; khi đèn nhấp nháy, bấm nút **Reset** vài lần để vào failsafe.
   - Máy tính đặt IP `192.168.1.2`, SSH `root@192.168.1.1` (không mật khẩu trong failsafe).
   - `mount_root` rồi chạy rollback, hoặc `firstboot && reboot` để reset toàn bộ về mặc định.
3. **U-Boot recovery (nặng nhất, brick):** GL-MT6000 có U-Boot web. Đặt IP `192.168.1.2`, vào `http://192.168.1.1` (giữ Reset khi cấp nguồn), flash lại firmware sạch.

## Mức 5 — Chỉ sing-box/proxy lỗi (WiFi vẫn chạy nhưng không ra net)
Không cần rollback cả hệ — thường do config SOCKS/tproxy:
```sh
logread -e sing-box | tail -30           # xem log sing-box
sing-box check -c /etc/sing-box/config.json   # validate config
nft list table inet sbproxy              # kiểm tra ruleset tproxy
ip rule ; ip route show table 100        # policy routing còn không
/etc/init.d/sbproxy restart
/etc/init.d/sing-box restart
```
Đổi tạm 1 WiFi về SOCKS khác: `sh scripts/set-sock.sh <idx> <host> <port> ...`

---

## Mẹo an toàn
- **Trước khi apply lần đầu:** tự tạo 1 backup mốc `sh scripts/backup.sh baseline`.
- Test trên **1–2 SSID** trước, chạy ổn rồi mới nhân lên 20–30.
- Dùng `DRYRUN=1 sh scripts/apply.sh` để soi thay đổi trước khi thực thi.
