# Kế hoạch: nhiều proxy trên một SSID + đổi proxy hàng loạt theo thiết bị

Trạng thái: **đề xuất, chưa code**. Nền: 0.4.13-SNAPSHOT.
Phần sinh cấu hình đã chạy thử — bằng chứng ở [phụ lục A](#phụ-lục-a-kết-quả-đã-chạy-thử).

**Phần cứng chuẩn để phát triển và chốt limit là GL‑MT6000 (Flint 2):** MediaTek
MT7986AV 4 nhân Cortex-A53 2 GHz, RAM DDR4 1 GiB, eMMC 8 GiB, hai radio Wi‑Fi 6
4×4 (2.4/5 GHz). Các router OpenWrt khác vẫn được phép chạy khi
`ALLOW_UNSUPPORTED_BOARD=1`, nhưng không được thừa hưởng limit của Flint 2 nếu chưa
calibration trên đúng model.

## 1. Mục tiêu

1. **Một SSID mang nhiều proxy** (SOCKS5 và HTTP lẫn lộn được). Thiết bị vào Wi-Fi
   được **chọn ngẫu nhiên một proxy** trong pool và **giữ nguyên** proxy đó.
2. **Đổi proxy hàng loạt**: chọn một nhóm thiết bị đang kết nối, dán vào một danh
   sách proxy, hệ thống **chia đều** thiết bị cho proxy.

Ràng buộc xuyên suốt: **SSID chỉ có một proxy thì đầu ra phải giống hệt hôm nay,
từng byte.** Mọi code mới nằm sau nhánh "pool có ≥1 phần tử", nên bản đang chạy
không đổi hành vi khi nâng cấp.

**Quy mô phải nhắm tới:** thị trường công bố từ **30 thiết bị/32 SSID trên H3000** tới
**200–300 thiết bị trên dòng mini-PC**, mỗi thiết bị một proxy riêng. Đây là claim của
các model khác nhau nên phải benchmark riêng, nhưng thiết kế không được chết ở vài
chục. Xem [B.1](#b1-genrouter--đối-thủ-trực-tiếp) — đây là lý do quyết định D2 được
viết lại so với bản plan đầu.

## 2. Các quyết định thiết kế

| # | Quyết định | Vì sao | Đã kiểm chứng? |
|---|---|---|---|
| D1 | Mỗi proxy = một *slot* = một cổng TPROXY riêng + một outbound sing-box riêng | Gán thiết bị chỉ còn là việc của nftables, không phải sinh lại config | ✅ chạy thử, [A.1](#a1-sinh-cấu-hình-sing-box) |
| **D2** | nftables chọn cổng bằng **map `ipv4_addr : inet_service` có khai báo `size`** — IP nguồn → thẳng cổng của proxy | Một luật, một lần tra băm; khoá 4 byte lấy được backend nhanh nhất của nhân; tránh luôn câu hỏi đọc header L2. Gán = `nft add element`, không restart | ⚠️ phải spike; xem [3.6](#36-thuật-toán-tra-bảng) |
| D2a | Nếu map trong đối số cổng của `tproxy` không parse → quay về **một set cho mỗi slot** | Cú pháp chắc chắn chạy, nhưng tuyến tính theo số slot | — |
| D2b | Khoá thay thế: `ether_addr` / `ether saddr` | Sống sót khi IP đổi, nhưng khoá 6 byte nên chậm hơn một bậc backend, và phụ thuộc header L2 ở `inet prerouting` | — |
| **D9** | **Chèn luật `socket transparent` ở đầu prerouting** ("divert" trong tài liệu kernel) | Chuyển việc tra bảng từ **mỗi gói** sang **mỗi kết nối** — đổi bản chất bài toán, và làm nhanh cả bản đang chạy | ✅ mẫu chuẩn của kernel |
| D3 | **Một chain nft riêng cho mỗi SSID**, vào chain bằng `iifname vmap` | Chain phẳng hiện tại đã chậm; thêm pool vào sẽ chậm hẳn | ✅ đếm luật, [9](#9-hiệu-năng) |
| D4 | Elements của map **ghi thẳng vào file nft sinh ra** | `init.d/sbproxy restart` xoá cả bảng; đây là cách khôi phục atomic | ✅ đọc code |
| D5 | Ghim thiết bị bằng **móc DHCP** (v1), daemon quét là lưới an toàn | Móc DHCP bắn trước mọi lưu lượng ứng dụng; chỉ quét thì hở ~3 giây | — |
| D6 | Ghim **dính**: một thiết bị giữ nguyên proxy qua các lần vào lại | IP ra ngoài nhảy liên tục làm hỏng phiên đăng nhập | ✅ prior art |
| D7 | Failover dùng outbound **`urltest`** của sing-box | Cơ chế native, khỏi tự viết logic dò sống-chết | ✅ tài liệu |
| D8 | **Không** dùng `selector` + Clash API | Việc nó giải quyết thì map nft đã làm miễn phí; việc nó không giải quyết thì vẫn phải restart | ✅ tài liệu, [B.4](#b4-đã-cân-nhắc-và-loại-selector--clash-api) |
| **D10** | GL‑MT6000 có **profile limit chuẩn**; model OpenWrt khác dùng profile riêng hoặc fallback bảo thủ | Limit chính xác cần benchmark theo CPU/RAM/sing-box, nhưng vẫn phải co lại theo RAM/overlay khả dụng tại thời điểm apply | ⚠️ phải đo ở P1; xem [3.5](#35-tự-tính-ram-bộ-nhớ-và-trần-pool) |
| **D12** | Chưa có profile khớp thì `POOL_TOTAL_SLOTS_MAX="auto"` **hạ trần xuống 32**, không từ chối chạy. Trần thấp đi; **danh sách proxy không bao giờ bị cắt** | Router lạ vẫn dùng được ngay mà không phải hiệu chuẩn trước; 32 là mức đã qua soak test ở mọi cấu hình. Việc "vượt trần" vẫn do `apply.sh` chặn nên không có đường nào âm thầm mất proxy | — |
| **D11** | Thiết bị chưa gán/proxy chết có policy rõ: `auto`, `block` hoặc `default`; triển khai phone-farm mặc định `auto`, **không fail-open cả nhóm vào một IP** | Fallback im lặng sang proxy mặc định có thể liên kết hàng loạt tài khoản — đúng failure mode sản phẩm này phải ngăn | — |

## 3. Kiến trúc

### 3.1 Đường dữ liệu

Hôm nay là **một Wi-Fi ↔ một proxy**, cứng từ đầu tới cuối:

```
br-w<idx> --nft prerouting--> tproxy :12000+idx --sing-box--> out-w<idx> --> proxy
```

Sau khi có pool:

```
                        +--> :13032 (slot 0)  --> out-w1-s0 --> proxy A
br-w1 --> chain w1 -----+--> :13033 (slot 1)  --> out-w1-s1 --> proxy B
   (tra IP nguồn map)   +--> …
                        +--> :12001 (mặc định)--> out-w1    --> proxy trong wifi-socks.conf
```

Thiết bị **chưa được ghim** không khớp map. Với SSID không có pool, nó vẫn đi proxy
trong `wifi-socks.conf` đúng hành vi cũ. Với SSID có pool, chain áp D11: chuyển sang
nhánh auto-assign, block (kill switch), hoặc proxy mặc định theo cấu hình. Phone-farm
không được fail-open im lặng nhiều máy vào cùng một IP.

Chỗ phải sửa:

- [scripts/lib.sh:135](scripts/lib.sh#L135) `tproxy_port()` — thêm `pool_port()`.
- [scripts/lib.sh:383](scripts/lib.sh#L383) `build_singbox()` — sinh inbound/outbound theo slot.
- [scripts/lib.sh:475](scripts/lib.sh#L475) `build_nft()` — tái cấu trúc chain, sinh map.

### 3.2 Chain nftables

```
chain prerouting {
  type filter hook prerouting priority mangle; policy accept;
  # D9 — gói của luồng TCP đã lập thoát ngay tại đây, không đụng tới bảng nào bên dưới.
  meta l4proto tcp socket transparent 1 meta mark set 1 accept
  iifname vmap { "br-w1" : jump w1, "br-w2" : jump w2 }
}

map w1map { type ipv4_addr : inet_service
            size 512
            elements = { 192.168.11.23 : 13032, 192.168.11.24 : 13033 } }

chain w1 {
  meta l4proto { tcp, udp } th dport 53 tproxy ip to :12001 meta mark set 1 accept
  ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
  ip daddr @proxy_hosts return
  udp dport 443 drop
  meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w1map meta mark set 1 accept
  meta l4proto { tcp, udp } tproxy ip to :12001 meta mark set 1 accept
}
```

Năm điểm:

- **`socket transparent` (D9) là thứ quan trọng nhất trong khối này.** Nó là mẫu
  "divert" trong tài liệu TPROXY của kernel, và `build_nft()` hôm nay **đang thiếu**.
  Xem [3.6](#36-thuật-toán-tra-bảng).
- `iifname vmap` là **tra bảng băm O(1)**; gói chỉ duyệt luật của đúng SSID mình.
- **Luật ghim là một luật duy nhất, chi phí không đổi** dù có 8 hay 800 proxy, 10 hay
  300 thiết bị. Đây là điều kiện để chạm được quy mô ở [mục 1](#1-mục-tiêu).
- Map miss thì luật không khớp và rơi xuống luật mặc định — đúng hành vi cần.
- Gộp `tcp`/`udp` và `tcp/udp dport 53` thành một luật mỗi loại; danh sách proxy host
  thành một set `@proxy_hosts` thay vì một luật `ip daddr … return` cho mỗi host.

**DNS vẫn đi cổng cũ `12000+idx`, không nhân bản theo slot.** Kho fake-IP thuộc về cả
tiến trình sing-box và `reverse_mapping` tra ngược lúc kết nối, nên gói vào bằng
inbound nào cũng ra đúng hostname.

Nếu spike cho thấy map không dùng được trong đối số cổng (D2a), thay luật ghim bằng
một luật cho mỗi slot (`ether saddr @w1s0 … :13032`). Chạy đúng, nhưng tuyến tính theo
số slot nên bộ tính tài nguyên phải áp thêm một trần bảo thủ cho nhánh fallback này.

### 3.3 Cấp phát cổng

Thêm vào [config/settings.sh](config/settings.sh):

```sh
# Dải cổng TPROXY cho chế độ nhiều proxy trên một SSID.
POOL_PORT_BASE=13000
# Khoảng cổng dành cố định cho mỗi idx; không được đổi theo RAM lúc chạy.
POOL_PORT_STRIDE=256
# auto = tự tính tổng slot an toàn từ RAM/overlay; số nguyên = trần do admin đặt.
POOL_TOTAL_SLOTS_MAX="auto"
# Trần riêng của một SSID, luôn không lớn hơn POOL_PORT_STRIDE.
POOL_SLOTS_PER_SSID_MAX=256
# Luật divert (D9). auto = dùng khi nft của router này chấp nhận; on | off.
POOL_DIVERT="auto"
# Trạng thái ghim: idx|mac|slot|source. Runtime state, cùng loại với BANS_FILE.
ASSIGN_FILE="/etc/sbproxy.assign"
# Sức chứa map ghim của mỗi SSID. Phải khai báo size thì nftables mới chọn bảng
# băm cố định; map không tự lớn quá số này nên đặt rộng hơn dải DHCP.
POOL_MAP_SIZE=512
# Giữ lại ít nhất max(64 MiB, 20% MemTotal) cho kernel, Wi-Fi và tiến trình khác.
POOL_RAM_RESERVE_MIB=64
POOL_RAM_RESERVE_PERCENT=20
# Giữ lại overlay để sysupgrade, log và backup; flash không đủ thì apply bị chặn.
POOL_OVERLAY_RESERVE_MIB=16
# random | round-robin | least-loaded | sticky-hash
POOL_ASSIGN_POLICY="random"
# Nhịp quét lưới an toàn của sbproxy-assignd, giây.
POOL_SCAN_INTERVAL=3
# 1 = bốc proxy mới mỗi lần thiết bị vào lại, thay vì giữ nguyên.
POOL_ROTATE_ON_RECONNECT=0
# 1 = mỗi slot bọc trong urltest [chính, dự phòng] để tự né proxy chết.
POOL_FAILOVER=0
# auto = chỉ gán vào proxy healthy; block = kill switch; default = tương thích hành vi cũ.
POOL_UNASSIGNED_POLICY="auto"
# Số lần probe thành công/thất bại liên tiếp trước khi đổi trạng thái, tránh flapping.
POOL_HEALTH_SUCCESS_THRESHOLD=2
POOL_HEALTH_FAILURE_THRESHOLD=3
```

`pool_port(idx, slot) = POOL_PORT_BASE + idx * POOL_PORT_STRIDE + slot`

`POOL_SHUFFLE_SEED` **không phải một thiết lập** và không nằm trong `settings.sh`: nó
là biến môi trường để bảng xem trước và lần ghi ngay sau đó dùng chung một phép xáo,
và để test lặp lại được kết quả. Bỏ trống thì seed lấy từ `/dev/urandom`.

Tách `POOL_PORT_STRIDE` khỏi trần tự động là bắt buộc: lượng RAM rảnh thay đổi giữa hai
lần apply không được làm đổi cổng của mọi idx. Với idx ≤ 200 và stride 256, cổng lớn nhất
là `64455`, không chạm dải `TPROXY_PORT_BASE` (`12001…12200`). `validate_settings()` phải
**chặn cấu hình làm hai dải chồng nhau**, chặn `POOL_SLOTS_PER_SSID_MAX > POOL_PORT_STRIDE`
và chặn `POOL_PORT_BASE + 200 * POOL_PORT_STRIDE + POOL_PORT_STRIDE - 1 > 65535`.

### 3.4 sing-box

Với mỗi SSID ở chế độ pool, ngoài `in-w<idx>` / `out-w<idx>` như hôm nay:

- inbound `in-w<idx>-s<slot>` nghe `pool_port(idx, slot)`
- outbound `out-w<idx>-s<slot>` (`socks` hoặc `http` tuỳ hàng pool)
- hai route rule: `sniff`, rồi `inbound → outbound`

Khi `POOL_FAILOVER=1`, `out-w<idx>-s<slot>` là một `urltest` bọc
`[proxy của slot, proxy dự phòng]` thay vì trỏ thẳng.

**Đây là chỗ tốn tài nguyên duy nhất tỉ lệ với số proxy** — một inbound cho mỗi slot.
P1 phải đo RAM thật ở các mốc 0/32/64/128/256/300 slot — cùng bộ mốc với ma trận ở
[3.5](#35-tự-tính-ram-bộ-nhớ-và-trần-pool) — để hiệu chuẩn bộ tính ở mục kế tiếp.

### 3.5 Tự tính RAM, bộ nhớ và trần pool

Thêm `scripts/pool-capacity.sh`, chạy read-only trong `preflight.sh` và chạy bắt buộc ngay
trước khi `apply.sh` thay cấu hình. Kết quả phải in cả **tổng slot được yêu cầu**, **trần an
toàn**, tài nguyên nào tạo ra trần và số liệu đầu vào; không chỉ in một con số “đạt/trượt”.

#### Hai tầng hỗ trợ

1. **Tầng chuẩn — GL‑MT6000.** Repo phát hành sẵn profile đã benchmark cho
   `board_name=glinet,gl-mt6000`, kiến trúc `aarch64_cortex-a53` và từng major.minor
   sing-box được hỗ trợ. Đây là model duy nhất được công bố limit chính thức.
2. **Tầng tương thích — OpenWrt model khác.** Vẫn cho chạy khi admin bật
   `ALLOW_UNSUPPORTED_BOARD=1`. Nếu có profile do calibration cục bộ tạo thì tính như
   Flint 2; nếu chưa có thì limit fallback bảo thủ và preflight ghi `UNPROFILED`, tuyệt
   đối không suy ra “cùng 1 GiB RAM thì cùng limit”.

Profile phải khớp ít nhất `board_name`, kiến trúc, major.minor sing-box và chế độ
`POOL_FAILOVER`; failover tạo thêm outbound/urltest nên không dùng chung hệ số với chế
độ thường. Firmware OEM GL.iNet và OpenWrt thuần trên cùng Flint 2 dùng hai baseline
khác nhau nếu RAM nền đo được khác đáng kể.

Không gom mọi thứ thành một biến “limit”. `pool-capacity.sh` phải trả riêng:

| Limit | Nguồn chặn |
|---|---|
| `max_ssids_per_radio` | `iw list` thực tế, sau đó min với `BSSID_LIMIT`; không suy ra từ RAM |
| `max_slots_per_ssid` | `POOL_PORT_STRIDE`, profile và RAM |
| `max_total_slots` | RAM loaded, overlay, FD, cổng và profile soak-test |
| `max_clients_tested` | workload envelope của profile, không đồng nghĩa với số slot |
| `configured_slots` / `active_clients` | dữ liệu cấu hình và station hiện tại để so với các trần trên |

Console/agent hiển thị cả năm giá trị và `limiting_factor`, ví dụ
`RAM_LOADED`, `PROFILE_MAX`, `PORTS`, `FD`, `BSSID` hoặc `UNPROFILED`. Nhờ vậy admin
biết cần giảm proxy, giảm SSID hay calibration, thay vì chỉ nhận lỗi “quá limit”.

#### Nguồn số liệu trên router

- RAM dùng `MemAvailable` trong `/proc/meminfo`, **không dùng `MemFree`**. Kernel cũ không có
  `MemAvailable` thì fallback về `MemFree + Buffers + Cached + SReclaimable - Shmem` và ghi rõ
  đây là ước lượng.
- RAM của sing-box ưu tiên `Rss`/`Pss` từ `/proc/<pid>/smaps_rollup`; fallback `VmRSS` trong
  `/proc/<pid>/status`. Không lấy `VSZ`, vì Go reserve không gian địa chỉ ảo nhưng chưa dùng RAM.
- Bộ nhớ lưu trữ dùng số KiB còn trống của mount `/overlay` (`df -Pk /overlay`); nếu không có
  overlay riêng thì lấy mount chứa `SINGBOX_CONF`. `/tmp` là tmpfs tính vào RAM, không được cộng
  lại như flash.
- Ghi thêm giới hạn cổng, `ulimit -n`, số FD sing-box đang mở và kích thước config sinh thử.
  Đây là các hard limit độc lập với RAM.

#### Hiệu chuẩn chi phí mỗi slot

P1 sinh config 0/32/64/128/256 slot trên GL‑MT6000, `sing-box check`, khởi động, chờ 30 giây
rồi lấy 3 mẫu RSS cách nhau 5 giây. Lấy median từng mốc; tính `slot_idle_ram_kib` bằng **độ dốc
lớn nhất** giữa các mốc liên tiếp. Chạy lại cùng các mốc với một client/slot và workload chuẩn
(DNS + HTTPS giữ kết nối + reconnect burst) để lấy `slot_loaded_ram_kib`. Hệ số dùng tính limit
là `max(idle, loaded)` cộng 25% headroom. Tương tự, lấy chênh lệch kích thước config để có
`slot_overlay_kib`. Lưu hệ số đã đo, workload envelope, phiên bản sing-box và kiến trúc trong
`config/resource-profiles.conf`; không nhúng một con số phỏng đoán vào code.

Limit chỉ có ý nghĩa trong workload envelope đã công bố. Profile Flint 2 phải ghi ít nhất:
`max_clients`, `flows_per_client`, throughput tổng, tỷ lệ TCP reconnect/giây và có/không
`POOL_FAILOVER`. Nếu triển khai vượt một trong các ngưỡng đó, preflight cảnh báo limit RAM không
còn là cam kết; admin phải chọn profile tải cao hơn hoặc calibration lại.

Với model khác hoặc phiên bản sing-box chưa khớp profile, chế độ `auto` lấy fallback:

```text
fallback_total_slots = min(32, slots_by_ports, slots_by_fd)
```

và vẫn bắt buộc kiểm tra reserve RAM/overlay; nếu không đủ cho 32 thì giảm tiếp hoặc
fail. Cảnh báo hướng dẫn chạy `scripts/calibrate-pool.sh` để tạo profile cục bộ. Script
hiệu chuẩn là thao tác chủ động của admin, không tự restart sing-box trên router production.

**Fallback hạ trần, không cắt pool (D12).** Hai việc này phải tách bạch, vì gộp lại là
đúng kiểu lỗi mà [mục 7](#7-việc-dễ-quên-đã-có-tiền-lệ-đau) dặn tránh:

1. Không có profile khớp → `auto` trả về `fallback_total_slots` (tối đa 32) và đặt
   `limiting_factor=UNPROFILED`. Đây là **trần**, không phải một thao tác lên pool.
2. Pool đang cấu hình vượt trần đó → `apply.sh` **fail trước mọi thay đổi**, nêu rõ số
   slot đang yêu cầu, trần 32, lý do `UNPROFILED`, và hai lối ra: chạy
   `calibrate-pool.sh` để có profile thật, hoặc đặt tay một số cho
   `POOL_TOTAL_SLOTS_MAX` và tự chịu trách nhiệm.

Nói cách khác: router lạ vẫn chạy được ngay với ≤32 proxy mà không phải hiệu chuẩn
trước, còn ai muốn vượt 32 thì phải nói rõ ý định. **Không có đường nào khiến một
proxy trong `proxy-pools.conf` biến mất mà người dùng không được báo.**

#### Công thức và hành vi

```text
ram_reserve_kib = max(POOL_RAM_RESERVE_MIB * 1024,
                      MemTotal * POOL_RAM_RESERVE_PERCENT / 100)
ram_budget_kib  = max(0, MemAvailable + current_singbox_rss
                         - ram_reserve_kib - predicted_base_rss - 16 MiB_transient)
slot_ram_kib    = max(slot_idle_ram_kib, slot_loaded_ram_kib) * 1.25
slots_by_ram    = floor(ram_budget_kib / slot_ram_kib)

overlay_budget_kib = max(0, overlay_available_kib
                            - POOL_OVERLAY_RESERVE_MIB * 1024 - generated_base_kib)
slots_by_overlay = floor(overlay_budget_kib / slot_overlay_kib)

safe_total_slots = min(slots_by_ram, slots_by_overlay, slots_by_ports, slots_by_fd)
```

Trên GL‑MT6000, giá trị cuối cùng còn bị chặn bởi `flint2_profile_max_slots` — con số
cao nhất đã vượt qua toàn bộ soak test — dù công thức RAM cho ra cao hơn. Do đó:

```text
effective_limit_gl_mt6000 = min(safe_total_slots, flint2_profile_max_slots,
                                configured_numeric_cap_if_any)
effective_limit_other    = min(safe_total_slots, local_profile_max_or_32,
                                configured_numeric_cap_if_any)
```

Không dùng toàn bộ 1 GiB làm ngân sách: `MemAvailable` đã phản ánh firmware, Wi‑Fi,
page cache và dịch vụ đang chạy. 8 GiB eMMC khiến overlay hiếm khi là bottleneck,
nhưng vẫn giữ nó trong phép `min` để bắt trường hợp phân vùng đầy hoặc firmware chia
overlay khác dự kiến.

`current_singbox_rss` được cộng lại vì tiến trình cũ sẽ bị thay khi apply; `predicted_base_rss`
và 16 MiB transient được trừ để không đánh giá hai lần hoặc sát mép OOM. Sau đó lấy min với
`POOL_SLOTS_PER_SSID_MAX` cho từng SSID. Nếu admin đặt một số cho `POOL_TOTAL_SLOTS_MAX`, đó là
**trần bổ sung**, không được phép vượt `safe_total_slots` trừ khi có cờ override riêng và cảnh
báo lớn. Pool đang cấu hình vượt trần thì `apply.sh` phải fail trước mọi thay đổi; không âm thầm
cắt danh sách proxy.

Sau khi restart, đợi 30 giây và kiểm tra lại `MemAvailable`, RSS và số listener. Nếu RAM dự phòng
bị xâm phạm thì rollback config vừa apply. Daemon chỉ cảnh báo khi RAM giảm trong lúc chạy, không
tự xoá slot hay restart vì hành vi đó sẽ làm đứt kết nối và có thể tạo vòng lặp restart.

#### Ma trận chốt limit cho GL‑MT6000

Chạy cả OpenWrt thuần và firmware GL.iNet được hỗ trợ, mỗi trường hợp ít nhất 30 phút và
soak 24 giờ ở limit dự kiến:

| Tổng slot/client | Phân bố SSID | Workload |
|---:|---|---|
| 32 | 1×32, 8×4 | idle, DNS/HTTPS, reconnect burst |
| 64 | 1×64, 8×8, 16×4 | như trên |
| 128 | 1×128, 8×16, 16×8 | như trên |
| 256 | 1×256, 8×32, 16×16 | như trên |
| 300 | nhiều SSID, mỗi SSID ≤256 | như trên; mục tiêu cạnh tranh, không mặc định là đạt |

Một mốc chỉ được ghi thành `flint2_profile_max_slots` khi: không OOM/restart, reserve RAM không
bị xuyên thủng, listener đủ, assignment đúng, không rò DNS/WebRTC, p95 latency/reconnect và CPU
nằm trong ngưỡng ghi trong profile. Nếu 300 không đạt thì công bố đúng mốc thấp hơn; không hạ
reserve để làm đẹp con số.

### 3.6 Thuật toán tra bảng

Câu hỏi "bảng nào nhanh nhất" có ba tầng trả lời, và **tầng 1 làm hai tầng còn lại
gần như không còn quan trọng**.

#### Tầng 1 — đừng tra bảng mỗi gói (D9)

Tài liệu TPROXY của kernel mô tả một chain **"divert"**: gói nào đã thuộc về một
socket transparent đang mở thì đánh dấu và cho đi luôn, không cần chạy lại toàn bộ
luật phân loại.

```
meta l4proto tcp socket transparent 1 meta mark set 1 accept
```

`build_nft()` hôm nay **không có luật này**, nên mọi gói của mọi luồng đều chạy lại
đủ chuỗi luật và câu lệnh `tproxy`. Thêm vào thì:

- Việc tra map chỉ còn xảy ra **một lần cho mỗi kết nối** (gói SYN), thay vì mỗi gói.
- Chi phí mỗi gói của luồng đã lập rút còn **một luật + một lần tra bảng socket**.
- **Bản đang chạy cũng nhanh lên**, không cần có pool.

Chỉ áp cho **TCP**. Với UDP, socket của sing-box nghe `0.0.0.0:port` còn đích của gói
là một IP Internet nên tra socket không khớp; mà UDP qua pool cũng bị outbound SOCKS
`"network":"tcp"` bỏ, nên không mất gì.

Cần applet/kmod `nft_socket` — `install-deps.sh` cài, `preflight.sh` kiểm. Không có
thì **bỏ qua luật này**, không mất tính đúng đắn, chỉ mất tốc độ.

**Hệ quả về hành vi, phải ghi vào tài liệu:** khi đã có divert, đổi proxy **không còn
làm gãy kết nối TCP đang mở** — chúng chạy tiếp trên proxy cũ tới khi ứng dụng tự
đóng. Muốn cắt ngay thì dùng `kick.sh` sẵn có để đá thiết bị ra và cho vào lại.

#### Tầng 2 — chọn khoá và kiểu bảng cho đúng backend

nftables tự chọn cấu trúc dữ liệu theo khoá và cờ của set/map:

| Backend | Tra cứu | Chọn khi |
|---|---|---|
| `nft_set_hash_fast` | O(1), băm cố định | khoá **đúng 4 byte** và **có khai báo `size`**, không `timeout`/`eval` |
| `nft_set_hash` | O(1), băm tổng quát | có `size`, khoá khác 4 byte |
| `nft_set_rhash` | O(1), hashtable co giãn | **không khai báo `size`**, hoặc có `timeout` |
| `nft_set_bitmap` | O(1), chỉ số trực tiếp | khoá ≤ 2 byte |
| `nft_set_rbtree` | O(log N) | set khoảng (`flags interval`) |
| `nft_set_pipapo` | O(log N) | khoảng nhiều chiều |

Rút ra hai điều cụ thể, cả hai đã đưa vào D2:

1. **Khoá IPv4 = 4 byte → `hash_fast`. Khoá MAC = 6 byte → `hash` thường.** Đây là lý
   do chính khiến D2 đổi sang khoá IP; lý do phụ là tránh hẳn câu hỏi header L2 có
   đọc được ở `inet prerouting` không.
2. **Phải khai báo `size` trên map.** Không khai báo thì rơi vào `rhash` co giãn,
   chậm hơn. Đổi lại backend cố định **không tự lớn**, nên `size` phải rộng rãi
   (mặc định 512, tức gấp đôi dải DHCP một /24) và `build_nft()` phải sinh kèm.
   **Không đặt `timeout`** trên map này — nó ép về `rhash`.

Định danh trong `/etc/sbproxy.assign` **vẫn là MAC** (ổn định, người đọc hiểu được);
chỉ *khoá của map nft* là IP. Móc DHCP ở [5.1](#51-thiết-bị-mới-vào-wi-fi) vốn đã
bắn mỗi khi lease đổi, nên nó cập nhật map luôn — IP đổi không làm mất ghim.

#### Tầng 3 — những thứ không đáng đổi

- **`jhash`/`numgen` không bảng.** Tính slot thẳng từ IP, O(1), không tốn bộ nhớ —
  nhưng **không ghi đè được cho từng máy**, mà đó chính là tính năng 2. Vẫn dùng được
  làm *luật mặc định* cho máy chưa ghim, để chúng trải đều thay vì dồn hết vào một
  proxy. Tuỳ chọn, phải thử nft có hỗ trợ.
- **Cache bằng `ct mark`.** Phân loại một lần rồi ghi cổng vào `ct mark`, các gói sau
  đọc lại. Đúng hướng, nhưng D9 đã giải quyết cùng vấn đề theo cách sạch hơn và được
  kernel khuyến nghị. Thừa.
- **eBPF/XDP + BPF hash map.** Tra cứu nhanh hơn nữa, nhưng TPROXY bắt buộc nằm ở
  netfilter nên XDP không thay thế được, và sau D9 thì tra bảng đã là chi phí mỗi kết
  nối chứ không phải mỗi gói. Thêm một phụ thuộc lớn để tối ưu thứ không còn nóng.
- **`nft_set_bitmap`.** Nhanh nhất về lý thuyết (chỉ số trực tiếp) nhưng khoá tối đa
  2 byte. Có thể ép bằng cách chỉ lấy octet cuối của IP, nhưng như thế là trói cả
  thiết kế vào một /24 cho mỗi SSID để đổi lấy vài ns của một phép tra đã hết nóng.
  Không đáng.

## 4. Cấu hình và trạng thái

### 4.1 `config/proxy-pools.conf` — nguồn sự thật của pool

Cùng phong cách `|` như phần còn lại của dự án:

```
# idx|proxy_type|host|port|user|pass|label
1|socks5|1.2.3.4|1080|u1|p1|VN-01
1|http|5.6.7.8|8080|||US-02
```

- **slot = thứ tự xuất hiện của hàng trong cùng idx**, đánh số từ 0.
- File không tồn tại, hoặc idx không có hàng nào → SSID đó chạy y như hôm nay.
- 4 cột proxy trong `wifi-socks.conf` giữ nguyên vai trò tương thích. Khi SSID không có
  pool, hành vi vẫn giống hệt hiện tại. Khi có pool, thiết bị chưa ghim tuân theo
  `POOL_UNASSIGNED_POLICY`: tự gán vào slot healthy, bị chặn, hoặc mới dùng proxy mặc định.
- `label` chỉ để hiển thị trên console.

File chứa **mật khẩu proxy** nên phải đối xử đúng như `wifi-socks.conf`: `.gitignore`,
quyền 0600, redact trong log, có trong [scripts/backup.sh](scripts/backup.sh), bị xoá
bởi [scripts/uninstall.sh](scripts/uninstall.sh), và
[scripts/self-update.sh](scripts/self-update.sh) tạo file rỗng kèm comment mô tả cột
nếu chưa có (như đã làm cho `wifi-socks.conf` ở 0.4.11).

### 4.2 `/etc/sbproxy.assign` — trạng thái ghim

Runtime state, sống cùng `/etc/sbproxy.bans`:

```
idx|mac|slot|source        # source = auto | manual
```

[etc/init.d/sbproxy](etc/init.d/sbproxy) `restart` chạy `nft delete table inet sbproxy`
rồi nạp lại, tức **mọi lần apply/set-sock/restart đều xoá sạch nội dung map**. Vì vậy
`build_nft()` **ghi thẳng `elements = { … }` vào file sinh ra** (D4): trạng thái được
khôi phục atomic cùng lúc với bảng, không cần bước nạp lại riêng, không có khe hở giữa
hai lệnh. Thay đổi lúc chạy vẫn dùng `nft add element`, và file được sinh lại để lần
restart sau giữ nguyên kết quả.

**Chống đua:** nếu daemon gọi `nft add element` đúng lúc bảng vừa bị xoá thì element
mất. Không dùng khoá — cho daemon **tự chữa lành**: khi `add element` thất bại, hoặc
khi số phần tử trong map khác `/etc/sbproxy.assign`, thì nạp lại toàn bộ map từ file.

Khi pool co lại, mọi ghim trỏ vào slot không còn tồn tại được **gán lại tự động** theo
policy và ghi rõ trong log — không im lặng bỏ qua.

## 5. Gán proxy cho thiết bị

### 5.1 Thiết bị mới vào Wi-Fi

**Móc DHCP là đường chính (v1, không để phase sau).** `option dhcpscript` của dnsmasq
gọi script ngay khi cấp lease — **trước mọi lưu lượng ứng dụng** — nên khe hở gần như
bằng 0:

- `/usr/libexec/sbproxy-dhcp-assign add|old|del <mac> <ip> <host>` → chọn slot,
  ghi state, `nft add element`.
- Nếu người dùng đã đặt `dhcpscript` khác, **preflight cảnh báo và không ghi đè**.

**Daemon `sbproxy-assignd` là lưới an toàn**, dựng theo khuôn `sbproxy-healthd` đã có:
mỗi `POOL_SCAN_INTERVAL` giây đọc `iw dev … station dump`, tìm MAC chưa có trong file
state (máy đặt IP tĩnh không hề xin DHCP), và tự chữa lành map theo mục 4.2.

Chọn trong **các slot healthy** theo `POOL_ASSIGN_POLICY`: `random` (mặc định — bốc
ngẫu nhiên rồi dính luôn), `round-robin`, `least-loaded`, `sticky-hash` (băm MAC;
cùng máy luôn ra cùng proxy kể cả sau khi xoá state). Không còn slot healthy thì áp
`POOL_UNASSIGNED_POLICY`; console phải hiện trạng thái đỏ, không được fallback im lặng.

Nguồn ngẫu nhiên: `seed=$(head -c 8 /dev/urandom | cksum | cut -d" " -f1)` rồi
`awk 'BEGIN{srand(seed); …}'`. **Không dùng `hexdump`/`od`** — đó chính là applet đã
làm hỏng self-update ở 0.4.10, nhiều image OpenWrt không build vào.

### 5.2 Chia đều theo danh sách dán

Cho M thiết bị được chọn và N proxy đã dán:

1. Xáo trộn danh sách thiết bị bằng seed ngẫu nhiên — "đều" nhưng không đoán được.
2. Chia bài: thiết bị thứ `j` → slot `j mod N`.

Số thiết bị trên mỗi proxy chênh nhau tối đa 1. Trường hợp **N ≥ M** (mỗi máy một
proxy riêng — đúng cách dùng phổ biến của thị trường) rơi ra tự nhiên: mỗi máy nhận
một slot khác nhau, các slot thừa không ai dùng. Đây là hàm thuần, tách riêng, test
bằng bảng (M = 0, 1, 7, 300; N = 1, 3, 8, 32, 300; M<N; M=N).

**Dán danh sách = thay toàn bộ pool của SSID đó.** Proxy trùng với cái đang có giữ
nguyên slot, để những máy không được chọn không bị đổi proxy oan.

**Kết nối đang mở xử lý thế nào** phụ thuộc D9:

- **Có luật divert** (mặc định): kết nối TCP đang mở **chạy tiếp trên proxy cũ** tới
  khi ứng dụng tự đóng; chỉ kết nối mới dùng proxy mới. Êm, không có lỗi hiện ra màn
  hình thiết bị.
- **Muốn cắt ngay**: thêm tuỳ chọn *"Ngắt thiết bị để áp dụng ngay"* trong hộp thoại,
  dùng `kick.sh` sẵn có để deauth — máy vào lại là dùng proxy mới từ gói đầu tiên.
- **Không có luật divert**: gói tiếp theo đã đi sang cổng TPROXY khác nên kết nối cũ
  gãy ngay. Có `conntrack` thì gọi thêm `conntrack -D -s <ip>` cho sạch.

### 5.3 Failover

`healthd` probe độc lập từng endpoint và lưu trạng thái runtime
`unknown | healthy | degraded | dead`, kèm latency, lần kiểm tra cuối và lỗi đã redact.
Chỉ chuyển trạng thái sau `POOL_HEALTH_SUCCESS_THRESHOLD` lần thành công liên tiếp,
hoặc `POOL_HEALTH_FAILURE_THRESHOLD` lần thất bại liên tiếp, để tránh flapping. Proxy `dead`
không nhận thiết bị mới; thiết bị đang ghim không bị tự chuyển giữa phiên trừ khi admin
bật policy failover cho SSID đó.

`POOL_FAILOVER=1` → mỗi slot là một `urltest` bọc `[proxy chính, proxy dự phòng]`,
sing-box tự né node chết cho kết nối mới. Cần ghi rõ đây là **failover endpoint**, không
phải giữ danh tính tuyệt đối: IP public có thể đổi khi proxy chính chết. Chế độ danh tính
nghiêm ngặt dùng kill switch (`block`) thay vì dự phòng. Console có nút probe lại và thao
tác “chuyển các thiết bị trên proxy chết”, luôn có preview trước khi commit.

## 6. Giao diện

### 6.1 Agent API

| Action | Method | Body / query | Việc |
|---|---|---|---|
| `get_pool` | GET | `idx` | `{proxies:[{slot,type,host,port,user,pass,label}], assignments:[…]}` |
| `save_pool` | POST | `{idx, proxies:[…]}` | validate → ghi file → dựng lại sing-box + nft → restart → gán lại slot mồ côi |
| `assign_proxy` | POST | `{idx, assignments:[{mac,slot}]}` | đổi một/vài máy, **chỉ cập nhật map nft**, không restart |
| `rebalance` | POST | `{idx, macs:[…], proxies:[…], shuffle}` | atomic: thay pool rồi chia đều — chính là tính năng 2 |
| `capacity` | GET | — | kết quả `pool-capacity.sh`: năm trần ở [3.5](#35-tự-tính-ram-bộ-nhớ-và-trần-pool), `limiting_factor`, và **số liệu đầu vào** (MemAvailable, RSS, overlay, FD, profile đã khớp hay `UNPROFILED`) |
| `pool_health` | GET | `idx?` | trạng thái từng endpoint: `unknown\|healthy\|degraded\|dead`, latency, lần probe cuối, lỗi đã redact |
| `probe_pool` | POST | `{idx, slot?}` | ép probe lại ngay, bỏ qua nhịp của `healthd` |

Thao tác *"chuyển các thiết bị trên proxy chết"* ở [5.3](#53-failover) **không cần action
riêng**: console đọc `pool_health`, lọc thiết bị trên slot `dead`, rồi gọi `rebalance` với
đúng danh sách MAC đó. Giữ bề mặt API nhỏ, và preview vẫn dùng chung một đường code.

Mở rộng action sẵn có:

- `clients` trả thêm `slot`, `proxy_label`, `proxy_host`, `proxy_state` cho từng thiết bị.
- `status.meta` trả thêm `pool_port_base`, `pool_port_stride`, **cả năm trần và
  `limiting_factor`** để console không hardcode (đúng nguyên tắc đã áp cho `net_base` /
  `tproxy_port_base`). **Không** còn field `pool_slots_max` — trần bây giờ là một tập
  giá trị có nguồn chặn khác nhau, gộp lại thành một số là đánh mất đúng thứ admin cần
  biết để xử lý.

`get_pool` trả mật khẩu dạng rõ, thống nhất với `get_conf` hiện tại — cùng một ranh
giới tin cậy, không đẻ thêm quy ước mới.

### 6.2 CLI

- `scripts/pool.sh <idx> list|add|del|set`
- `scripts/assign.sh <idx> <mac> <slot|auto>`
- `scripts/rebalance.sh <idx> [--macs a,b,c] [--pool-file f] [--shuffle]`
- `scripts/preflight.sh` kiểm thêm: dải cổng pool có trống không, nft có hiểu cú pháp
  map/vmap không, `dhcpscript` còn trống không.

### 6.3 Console desktop

**Tab Wi-Fi**, khu "Pool proxy": chọn SSID → bảng proxy hiện tại (slot, loại,
host:port, user, label, số thiết bị đang dùng) → ô dán danh sách → *Xem trước* →
*Lưu pool*.

**Tab Thiết bị** ([console/desktop/main.py:3818](console/desktop/main.py#L3818) đã là
`selectmode="extended"`):

- Thêm cột **Proxy**, health/latency, public IP quan sát gần nhất và lần đổi cuối.
- Cho đặt **tag/group**, lưu bộ lọc thường dùng và chọn hàng loạt theo tag.
- Nút **"Đổi proxy cho thiết bị đã chọn…"** → hộp thoại có ô dán proxy, checkbox
  *Chia đều* và *Xáo trộn*, và **bảng xem trước ánh xạ thiết bị → proxy trước khi bấm
  xác nhận** → gọi `rebalance`.
- Chuột phải một dòng → gán thẳng một proxy cụ thể.

**Tab Tổng quan**: CPU, `MemAvailable`, RAM sing-box, overlay, load, tổng slot
`requested/safe`, proxy healthy/dead, thiết bị online và bandwidth/latency theo SSID.
Mọi cảnh báo phải liên kết tới thiết bị/proxy gây ra nó. Có nút xuất diagnostic bundle
đã redact; không ghi credential hoặc URL có user/password vào log.

**Bộ parse danh sách dán** — hàm thuần, dùng chung, có test riêng:

```
socks5://user:pass@host:port      <- định dạng người dùng GenRouter đang có sẵn
http://host:port
user:pass@host:port
host:port:user:pass
host:port
```

Dạng đầu là **bắt buộc phải nhận**: đó là định dạng đối thủ bắt người dùng gõ tay cho
từng máy, nên kho proxy của họ đang ở dạng đó. Bỏ dòng trống và dòng `#`. Chặn ký tự
`|` và ký tự điều khiển. Khử trùng lặp. Vượt `POOL_SLOTS_PER_SSID_MAX` hoặc trần tổng
do bộ tính tài nguyên trả về thì **từ chối và báo rõ**, không cắt im lặng. Nhập nhằng
`a:b:c:d` phân giải bằng dấu `@`; không có
`@` thì hiểu là `host:port:user:pass` — quy tắc này phải có test.

### 6.4 Console web

[console/web/control-panel.html](console/web/control-panel.html) làm tương đương ở
phase sau để hai console không lệch nhau; `tests/test_web_console_i18n.py` bắt lỗi
thiếu chuỗi dịch.

## 7. Việc dễ quên (đã có tiền lệ đau)

1. **Bypass nft cho *mọi* proxy host trong pool.** `build_nft()` hiện chỉ bypass host
   của hàng SSID. Thiếu bước này thì chính kết nối của router tới proxy bị TPROXY bắt
   lại → vòng lặp. Với pool 300 proxy, đây là một set `@proxy_hosts` (`ipv4_addr`, có
   `size`) chứ không phải một luật `return` cho mỗi host.
2. **`install-deps.sh` phải cài `nft_socket`** cho D9 và `preflight.sh` phải kiểm; đây
   là phụ thuộc mới duy nhất của cả plan.
3. `sock_bypass` là **toàn cục, không theo SSID**: thêm host của pool SSID 1 thì client
   của SSID 2 cũng đi thẳng tới IP đó không qua proxy. Hành vi này đã có từ trước với
   proxy đơn, nhưng pool làm nó lộ ra rõ hơn — ghi vào tài liệu.
4. **Vòng lặp pool không được đặt sau `|`.** Đã vấp đúng lỗi này khi chạy thử:
   `pool_rows | while read` chạy trong subshell nên `$inbounds`/`$slot` tích luỹ bên
   trong mất sạch khi ra khỏi vòng lặp. Phải đọc qua file tạm hoặc `< file` như
   `for_each_ssid` đang làm.
5. `desired_idx()` ở [scripts/lib.sh:456](scripts/lib.sh#L456) vẫn lọc `NF==10 || NF==11`
   trong khi `validate_conf` đã cho phép 12 cột — kiểm lại khi đụng vào vùng này.
6. `backup.sh` / `rollback.sh` phải ôm thêm `proxy-pools.conf` và `/etc/sbproxy.assign`.
7. `security-audit.sh`, `SECURITY.md`, `.gitignore` coi `proxy-pools.conf` là file bí mật.
8. LF, shellcheck sạch mức warning, không hardcode giá trị nào — hằng số mới vào
   `settings.sh` và trả về qua `status.meta`.

## 8. Test

### 8.1 Nguyên tắc

1. **Viết test trước, code sau**, và test phải **đỏ vì đúng lý do** — không phải đỏ
   vì hàm chưa tồn tại.
2. **Chỉ chạy suite của bước đang làm.** Full suite chạy một lần ở F10.
3. **Mutation test là cổng, không phải tuỳ chọn.** Mỗi bước phá có chủ đích từng
   guard trong code vừa viết; guard nào sống sót thì test của nó vô giá trị. Ba lần
   đầu áp dụng đã bắt được ba lỗi thật, xem [8.5](#85-hai-kiểu-test-rỗng-đã-gặp).
4. **Bất biến tương thích ngược có golden file**: `tests/fixtures/singbox-nopool.json`
   sinh từ code trước F2 và so từng byte. Fixture đó **không được refresh cho khớp**
   khi test gãy — gãy nghĩa là thay đổi đã phá tương thích ngược.

### 8.2 Suite theo bước

| Bước | Suite | Lệnh chạy |
|---|---|---|
| F1–F5 | `tests/test_pool.sh` | `sh tests/test_pool.sh` |
| F3 | thêm `tests/run.sh` (có assertion trên text nft) | `sh tests/run.sh` |
| F6, F8 | `tests/test_pool_console.py` | `python -m unittest tests.test_pool_console` |
| F7 | `tests/test_pool_agent.sh` | `sh tests/test_pool_agent.sh` |
| F9 | `tests/test_assignd.sh` | `sh tests/test_assignd.sh` |
| F5b | `tests/test_pool_capacity.sh` | `sh tests/test_pool_capacity.sh` |
| F10 | tất cả | `sh tests/run-all.sh` |

### 8.3 Kế hoạch từng bước còn lại

#### F5 — ghi trạng thái ghim

- `assign_set`: ghi thường hoá chữ thường; ghim lại thì **thay chứ không thêm dòng**;
  cùng một máy ghim được trên hai SSID khác nhau; `assign_clear` chỉ xoá đúng SSID đó.
- Từ chối: MAC sai, slot không phải số, slot vượt pool, SSID không có pool, `source`
  lạ. Mỗi ca **một khuyết điểm duy nhất**.
- `assign_prune`: slot biến mất thì **gán lại** (`slot % số_slot_mới`, đánh dấu `auto`)
  chứ không xoá; SSID mất sạch pool thì mới bỏ; SSID khác không bị đụng; log nói rõ
  đã đổi gì.
- `assign_spread`: ma trận M × N với M = 0, 1, 2, 4, 6, 300 và N = 1, 3, 8, 32, 300.
  Khẳng định số thiết bị mỗi proxy **chênh nhau tối đa 1**, mọi thiết bị được ghim
  đúng một lần, và khi N ≥ M thì mỗi máy một slot riêng.
- **Cùng seed cho cùng kết quả** — nếu không, bảng xem trước và lần ghi sau đó có thể
  lệch nhau.
- `apply.sh` gọi `validate_pools` và `assign_prune`; `preflight.sh` gọi `validate_pools`.

#### F6 — parser danh sách dán và hàm chia đều

- Năm định dạng ở [6.3](#63-console-desktop), scheme không phân biệt hoa thường.
- **Quy tắc tách phải có test riêng**: cắt tại dấu `@` **cuối cùng** (mật khẩu có thể
  chứa `@`), rồi tách `user:pass` tại dấu `:` **đầu tiên** (mật khẩu có thể chứa `:`).
  `a:b:c:d` không có `@` thì đọc là `host:port:user:pass`.
- Từ chối: ký tự `|`, ký tự điều khiển, host rỗng, port ngoài 1..65535, port không phải số.
- Khử trùng lặp **giữ lần xuất hiện đầu**, vì slot bám theo thứ tự.
- Vượt `POOL_SLOTS_PER_SSID_MAX`: **báo đã bỏ bao nhiêu dòng**, không cắt im lặng.
- Chia đều: cùng ma trận M × N như F5, chạy ở phía Python để hai bên không lệch nhau.

#### F7 — agent API

Theo khuôn `tests/test_agent.sh`. Với **mỗi** action mới:

- Thiếu token → 401; sai method (GET vào action POST và ngược lại) → 405; body vượt
  giới hạn → 413; body chứa NUL → 400.
- `get_pool`: idx lạ → 400; trả slot đúng thứ tự; kèm danh sách ghim hiện tại.
- `save_pool`: hàng hỏng → 400 **và file trên đĩa không đổi** (kiểm nội dung trước/sau);
  vượt trần → 400; hợp lệ → ghi, dựng lại, trả ok.
- `assign_proxy`: **không restart gì cả** (khẳng định bằng dấu vết lệnh); MAC lạ → 400;
  slot ngoài dải → 400.
- `rebalance`: thay pool rồi chia đều trong **một thao tác**; danh sách MAC rỗng → 400;
  pool rỗng → 400; trả về đúng ánh xạ đã ghi.
- `clients` có thêm `slot`, `proxy_label`, `proxy_host`, `proxy_state`.

> **Sửa so với [6.1](#61-agent-api):** `capacity` thuộc F5b và `pool_health`/`probe_pool`
> thuộc F9, không phải F7 — chúng cần bộ tính và daemon tồn tại trước.

#### F8 — console desktop

- Khu Pool proxy: bảng slot hiện đúng thứ tự, kèm **số thiết bị đang dùng mỗi slot**.
- Hộp thoại đổi hàng loạt: **từ chối khi chưa chọn máy** và **khi pool rỗng**; bảng xem
  trước phải bằng đúng ánh xạ được gửi đi — cùng một hàm, cùng một seed, không tính hai lần.
- Cột Proxy hiện nhãn hoặc `host:port`, và trạng thái "chưa ghim" cho máy chưa có pin.
- Chuột phải gán một máy → gửi `assign_proxy` đúng MAC và slot.
- i18n: mọi chuỗi tiếng Việt mới đều có bản dịch EN, theo cách `test_web_console_i18n.py`
  đang kiểm cho console web.

#### F9 — daemon và móc DHCP

- Máy mới xuất hiện trong `station dump` được ghim **đúng một lần**; máy đã ghim không
  bị ghim lại.
- Từng policy: `random` cho slot trong dải, `round-robin` quay vòng, `least-loaded` chọn
  slot ít máy nhất, `sticky-hash` cho cùng kết quả sau khi xoá state.
- `POOL_ROTATE_ON_RECONNECT=1` thì bốc lại khi máy vào lại.
- **Tự chữa lành**: `nft add element` thất bại, hoặc số phần tử trong map khác file
  state, thì nạp lại toàn bộ map.
- Pool rỗng → không làm gì và không lỗi.
- Móc DHCP: `add`/`old` thì ghim; `del` **giữ nguyên pin** và chỉ gỡ element, vì thiết
  bị sẽ quay lại; hook không ghi ra ngoài `ASSIGN_FILE`.
- Nguồn ngẫu nhiên **không dùng `hexdump`/`od`** — có test khẳng định, vì đó chính là
  applet đã làm hỏng self-update ở 0.4.10.

#### F5b — bộ tính trần

- Fixture cho `/proc/meminfo` **có và không có** `MemAvailable`; `smaps_rollup` có và
  không có (rơi về `VmRSS`); `df -Pk` bình thường và không có `/overlay`.
- Profile khớp/không khớp trên **từng** trường trong bốn trường khoá; không khớp thì
  không được dùng nhầm profile khác.
- `UNPROFILED` → trần 32 (D12); pool vượt trần → `apply.sh` fail **trước mọi thay đổi**,
  và thông báo nêu đủ: số slot đang yêu cầu, trần, lý do, hai lối ra.
- Số học: không có số thực; `×1.25` là `* 5 / 4`; **chặn chia cho 0** khi chưa có
  profile; không tràn với giá trị lớn.
- `limiting_factor` đúng với từng tài nguyên đang chặn.

#### F10 — tài liệu

- Không có CRLF, không có link gãy, mọi thiết lập `POOL_*` mới đều được nói tới trong
  văn xuôi, cả bản `.md` và `.en.md` đều cập nhật, TEST-MATRIX và CHANGELOG có mục mới.
- Chạy `sh tests/run-all.sh` **một lần**.

### 8.4 Đích đột biến theo bước

Mỗi bước phải liệt kê trước các guard sẽ bị phá, rồi chứng minh suite bắt được hết:

| Bước | Guard phải bắt được |
|---|---|
| F5 | thay-vs-thêm dòng, chặn slot, gán lại vs xoá khi mồ côi, phép chia bài `% N`, tính lặp lại của seed |
| F6 | quy tắc tách `@` cuối và `:` đầu, khử trùng lặp, thông báo khi vượt trần, phép chia bài |
| F7 | kiểm token, kiểm method, tính nguyên tử của `save_pool`, chặn dải slot |
| F8 | điều kiện chặn nút, việc dùng chung seed giữa xem trước và lần gửi |
| F9 | điều kiện "đã ghim", từng nhánh policy, điều kiện tự chữa lành |
| F5b | từng phép `min` trong công thức, nhánh fallback, chặn chia 0 |

### 8.5 Hai kiểu test rỗng đã gặp

Ghi lại vì cả hai đều **xanh trong khi không kiểm gì cả**, và cả hai chỉ lộ ra nhờ
mutation test:

1. **Assertion bọc trong `( )`.** Biến đếm tăng trong subshell rồi mất, nên mọi ca
   trong nhóm đều pass bất kể kết quả. Xảy ra ở nhóm kiểm `validate_pool_settings`.
   Cách tránh: chỉ chạy *đối tượng kiểm* trong subshell, còn assertion ở lại shell cha.
2. **Các guard che nhau.** Một fixture gom nhiều khuyết điểm vào cùng một dòng dữ liệu:
   MAC sai cũng là MAC không có lease, slot sai cũng là dòng trùng. Bỏ một guard đi thì
   guard khác vẫn chặn, nên test không đổi màu. Xảy ra ở nhóm kiểm assignment của F4,
   làm sáu đột biến sống sót. Cách tránh: **mỗi ca đúng một khuyết điểm**, mọi thứ khác
   hợp lệ.

Hệ quả phụ đáng giữ: cả hai lần, thứ bị phát hiện không chỉ là test yếu mà còn là
**code thừa** — một nhánh `stride >= 1` và một guard kích thước pool, cả hai không đầu
vào nào chạm tới được. Đột biến sống sót thường là dấu hiệu của một trong hai điều đó.

## 9. Hiệu năng

### 9.1 Trần không phá được

Mỗi byte đi `client → nft → socket sing-box (userspace) → SOCKS5 → WAN`. **Vòng lên
userspace là trần**, và nó là hệ quả trực tiếp của yêu cầu sản phẩm: upstream là
SOCKS5/HTTP nên bắt buộc phải có tiến trình nói giao thức đó. Kèm theo:

- **Mất hardware flow offload** — gói phải lên socket cục bộ nên PPE của MT7986 không
  offload được. Khoản mất lớn nhất, **không thiết kế nào lấy lại được** chừng nào
  upstream còn là SOCKS5.
- **QUIC bị chặn** (`udp dport 443 drop`) vì SOCKS5 hầu như không làm UDP ASSOCIATE.
  Đây là lựa chọn đúng/sai, không phải chỗ tối ưu.

Viết lại từ đầu không phá được trần này. Đừng kỳ vọng vào đó.

### 9.2 Chỗ lấy được: chain nftables (D3)

`build_nft()` hôm nay sinh **một chain phẳng** cho mọi SSID, nên gói của SSID cuối
phải duyệt gần hết luật của các SSID trước — trên đường đi của **từng gói của từng
luồng**, không chỉ gói đầu.

Số luật một gói phải duyệt:

| SSID | slot/SSID | Hôm nay | Pool, chain phẳng, luật/slot | `vmap` + map (D2+D3) | thêm divert (D9) |
|---:|---:|---:|---:|---:|---:|
| 3 | 0 | 20 | 20 | 8 | **1** |
| 8 | 0 | 50 | 50 | 8 | **1** |
| 16 | 0 | 98 | 98 | 8 | **1** |
| 3 | 8 | 20 | 68 | 7 | **1** |
| 8 | 8 | 50 | 178 | 7 | **1** |
| 16 | 8 | 98 | 354 | 7 | **1** |
| 16 | 32 | — | 1122 | 7 | **1** |

Cột cuối là **gói của một luồng TCP đã lập** — tức đại đa số lưu lượng. Gói đầu của
mỗi kết nối vẫn trả giá cột kề trước (7–8 luật).

Bốn điều rút ra:

1. **Chain phẳng + một luật cho mỗi slot là ngõ cụt ở quy mô thị trường** — 1122 luật
   mỗi gói với 16 SSID × 32 proxy. Đây là lý do D2 chuyển sang map.
2. `vmap` + map làm chi phí **hằng số**, không phụ thuộc số SSID lẫn số proxy.
3. **D9 mới là bước nhảy**: đưa chi phí mỗi gói về một luật, và biến việc chọn cấu
   trúc bảng thành chuyện mỗi-kết-nối. Đây cũng là lý do không cần đi xa hơn (eBPF,
   bitmap) — xem [3.6 tầng 3](#36-thuật-toán-tra-bảng).
4. Kể cả không có pool, D3 + D9 vẫn **làm bản đang chạy nhanh lên**.

Chưa đo nên **không cam kết con số**. Ước lượng để biết có đáng làm không: một luật
nft trên Cortex-A53 cỡ vài chục ns → 98 luật ≈ 3–5 µs/gói; ở 1 Gbps với gói 1500B
(~83k pps) là **cỡ 30% một nhân** chỉ để duyệt luật. Cách đo trước khi tối ưu:

```sh
nft --handle list table inet sbproxy | grep -c '^\s*iifname'   # đếm luật
# thêm `counter` vào luật cuối chain, chạy iperf3 qua Wi-Fi, so pps và %CPU
```

### 9.3 Không đáng kỳ vọng

- **Gộp bớt inbound sing-box.** Listener chỉ tốn bộ nhớ, không nằm trên đường dữ liệu.
  Đổi sang một inbound rồi phân luồng bằng `source_ip_cidr` **không nhanh hơn**, lại
  bắt restart mỗi lần gán → đứt kết nối toàn bộ SSID.
- **Route rule sing-box.** Duyệt tuyến tính nhưng chỉ một lần **cho mỗi kết nối**,
  không phải mỗi gói.
- **Nhiều tiến trình sing-box.** Go runtime đã trải goroutine ra cả 4 nhân.
- **`sniff` và fake-IP.** Chạy một lần mỗi kết nối; fake-IP còn *tiết kiệm* một vòng
  DNS cho mỗi kết nối so với phân giải thật.

## 10. Lộ trình

### 10.1 Phase và rủi ro

| Phase | Nội dung | Rủi ro |
|---|---|---|
| **P0** | `settings.sh`, `proxy-pools.conf`, schema `resource-profiles.conf`, parse + validate trong `lib.sh`, test | thấp |
| **P1** | **Spike nft trên GL‑MT6000** (D2, D9), ma trận 0/32/64/128/256/300 idle + loaded, profile OpenWrt/GL.iNet, `pool-capacity.sh`, `calibrate-pool.sh`, pre/post-apply guard + rollback, tái cấu trúc chain (D3), sinh sing-box + nft | **cao** — chốt D2 và limit Flint 2 là chốt được cả thiết kế |
| **P2** | `/etc/sbproxy.assign`, móc DHCP, `sbproxy-assignd`, cập nhật map trực tiếp, CLI | trung bình |
| **P3** | 4 action agent + test | thấp |
| **P4** | Console desktop: sửa pool, đổi hàng loạt, tag/group, overview tài nguyên/health/traffic, audit + undo | trung bình |
| **P5** | Console web, docs (admin-guide, desktop-user-guide, GUIDE, TEST-MATRIX, CHANGELOG, README), `urltest` failover, leak-test | thấp |

**Làm spike D2 trước tiên, nửa ngày trên router.** Trình tự thử: map → nếu hỏng thì
set theo slot (D2a) → nếu `ether saddr` hỏng thì đổi khoá sang IP (D2b). P2–P4 không
đổi hình dạng trong cả ba nhánh.

### 10.2 Trình tự commit

Mỗi bước là **một commit**: viết test trước, code sau, và **chỉ chạy test của bước đó**.
Toàn bộ suite (`sh tests/run-all.sh`) chạy **một lần duy nhất ở bước cuối**, không chạy
lại sau mỗi commit.

| Bước | Nội dung | Chạm vào | Test chạy | Phase |
|---|---|---|---|---|
| F1 | Lớp config pool: `pool_port`, `pool_rows`, `pool_count`, `pool_enabled`, `for_each_pool`, `pool_hosts`, `validate_pools`, `validate_pool_settings` | `settings.sh`, `lib.sh` | `sh tests/test_pool.sh` | P0 |
| F2 | sing-box sinh inbound/outbound/route theo slot | `lib.sh:build_singbox` | `sh tests/test_pool.sh` | P1 |
| F3 | nft **tái cấu trúc, giữ nguyên hành vi**: `vmap` + chain riêng mỗi SSID + luật divert + gộp tcp/udp + `@proxy_hosts` | `lib.sh:build_nft` | `sh tests/test_pool.sh` + `sh tests/run.sh` | P1 |
| F4 | nft định tuyến pool: map có `size`, elements nướng sẵn, luật ghim trước luật mặc định | `lib.sh:build_nft` | `sh tests/test_pool.sh` | P1 |
| F5 | State ghim `/etc/sbproxy.assign`, gán lại slot mồ côi, `assign.sh`, `rebalance.sh`, nạp state khi apply | `lib.sh`, `assign.sh`, `rebalance.sh`, `apply.sh` | `sh tests/test_pool.sh` | P2 |
| F6 | Parser danh sách dán + hàm chia đều (hàm thuần) | `console/desktop/main.py` | `python -m unittest tests.test_pool_console` | P4 |
| F7 | Agent API: `get_pool`, `save_pool`, `assign_proxy`, `rebalance`, `capacity`, `pool_health`, `probe_pool` | `agent/cgi/sbproxy` | `sh tests/test_pool_agent.sh` | P3 |
| F8 | Console desktop: khu Pool proxy, cột Proxy, hộp thoại đổi hàng loạt có xem trước | `console/desktop/main.py` | `python -m unittest tests.test_pool_console tests.test_desktop_workflows` | P4 |
| F9 | `sbproxy-assignd` + móc DHCP + init.d + `install-deps.sh` cài `nft_socket` | `agent/`, `etc/init.d/`, `install-deps.sh` | `sh tests/test_assignd.sh` | P2 |
| F10 | Tài liệu và CHANGELOG (cả bản `.en`) | `docs/`, `README*`, `CHANGELOG.md` | `sh tests/run-all.sh` | P5 |

Bất biến phải giữ ở **mọi** bước: SSID không có pool thì `config.json` và `sbproxy.nft`
sinh ra **giống hệt hôm nay, từng byte**. F3 là bước duy nhất được phép đổi output của
cấu hình không-pool, và chỉ theo nghĩa tương đương ngữ nghĩa — test phải chứng minh.

### 10.3 F5b — bộ tính trần theo RAM

Khối này tách riêng vì toàn bộ giá trị của nó nằm ở **hệ số đo được từ phần cứng thật**.
Làm bộ tính trước khi có số đo chỉ tạo ra một hàm in hằng số 32.

| Bước | Nội dung | Test chạy |
|---|---|---|
| F5b.6 | `calibrate-pool.sh` — đo trên router, sinh `resource-profiles.conf` | `sh tests/test_pool_capacity.sh` (phần số học: median, độ dốc, headroom) |
| F5b.1 | Đọc số liệu: `MemAvailable`, `smaps_rollup`, `df -Pk`, FD, cổng | ↑ |
| F5b.2 | Schema và tra profile theo board + kiến trúc + major.minor sing-box + `POOL_FAILOVER` | ↑ |
| F5b.3 | Bộ tính: năm trần + `limiting_factor` | ↑ |
| F5b.4 | `pool-capacity.sh` xuất JSON theo khuôn `gateway.sh`, preflight gọi read-only | ↑ |
| F5b.5 | Cổng chặn ở `apply.sh` + guard 30 giây sau apply + rollback | ↑ + `sh tests/test_pool.sh` |

**F5b.6 chạy ngay sau spike D2/D9 ở P1**, khi đã có router trong tay; F5b.1–5 làm sau đó
với hệ số thật. Ba điểm kỹ thuật phải chốt trong F5b.3:

- POSIX sh không có số thực: `×1.25` viết là `* 5 / 4`, `20%` là `* 20 / 100`; tính toàn
  bộ bằng KiB, chỉ đổi ra MiB khi in.
- **Chặn chia cho 0**: chưa có profile thì `slot_ram_kib = 0`, phải rẽ sang fallback
  trước phép chia chứ không để nó xảy ra.
- sing-box chưa chạy thì `current_singbox_rss = 0` và `predicted_base_rss` lấy từ profile.

**Xung đột cần biết:** F5b.5 và F5 cùng sửa `apply.sh`. F5 phải xong trước, hoặc gộp hai
phần sửa `apply.sh` vào một commit.

## 11. Rủi ro còn mở

| Câu hỏi | Nếu sai thì sao |
|---|---|
| `tproxy ip to :ip saddr map @m` có parse không? | → D2a: một luật cho mỗi slot; bộ tính áp thêm trần fallback đã benchmark |
| `nft_socket` có trên image không (D9)? | Bỏ luật divert; đúng đắn không đổi, chỉ mất tốc độ và kết nối cũ sẽ gãy khi đổi proxy |
| Máy đặt IP tĩnh không qua DHCP thì map lấy IP ở đâu? | `assignd` đối chiếu `station dump` với bảng neigh/ARP; không ra thì áp D11 (`block` hoặc `default`) và cảnh báo trên console, không tự fail-open |
| `iifname vmap` + `jump` chạy đúng trên nft của OpenWrt? | Giữ chain phẳng, chấp nhận chi phí ở mục 9.2 |
| Mô hình RAM theo slot có còn đúng khi có tải thật? | Đo cả idle và 200–300 kết nối; lấy độ dốc xấu hơn, cộng headroom 25%, rồi post-apply guard xác nhận lại |
| Flint 2 nhưng version sing-box/firmware chưa có profile? | Không dùng nhầm profile; fallback 32 hoặc calibration, preflight chỉ rõ field không khớp |
| Model OpenWrt khác chưa được hiệu chuẩn? | Vẫn hỗ trợ qua `ALLOW_UNSUPPORTED_BOARD=1`, nhưng `auto` giới hạn bảo thủ ≤32 và gắn trạng thái `UNPROFILED` |
| `option dhcpscript` còn trống trên máy người dùng? | Chỉ còn daemon quét, độ trễ ghim ~3 giây |
| Cả D2, D2a, D2b đều hỏng? | Đường lui cấp bốn: chuyển việc chọn proxy vào sing-box (`source_ip_cidr` + `selector` + Clash API), như OpenClash/PassWall — chậm hơn, phải restart khi thêm proxy, nhưng đã được chứng minh chạy được |

**MAC ngẫu nhiên của iOS/Android** ổn định theo từng SSID nên định danh theo MAC
trong file state không bị trôi; chỉ máy bật "đổi MAC định kỳ" mới mất ghim và bị gán
lại. Khoá map là IP nên mỗi lần lease đổi, móc DHCP ghi lại element — định danh vẫn
là MAC, chỉ khoá tra cứu là IP.

## 12. Điểm cần quyết trước khi code

1. **Ghim dính (D6) hay bốc lại mỗi lần vào mạng?** Plan mặc định là dính; muốn bốc
   lại thì `POOL_ROTATE_ON_RECONNECT=1`.
2. **Ngưỡng dự phòng RAM.** Plan đề xuất `max(64 MiB, 20% MemTotal)` cộng 16 MiB cho
   đỉnh lúc apply; P1 phải xác nhận bằng bài tải Wi-Fi thật và OOM pressure, không chỉ idle RSS.
3. **`BSSID_LIMIT=16` so với 32 SSID của đối thủ.** Không thuộc phạm vi plan này,
   nhưng là chênh lệch năng lực cần biết.
4. **D3 làm luôn trong P1 hay tách ra?** Không thuộc tính năng pool, nhưng không làm
   thì pool là bước lùi về hiệu năng.

---

## Phụ lục A: kết quả đã chạy thử

### A.1 Sinh cấu hình sing-box

Dựng bản mẫu của bộ sinh pool-mode, đối chiếu bằng `jq`:

| Kiểm tra | Kết quả |
|---|---|
| Pool rỗng → chỉ `in-w1` / `out-w1` | **giống hệt hôm nay** |
| 1 SSID + 3 proxy | inbound `in-w1, in-w1-s0..s2`, cổng liên tiếp trong dải pool |
| 2 SSID, chỉ SSID 1 có pool | SSID 2 không sinh thêm gì |
| `wifi-socks.conf` rỗng | JSON vẫn hợp lệ (không dính bẫy dấu phẩy thừa như bug 0.4.9) |
| Mật khẩu chứa `"` và `\` | qua `jq -Rn` về nguyên vẹn |
| Chồng dải cổng | hai dải giao nhau **rỗng** |

Tầng sinh cấu hình — phần chiếm khối lượng code lớn nhất — khả thi, không phải đổi
thiết kế.

### A.2 Đếm luật nft

Bảng ở [mục 9.2](#92-chỗ-lấy-được-chain-nftables-d3), tính theo đúng cách
`build_nft()` đang sinh luật hôm nay.

### A.3 Đọc code

- [etc/init.d/sbproxy](etc/init.d/sbproxy) `restart` = `nft delete table` + `nft -f`
  → dẫn tới D4.
- [console/desktop/main.py:3818](console/desktop/main.py#L3818) đã `selectmode="extended"`
  → tính năng 2 không phải sửa cơ chế chọn nhiều dòng.

## Phụ lục B: đối chiếu sản phẩm cùng loại

### B.1 GenRouter — đối thủ trực tiếp

Đây là sản phẩm thương mại nhắm đúng bài toán này (phone farm, mỗi máy một IP), nên
đáng đối chiếu hơn hẳn các dự án OpenWrt đại trà.

Thông tin công khai của GenRouter không hoàn toàn nhất quán: trang H3000/GenFarmer ghi
30 thiết bị ổn định và 32 SSID, trong khi một sản phẩm mini-PC khác được rao 200–300
thiết bị. Vì vậy coi 32 SSID là claim sản phẩm, còn 200–300 thiết bị là **mục tiêu tải
cần benchmark**, không ghi thành năng lực đã được chứng minh của cùng một model.

| Hạng mục | GenRouter công bố (2026) | sbproxy sau plan | Việc cần làm để hơn |
|---|---|---|---|
| Gán theo thiết bị | DPN/VPN/proxy riêng cho từng máy | proxy riêng, sticky | giữ D2/D6 |
| Đổi hàng loạt | tuyên bố một thao tác cập nhật nhiều máy | chọn nhiều máy, dán pool, preview và chia đều | atomic apply + undo/audit; không còn coi bulk là độc quyền |
| An toàn khi proxy lỗi | kill switch, trạng thái DPN/VPN/proxy | `urltest` mới chỉ là tùy chọn | D11: health state + `auto/block/default`, không fail-open chung IP |
| Quan sát | thiết bị/IP/route, CPU/RAM/load, log online/offline, bandwidth + latency theo SSID | status hiện còn rời rạc | dashboard SLO và cảnh báo; dùng luôn capacity calculator ở mục 3.5 |
| Cách ly | subnet riêng, chặn LAN scan, isolated mode | subnet/SSID riêng, client isolation | thêm bài test LAN-scan chéo SSID và trạng thái “proxy-only” rõ ràng |
| Network identity | quảng cáo DNS/WebRTC/MAC/SSID và timezone | DNS fake-IP, WebRTC block, MAC/SSID | không tuyên bố đổi timezone thiết bị; hiển thị leak-test có bằng chứng |
| Quy mô | 32 SSID; claim thiết bị khác nhau theo model/trang bán | GL‑MT6000 là chuẩn, `BSSID_LIMIT=16`, slot tự tính theo profile + tài nguyên | benchmark 32/64/128/256/300 trên Flint 2; model khác chỉ công bố khi có profile riêng |
| Giao thức/uplink | HTTPS, SOCKS5, VPN/DPN; LAN hoặc repeater | HTTP/SOCKS5; OpenWrt uplink | VPN/DPN và tạo proxy PPPoE ngoài scope; không làm loãng P0–P4 |
| Nhóm/tag | một review công khai còn yêu cầu tag/group | chưa có | thêm tag thiết bị, saved selection và bulk action theo tag ở P4 |
| Điều khiển | local dashboard, không cần cloud login | agent + desktop/web console | giữ local-first; API token, audit log và export chẩn đoán đã redact |

Ưu tiên cải thiện rút ra:

1. **P0 — không gom danh tính khi lỗi.** `default proxy` chỉ là compatibility mode.
   Với phone farm, máy chưa gán hoặc hết proxy healthy phải auto-assign an toàn hoặc
   bị block. Đây quan trọng hơn thêm thuật toán cân bằng mới.
2. **P0 — health là dữ liệu điều khiển, không chỉ đèn báo.** Không gán mới vào proxy
   chết; debounce trạng thái; cho chuyển hàng loạt khỏi node chết bằng preview.
3. **P1 — chứng minh quy mô.** Công bố ma trận 30/100/200/300 gồm RAM, CPU, p95 latency,
   reconnect, packet loss và thời gian apply. Không nhập nhằng 30 thiết bị H3000 với
   claim 200–300 của mini-PC.
4. **P2 — observability ngang hoặc hơn GenOS.** Một màn hình phải thấy device → SSID →
   slot → endpoint → public IP, health/latency, traffic, lần đổi cuối và lý do đổi.
5. **P3 — workflow hơn đối thủ.** Tag/group, saved selection, dry-run/preview, atomic
   commit, undo lần gần nhất và audit log. Review công khai của khách GenRouter cũng
   chỉ ra thiếu tag/group; đây là khe cạnh tranh thực tế.
6. **Giữ ranh giới tuyên bố.** Router đổi DNS/WebRTC/MAC/SSID được, nhưng không tự đổi
   timezone/GPS của hệ điều hành ứng dụng. Console nên chạy leak check và trình bày
   kết quả đo được thay vì dùng chữ “ẩn danh tuyệt đối”.

### B.2 Hệ sinh thái OpenWrt

| Dự án | Lõi | Chọn proxy theo thiết bị | Đổi lúc chạy | Cân bằng theo |
|---|---|---|---|---|
| OpenClash | mihomo | sửa rule `SRC-IP-CIDR` | **restart lõi** | mỗi *kết nối* |
| PassWall / PassWall2 | Xray, sing-box | phân luồng theo IP nguồn | sinh lại config + restart | mỗi *kết nối* |
| HomeProxy | sing-box | route rule `source_ip_cidr` | restart | mỗi *kết nối* |
| **sbproxy (plan này)** | sing-box | state theo MAC, map nft tra IP nguồn | `nft add element`, **không restart** | mỗi **thiết bị** |

### B.3 Load-balance của họ không làm được việc này

mihomo có đúng ba chiến lược: `round-robin` (mỗi kết nối một node),
`consistent-hashing` (băm theo *địa chỉ đích*), `sticky-sessions` (băm theo cặp
*nguồn + đích*, cache hết hạn sau **10 phút**). Nghĩa là cùng một máy **lộ IP khác
nhau với các website khác nhau**, rồi đổi lại sau 10 phút. Với mục đích tách danh
tính theo thiết bị thì sai bản chất.

Điểm đau chung của cả hệ sinh thái là **restart**: ai cũng sửa file rồi reload lõi,
tức đứt kết nối của mọi thiết bị chỉ để đổi proxy cho một máy. D2 né đúng chỗ đó.

Tất cả đều khoá theo IP nguồn, không ai khoá theo MAC — điều này **hạ rủi ro** của D2
chứ không nâng, vì đường lui D2b chính là con đường cả hệ sinh thái đã đi nhiều năm.

### B.4 Đã cân nhắc và loại: `selector` + Clash API

Tài liệu sing-box xác nhận: bật `experimental.clash_api.external_controller` thì
outbound `selector` đổi được lúc chạy qua REST, **không cần restart**, còn có
`interrupt_exist_connections` để chọn có ngắt kết nối đang mở hay không. Nghe rất
hợp, nhưng không lấy:

- Việc selector giải quyết — "đổi proxy mà slot đang trỏ tới" — trong thiết kế này
  **đã miễn phí**, vì chuyển thiết bị sang slot khác chỉ là dời element trong map.
- Việc selector **không** giải quyết là thêm proxy chưa từng có trong config — vẫn
  phải sinh lại config và restart. Mà "dán một danh sách mới" luôn rơi vào đúng đó.
- Đổi lại phải mở một HTTP controller trên router, thêm cổng và secret phải bảo vệ.

Giữ làm **đường lui cấp bốn** ở [mục 11](#11-rủi-ro-còn-mở).

### B.5 Lấy về sau: URL subscription

Cả hệ sinh thái nhận danh sách node từ **URL subscription** chứ không bắt dán tay. Ô
"dán danh sách" ở [6.3](#63-console-desktop) là bản thủ công của đúng thứ đó; thêm ô
"dán URL" ở phase sau là mở rộng tự nhiên, không phải thiết kế lại.

### B.6 Xác nhận thêm

Chặn QUIC là **thực hành phổ biến** — các dự án kia đều có công tắc "chặn QUIC" vì
cùng lý do UDP ASSOCIATE. Khác là họ cho người dùng bật/tắt, còn ta chặn cứng; về sau
có thể thành một cột trong `wifi-socks.conf` giống cột `webrtc`.

GenRouter quảng cáo che **WebRTC, DNS leak, MAC, SSID** — bốn thứ này dự án đã có
(cột `webrtc`, fake-IP DNS, `rotate-mac.sh`, cột `mac_oui`). Không có khoảng trống.

### Nguồn

- <https://genrouter.com/> · <https://genrouter.vn/> · <https://genfarmer.com/box-phone-shop/router-proxy-en/>
- <https://scale.genrouter.com/> — dashboard, kill switch, 32 SSID, resource/bandwidth monitoring
- <https://docs.gl-inet.com/router/en/4/user_guide/gl-mt6000/> — tài liệu chính thức Flint 2
- <https://openwrt.org/toh/hwdata/gl.inet/gl.inet_gl-mt6000> — board/CPU/RAM/eMMC/kiến trúc OpenWrt
- <https://fast-router-proxy.gitbook.io/fast-router-api-document/genrouter/huong-dan-su-dung-gen-router>
- <https://docs.kernel.org/networking/tproxy.html> — mẫu chain "divert" (D9)
- <https://wiki.nftables.org/wiki-nftables/index.php/Portal:DeveloperDocs/set_internals> — chọn backend theo `klen` và `size`
- <https://sing-box.sagernet.org/configuration/outbound/selector/>
- <https://sing-box.sagernet.org/configuration/experimental/clash-api/>
- <https://wiki.metacubex.one/en/config/proxy-groups/load-balance/>
- <https://github.com/vernesong/OpenClash/wiki>
