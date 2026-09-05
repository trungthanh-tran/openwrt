# Gói deploy và release

Người dùng chỉ cần tải **một gói đúng hệ điều hành**, giải nén rồi chạy. Không
cần clone repository, cài Python hay tự tìm từng file rời.

| Hệ điều hành | Gói tải về | Chương trình chạy |
|---|---|---|
| Windows x64 | `sbproxy-web-deploy-<version>-windows-x64.zip` | `sbproxy-web-deployer.exe` |
| Linux | `sbproxy-web-deploy-<version>-linux-<arch>.tar.gz` | `sbproxy-web-deployer` |

`<arch>` hiện là `x86_64`, `arm64`, hoặc kiến trúc thực tế của máy build. Binary
PyInstaller không chạy chéo hệ điều hành hoặc kiến trúc.

## Nội dung thống nhất trong mỗi gói

```text
sbproxy-web-deploy-<version>-<platform>/
├── sbproxy-web-deployer[.exe]       # kiểm tra, cài/update, mở Web Console
├── sbproxy-update-<version>.tar.gz  # upload thủ công qua mục Cập nhật trên web
├── README.md                        # bắt đầu nhanh
├── WEB-DEPLOY.md                    # tài liệu cài và sử dụng đầy đủ
├── LICENSE
└── SHA256SUMS                       # checksum các file bên trong
```

Executable đã nhúng cùng router payload, vì vậy file update rời không bắt buộc
khi cài bằng app. File `sbproxy-update-*.tar.gz` được kèm để cập nhật thủ công
trên Web Console hoặc kiểm tra/lưu trữ độc lập.

## Build tại máy phát triển

Windows x64:

```powershell
.\console\deployer\package-windows.ps1
```

Linux:

```sh
sh console/deployer/package-linux.sh
```

Kết quả đều vào `dist/release/`. Script dừng nếu `VERSION` sai định dạng, build
executable thất bại hoặc không tạo được router update package. Cả version ổn định
(`1.2.3`) và bản phát triển (`1.2.3-SNAPSHOT`) đều build được.

## Kiểm tra trước khi phát hành

Windows:

```powershell
Expand-Archive .\dist\release\sbproxy-web-deploy-*-windows-x64.zip .\check
Get-Content .\check\sbproxy-web-deploy-*\SHA256SUMS
Get-FileHash .\check\sbproxy-web-deploy-*\sbproxy-web-deployer.exe -Algorithm SHA256
```

Linux:

```sh
tar xzf dist/release/sbproxy-web-deploy-*-linux-*.tar.gz -C /tmp
cd /tmp/sbproxy-web-deploy-*-linux-*
sha256sum -c SHA256SUMS
./sbproxy-web-deployer --self-test
```

Windows EXE cũng hỗ trợ `--self-test`. Vì là ứng dụng windowed, có thể kiểm tra
exit code bằng PowerShell `Start-Process -Wait -PassThru`.

## GitHub Release

Workflow `.github/workflows/deploy-release.yml` build Windows ZIP và Linux
TAR.GZ riêng trên runner đúng hệ điều hành. `workflow_dispatch` tạo artifact để
kiểm tra nhưng không publish. Khi push tag `v<version>` hoặc `<version>`, tag
phải khớp chính xác với file `VERSION`; sau khi cả hai build thành công, workflow
đính kèm hai gói vào cùng một GitHub Release.
