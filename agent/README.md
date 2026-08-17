# sbproxy Agent (kiến trúc B) — CGI trên uhttpd + health-check realtime

**Ngôn ngữ:** Tiếng Việt | [English](README.en.md)

Biến UI từ "trình sinh config" thành **bảng điều khiển trực tiếp**: bấm nút trên UI → agent chạy `apply.sh`/`set-sock.sh`/`rollback.sh` trên router, và hiển thị **latency SOCKS realtime** cho từng WiFi.

```
Trình duyệt (UI mở TỪ router, http)
        │  fetch /cgi-bin/sbproxy?action=...   (header X-SB-Token)
        ▼
uhttpd ── CGI /www/cgi-bin/sbproxy ──> gọi scripts/*.sh + đọc health JSON
        ▲
        │  ghi /tmp/sbproxy-health.json mỗi 15s
sbproxy-healthd (procd) ── curl -x socks5h://… đo latency từng sock
```

## Thành phần
| File | Cài tới | Vai trò |
|---|---|---|
| `cgi/sbproxy` | `/www/cgi-bin/sbproxy` | REST API (status/apply/set_sock/save_conf/rollback/…) |
| `sbproxy-healthd` | `/usr/sbin/sbproxy-healthd` | Daemon probe SOCKS, đo latency, ghi JSON |
| `init.d/sbproxy-healthd` | `/etc/init.d/sbproxy-healthd` | procd chạy daemon, autostart |
| `install-agent.sh` | (chạy 1 lần) | Cài tất cả + tạo token + self-host UI |

## Cài đặt
Tiền đề: project đã ở `/root/sbproxy`, `apply.sh` chạy được (đã làm theo GUIDE tới bước Áp dụng).
```sh
cd /root/sbproxy
sh agent/install-agent.sh
```
Script sẽ: cài `curl jq`, tạo `/etc/sbproxy/env` + `/etc/sbproxy/token`, đặt CGI, self-host UI vào `/www/sbproxy/`, cài + chạy health daemon. Cuối cùng in ra **URL + token**.

## Dùng
1. Mở **`http://<router>/sbproxy/`** (phải là **http từ chính router** — xem mixed-content bên dưới).
2. Bấm **🔌 Kết nối router**, để trống Base URL (same-origin), dán **token** → **Kết nối**.
3. Khi kết nối:
   - Cột **Sức khỏe** hiện latency mỗi WiFi (xanh ok / vàng chậm / đỏ fail), tự cập nhật ~8s.
   - **⇪ Đẩy & Áp lên router**: ghi `wifi-socks.conf` từ UI rồi chạy `apply.sh`.
   - **⭳ Tải từ router**: nạp `wifi-socks.conf` hiện có trên router vào UI.
   - Nút **⚡** mỗi hàng: đổi SOCKS mà không reload WiFi; phiên đang mở có thể gián đoạn khi sing-box restart.

## API (tham chiếu)
Header bắt buộc: `X-SB-Token: <token>`.
| Method | action | Body | Trả về |
|---|---|---|---|
| GET | `status` | — | `{ssids[], health{ts,probes{idx:{state,latency_ms,code}}}, meta}` |
| GET | `get_conf` | — | text/plain wifi-socks.conf |
| POST | `save_conf` | text | `{ok,saved}` |
| POST | `apply` | — | `{ok,rc,log}` |
| POST | `set_sock` | `{idx,host,port,user,pass}` | `{ok,rc,log}` |
| POST | `rollback` | `{name?}` | `{ok,rc,log}` |
| POST | `uninstall` | — | `{ok,rc,log}` |
| GET | `backups` | — | `{ok,backups[]}` |
| GET | `health_now` | — | probe ngay 1 lần |

Test nhanh:
```sh
TOKEN=$(cat /etc/sbproxy/token)
curl -H "X-SB-Token: $TOKEN" http://192.168.8.1/cgi-bin/sbproxy?action=status | jq .
```

## ⚠️ Mixed-content (quan trọng)
Trình duyệt **chặn** trang https gọi tới router http. Vì vậy:
- Mở UI **từ chính router** qua `http://<router>/sbproxy/` → gọi API same-origin http → OK.
- Bản UI trên artifact (https của claude.ai) **không** dùng được chế độ Live (chỉ dùng để sinh config offline). Chức năng offline vẫn hoạt động bình thường.

## 🔒 Bảo mật (bắt buộc)
- **Chỉ dùng trên LAN/VLAN quản trị. KHÔNG mở uhttpd/agent ra WAN.**
- Giữ **token** bí mật; đổi bằng cách xoá `/etc/sbproxy/token` rồi chạy lại install-agent.
- API cho phép chạy `apply/uninstall/rollback` → ai có token là có quyền cấu hình router.
- Cân nhắc đặt UI/agent sau HTTPS nội bộ + chặn truy cập từ các SSID khách (firewall input).

## Cấu hình
`/etc/sbproxy/env` (do install-agent tạo): `SB_ROOT`, `CONF`, `PROBE_URL`, `INTERVAL` (giây giữa các lần probe), `SLOW_MS` (ngưỡng "chậm"), `PROBE_TIMEOUT`.
Đổi xong: `/etc/init.d/sbproxy-healthd restart`.

## Gỡ agent
```sh
/etc/init.d/sbproxy-healthd stop; /etc/init.d/sbproxy-healthd disable
rm -f /www/cgi-bin/sbproxy /usr/sbin/sbproxy-healthd /etc/init.d/sbproxy-healthd
rm -rf /www/sbproxy /etc/sbproxy
```
