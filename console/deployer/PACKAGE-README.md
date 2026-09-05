# sbproxy Web Deploy — bắt đầu tại đây

Gói này chỉ dùng để kiểm tra router, cài/cập nhật sbproxy Web và mở Web Console.
Nó không có chức năng quản lý Wi-Fi, proxy hoặc thiết bị.

## Chạy

Windows:

1. Giải nén toàn bộ file ZIP.
2. Chạy `sbproxy-web-deployer.exe`.

Linux:

1. Giải nén TAR.GZ.
2. Chạy `./sbproxy-web-deployer` trong terminal hoặc trình quản lý file.

Máy Linux cần môi trường desktop đồ họa và lệnh `ssh` (gói `openssh-client`).

Trong ứng dụng, nhập IP/host, SSH port, username và password của router. Bấm
**Kiểm tra router**, sau đó **Cài / Cập nhật**. Khi kiểm tra API thành công, app
tự mở `http://<router>/sbproxy/`.

Ứng dụng không lưu password SSH. Khi cập nhật, các file SSID, proxy pool và
settings hiện có được giữ nguyên; Wi-Fi không bị apply lại.

## File trong gói

- `sbproxy-web-deployer[.exe]`: ứng dụng cài/cập nhật.
- `sbproxy-update-<version>.tar.gz`: gói update riêng để upload trên Web Console.
- `WEB-DEPLOY.md`: hướng dẫn cài và sử dụng đầy đủ.
- `SHA256SUMS`: checksum kiểm tra file sau khi copy/download.

Windows kiểm tra checksum bằng `Get-FileHash <file> -Algorithm SHA256`. Linux
dùng `sha256sum -c SHA256SUMS`.
