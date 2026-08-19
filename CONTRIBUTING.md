# Contributing

## Cấu trúc dự án
```
config/     wifi-socks.conf(.example), settings.sh   # nguồn cấu hình + tunables
scripts/    lib.sh + entrypoints (apply, verify, doctor, clients, kick/ban…)
etc/init.d/ sbproxy                                    # init nạp nft + policy routing
agent/      CGI uhttpd + health daemon (agent LAN)
console/    web/control-panel.html (UI nguồn) + desktop/ (đóng gói .exe)
pc/         script quản trị router từ máy Windows/Linux qua SSH
docs/       *.md (nguồn) -> *.html (sinh bằng tools/build-docs.js)
tests/      run.sh — unit test POSIX sh cho lib.sh
tools/      build-docs.js
```

## Ràng buộc code
- **Shell = POSIX sh cho BusyBox ash** (không dùng bashism: mảng, `[[ ]]`,
  `local` tùy tiện…). Script chạy trên OpenWrt.
- **Line ending = LF** (xem `.gitattributes`/`.editorconfig`) — CRLF làm hỏng
  shebang trên router.
- Word-splitting cố ý phải chú thích `# shellcheck disable=SCxxxx` tại chỗ.
- **Không commit bí mật**: `wifi-socks.conf` thật, token, backup — đã có trong
  `.gitignore`. Chỉ commit `*.example`.

## Quy trình
```sh
make test         # chạy tests/run.sh (không cần router; phần cần jq tự skip)
make lint         # shellcheck (cần cài shellcheck)
make docs         # sinh lại docs/*.html sau khi sửa docs/*.md
make check        # lint + test + docs-check (giống CI)
```
- **Sửa tài liệu:** chỉ sửa `docs/*.md`, rồi `make docs`. **Đừng** sửa tay
  `docs/*.html` — CI kiểm tra chúng khớp nguồn và sẽ fail nếu lệch.
- Thêm/sửa hành vi generator (`lib.sh`) thì **thêm test** trong `tests/run.sh`.
- Bump `VERSION` và ghi `CHANGELOG.md` cho thay đổi có ảnh hưởng người dùng.

## Commit
- Một commit = một thay đổi mạch lạc; mô tả *tại sao*, không chỉ *cái gì*.
- CI (GitHub Actions + GitLab CI) chạy test + lint + docs-check trên mỗi push.

## Test trên router thật
Nhiều thứ (TPROXY, hostapd ubus, wifi) chỉ kiểm được trên GL-MT6000 thật.
Sau khi đổi code liên quan router: `sh scripts/apply.sh` → `sh scripts/verify.sh`
→ `sh scripts/doctor.sh`, và các bài client trong `docs/TESTING.md`.
