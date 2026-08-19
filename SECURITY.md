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
  token, backup.

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
