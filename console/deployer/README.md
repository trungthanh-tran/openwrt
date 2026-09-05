# sbproxy Web Deployer

Tiện ích Windows/Linux tối giản để kiểm tra router, cài/cập nhật sbproxy Web và mở
Web Console. Ứng dụng không có tính năng cấu hình Wi-Fi hoặc proxy.

Các trường có thể chỉnh: router IP/hostname, SSH port, username và password.
Password chỉ giữ trong bộ nhớ của phiên chạy, không ghi xuống đĩa.

Chạy từ mã nguồn:

```powershell
.\run.ps1
```

Build executable Windows độc lập:

```powershell
.\build.ps1
```

Kết quả: `dist\sbproxy-web-deployer.exe`. Linux dùng `sh build.sh` và nhận
`dist/sbproxy-web-deployer`. Executable đã chứa gói router nên máy đích không
cần Git, Python hay mã nguồn; chỉ cần OpenSSH client và kết nối LAN tới router.

Khi router chưa cài, ứng dụng chạy đủ các bước khởi tạo. Khi router đã cài,
ứng dụng giữ nguyên SSID, pool và settings, chỉ cập nhật code/web/agent và
không apply lại Wi-Fi. Sau khi Agent API trả lời đúng, ứng dụng mở
`http://<router>/sbproxy/`.

Hướng dẫn người dùng kèm ảnh: [docs/WEB-DEPLOYER.md](../../docs/WEB-DEPLOYER.md).

## Gói phát hành mang sang máy khác

Mỗi hệ điều hành có đúng một gói chính, đã kèm app, router update package,
checksum và tài liệu:

```powershell
# Windows x64 -> một standalone .exe và một gói .zip đầy đủ
.\package-windows.ps1
```

```sh
# Linux -> dist/release/...linux-<arch>.tar.gz
sh package-linux.sh
```

File standalone Windows chạy trực tiếp. Với gói ZIP/TAR.GZ, người dùng phải giải
nén trước khi chạy. Xem [tổ chức gói deploy](../../docs/RELEASE-ARTIFACTS.md).
