# sbproxy Web Deployer

Tiện ích Windows tối giản để kiểm tra router, cài/cập nhật sbproxy Web và mở
Web Console. Ứng dụng không có tính năng cấu hình Wi-Fi hoặc proxy.

Các trường có thể chỉnh: router IP/hostname, SSH port, username và password.
Password chỉ giữ trong bộ nhớ của phiên chạy, không ghi xuống đĩa.

Chạy từ mã nguồn:

```powershell
.\run.ps1
```

Build file độc lập:

```powershell
.\build.ps1
```

Kết quả: `dist\sbproxy-web-deployer.exe`. File `.exe` đã chứa gói router nên
máy đích không cần Git, Python hay mã nguồn; chỉ cần Windows OpenSSH và kết nối
LAN tới router.

Khi router chưa cài, ứng dụng chạy đủ các bước khởi tạo. Khi router đã cài,
ứng dụng giữ nguyên SSID, pool và settings, chỉ cập nhật code/web/agent và
không apply lại Wi-Fi. Sau khi Agent API trả lời đúng, ứng dụng mở
`http://<router>/sbproxy/`.
