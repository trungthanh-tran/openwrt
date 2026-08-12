# sbproxy Cloud — control server từ xa (RBAC)

Điều khiển & giám sát nhiều router GL-MT6000 **từ xa qua web**, có **đăng nhập riêng + phân quyền theo tính năng**. Router **poll RA** server (không mở cổng WAN, chạy sau NAT/CGNAT). Xem latency proxy realtime, đổi SOCKS, áp cấu hình, backup/rollback — không cần vào mạng router.

```
Bạn ─(đăng nhập)─▶ Web UI + API (server này, có DB) ◀─ router poll RA (mỗi ~10s)
                         │  lưu lịch sử latency + config mong muốn      │ push health
                         └──────────────────────────────────────────────┘ pull config/commands
```

## Phân quyền (RBAC)
- **superuser**: toàn quyền + quản lý người dùng + quản lý router. Tạo **chỉ bằng CLI** (`seed.js`) cho an toàn.
- **user thường**: được cấp **tập quyền theo tính năng** + **giới hạn router** (mọi router / một số router cụ thể).

| Quyền | Cho phép |
|---|---|
| `health.view` | Xem trạng thái & latency |
| `wifi.view` | Xem danh sách WiFi/SOCKS |
| `wifi.manage` | Thêm/sửa/xoá WiFi (sửa cấu hình) |
| `sock.change` | Đổi SOCKS (không rớt WiFi) |
| `config.apply` | Đẩy & áp cấu hình |
| `backup.create` | Tạo/tải backup |
| `backup.rollback` | Khôi phục |
| `device.manage` | *(super)* Quản router, cấp key |
| `user.manage` | *(super)* Quản người dùng |
| `audit.view` | Xem nhật ký |

UI **tự ẩn/khoá** nút theo quyền; server **luôn kiểm tra lại** ở API (không tin client).

## Cài server (VPS)
```bash
cd cloud-server
npm install                       # cần Node >= 18 (better-sqlite3 sẽ build)
node seed.js admin 'MatKhauManh123'   # tạo SUPERUSER
PORT=8088 npm start
# mở http://<VPS>:8088  → đăng nhập
```
Biến môi trường: `PORT`, `JWT_SECRET` (tự sinh nếu bỏ trống, lưu `data/jwt.secret`), `SBPROXY_DB` (đường dẫn DB), `POLL_INTERVAL`, `HTTPS=1` (đặt khi chạy sau reverse proxy TLS để cookie `secure`).

### Chạy nền (systemd gợi ý)
```ini
# /etc/systemd/system/sbproxy-cloud.service
[Service]
WorkingDirectory=/opt/sbproxy/cloud-server
ExecStart=/usr/bin/node server.js
Environment=PORT=8088 HTTPS=1
Restart=always
[Install]
WantedBy=multi-user.target
```
> **Bảo mật:** đặt sau **reverse proxy HTTPS** (Caddy/Nginx). Không chạy HTTP trần ra internet (mật khẩu + cookie sẽ lộ).

## Thêm router & cài agent
1. Trên web (tab **Router**) → **＋ Thêm router** → server hiện **device key (một lần)** + đoạn lệnh.
2. Trên router (đã cài project sbproxy + agent health):
   ```sh
   cat > /etc/sbproxy/cloud.env <<'EOF'
   CLOUD_URL=https://cloud.example.com
   DEVICE_KEY=<key vừa cấp>
   CLOUD_INTERVAL=10
   EOF
   chmod 600 /etc/sbproxy/cloud.env
   sh cloud-server/agent/install-cloud-agent.sh
   ```
3. Sau ~10s router chuyển **online** trên web.

## Cách hoạt động (pull model)
- **Config mong muốn** lưu ở server (dạng `wifi-socks.conf`). Sửa trên web → tăng `config_version`.
- Router mỗi vòng: `poll` → nếu version mới thì ghi conf + chạy `apply.sh`; nhận **command** (backup/rollback/set_sock) và thực thi; `report` health + danh sách backup + version đã áp.
- **Đổi SOCKS**: enqueue command `set_sock` → router chạy `set-sock.sh` (không rớt WiFi).

## Bảo mật — bắt buộc
- HTTPS (reverse proxy). Đặt `HTTPS=1`.
- Superuser chỉ tạo qua `seed.js`. Mật khẩu mạnh, đổi định kỳ.
- **Device key** chỉ hiện 1 lần; băm SHA-256 lưu trong DB. Lộ key → **Đổi key** (rekey) ngay.
- Cấp quyền tối thiểu cho user; giới hạn phạm vi router.
- Sao lưu file `data/` (DB + jwt.secret) của server.

## Ghi chú
- v0.1: xác thực JWT trong cookie httpOnly. Cân nhắc thêm 2FA/khoá đăng nhập-sai-nhiều-lần cho production.
- API thiết bị & người dùng: xem `server.js`. Danh mục quyền: `rbac.js`.
