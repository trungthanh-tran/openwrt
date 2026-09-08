# Security Policy

## Mô hình bảo mật
sbproxy điều khiển định tuyến mạng và giữ thông tin nhạy cảm (token agent, khoá
WiFi, tài khoản SOCKS). Nguyên tắc:

- **Chỉ dùng trên LAN/VLAN quản trị tin cậy hoặc VPN tự quản.** Không expose
  agent/uhttpd/SSH/LuCI ra WAN.
- **Token agent là bí mật dùng chung, toàn quyền** — không có tài khoản theo
  người. Giữ `/etc/sbproxy/token` quyền `600`; xoay khi nghi lộ.
- **Fail-closed:** zone khách `forward=REJECT` — proxy chết thì client mất mạng,
  không đi thẳng ra WAN.
- **Không commit bí mật** vào git (xem `.gitignore`): `wifi-socks.conf` thật,
  `proxy-pools.conf` thật (chứa credential của **mọi** proxy trong pool),
  `routing-rules.conf` thật (lộ tên miền và dải IP mà triển khai này quan tâm),
  token, backup. `scripts/security-audit.sh` kiểm quyền của cả hai file.
- **API thống kê của sing-box (`TRAFFIC_STATS=1`) là API điều khiển**, không
  phải chỉ đọc: ai gọi được nó thì đổi được định tuyến. Mặc định tắt; khi bật thì
  `apply.sh` từ chối `CLASH_API_LISTEN` bind ngoài localhost, và secret sinh tự
  động ở `/etc/sbproxy/clash-secret` quyền `600` — không đặt trong `settings.sh`
  vì file đó được commit.

## Báo cáo lỗ hổng
Không mở issue công khai cho lỗ hổng bảo mật. Liên hệ maintainer nội bộ
(người phụ trách repo) qua kênh riêng, kèm:
- mô tả lỗ hổng và ảnh hưởng,
- bước tái hiện,
- phiên bản (`cat VERSION`) và firmware router.

## Kiểm tra bảo mật
- `sh scripts/security-audit.sh` — audit quyền file, SSH, dấu hiệu mở quản trị.
- `sh scripts/doctor.sh` — trạng thái tổng thể gồm agent/token.
- `docs/TESTING.md` — leak DNS/WebRTC/IPv6 phía client.
