# Contributing

## Cấu trúc dự án
```
config/     wifi-socks.conf(.example), settings.sh   # nguồn cấu hình + tunables
scripts/    lib.sh + entrypoints (apply, verify, doctor, clients, kick/ban…)
etc/init.d/ sbproxy                                    # init nạp nft + policy routing
agent/      CGI uhttpd + health daemon (agent LAN)
console/    web/control-panel.html (UI nguồn) + desktop/ (app Tkinter native)
pc/         script quản trị router từ máy Windows/Linux qua SSH
docs/       *.md — tài liệu (Markdown là định dạng duy nhất)
tests/      run-all.sh gọi mọi suite — xem docs/TEST-MATRIX.md
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
make test         # chạy tests/run-all.sh (không cần router; phần cần jq/Tk tự skip)
make lint         # shellcheck (cần cài shellcheck)
make check        # lint + test (giống CI)
```
- **Sửa tài liệu:** sửa trực tiếp `docs/*.md`. Dự án chỉ dùng Markdown, không
  sinh bản HTML.
- Đổi hành vi thì **thêm test** vào đúng suite: generator/POSIX trong
  `tests/run.sh`, console desktop trong `tests/test_desktop_*.py`, Agent CGI
  trong `tests/test_agent.sh`, health daemon trong `tests/test_healthd.sh`.
- Bump `VERSION` và ghi `CHANGELOG.md` cho thay đổi có ảnh hưởng người dùng.

## Commit
- Một commit = một thay đổi mạch lạc; mô tả *tại sao*, không chỉ *cái gì*.
- CI (GitHub Actions + GitLab CI) chạy test + lint trên mỗi push.

## Test trên router thật
Nhiều thứ (TPROXY, hostapd ubus, wifi) chỉ kiểm được trên GL-MT6000 thật.
Sau khi đổi code liên quan router: `sh scripts/apply.sh` → `sh scripts/verify.sh`
→ `sh scripts/doctor.sh`, và các bài client trong `docs/TESTING.md`.
