# Chạy thử trên máy ảo, và spike P1

Bộ test ở workstation kiểm **văn bản** mà bộ sinh viết ra. Nó không kiểm được nhân
có nạp được văn bản đó hay không — `nft -c` chỉ phân tích cú pháp bằng binary nft
tại chỗ, còn khả năng hỗ trợ biểu thức thì nằm ở module nhân. Một luật parse được
vẫn có thể nạp thất bại. Mọi quyết định đánh dấu "⚠️ phải spike" trong
[docs/plan-proxy-pool.md](../../docs/plan-proxy-pool.md) đều nằm đúng khoảng cách đó.

Hai script ở đây thu hẹp khoảng cách ấy.

## Giả lập được tới đâu

Không giả lập được **chính** GL-MT6000: nó là MT7986 (Filogic 830), QEMU không có
model cho SoC đó, và quan trọng hơn là không có model cho radio mt7915/mt7986.

Nhưng phần lớn rủi ro của thiết kế không nằm ở radio.

| Máy ảo OpenWrt x86-64 trả lời được | Phải có phần cứng thật |
|---|---|
| **D2** — `tproxy ip to :ip saddr map @m` có nạp được không | **D10** — RAM sing-box theo số slot |
| **D2a** — phương án lui, một set mỗi slot | Số BSSID mỗi radio chịu được |
| **D9** — `socket transparent 1`, `kmod-nft-socket` | Thiết bị thật kết hợp, rời, roaming |
| **D3** — `iifname vmap` + chain riêng mỗi SSID | Thông lượng và độ trễ thật |
| **D4** — map có `size` và `elements` nướng sẵn | |
| `nft add/delete element` lúc chạy, và `nft list map` có đếm được như `assign_map_size` đếm không | |
| dnsmasq gọi `dhcpscript` với `add`/`old`/`del` | |
| sing-box nạp được config nhiều inbound/outbound | |

Nói gọn: **D2 và D9 — hai thứ plan đánh dấu phải spike — kiểm được hết trên máy ảo.**
Chỉ D10 là không.

## Dựng máy ảo

Lấy image x86-64 của OpenWrt (`openwrt-x86-64-generic-ext4-combined-efi.img.gz`),
giải nén, rồi khởi động dưới QEMU, Hyper-V hoặc VirtualBox với **hai** NIC — một
cho WAN, một cho LAN quản lý. Bật SSH, đặt IP LAN, rồi cài phụ thuộc:

```sh
opkg update
opkg install nftables kmod-nft-tproxy kmod-nft-core kmod-nft-socket ip-full jq sing-box
```

`kmod-nft-socket` là phụ thuộc mới duy nhất của cả plan (D9). Nếu image không có
gói đó thì `spike.sh` sẽ nói rõ, và luật divert phải tắt bằng `POOL_DIVERT=off`.

Đẩy code lên bằng đúng đường cài đặt vẫn dùng: `console/desktop` hoặc
`agent/install-agent.sh` qua SSH.

## Dựng phần Wi-Fi giả

Máy ảo không có radio, nên `ubus call network.wireless status` trả về rỗng.

```sh
sh tests/vm/setup-vm.sh          # dựng shim và bridge br-w1, br-w2
sh tests/vm/setup-vm.sh --undo   # gỡ hết
```

Script cài **hai shim** đứng trước trên `PATH` — `ubus` và `iw` — trả lời đúng hai
câu hỏi liên quan tới wireless từ file, còn lại chuyển tiếp cho binary thật. Làm
kiểu này để `scripts/lib.sh` **không phải học về chế độ test**: code chạy trên máy
ảo là đúng code chạy trên router.

Cho một thiết bị "vào mạng":

```sh
printf 'Station aa:bb:cc:dd:ee:01 (on br-w1)\n\tsignal:  \t-40 dBm\n' \
  >> /etc/sbproxy-vm/stations/br-w1
echo '99999 aa:bb:cc:dd:ee:01 192.168.11.50 vm-client *' >> /tmp/dhcp.leases
```

Rồi `ALLOW_UNSUPPORTED_BOARD=1 sh scripts/apply.sh`.

## Chạy spike

```sh
sh tests/vm/spike.sh
```

Chạy được trên máy ảo **hoặc thẳng trên router**. Cần root, vì nó nạp luật thật —
đó chính là điểm khác biệt so với bộ test workstation.

**Nó làm gì với máy:** nạp luật vào một bảng riêng, `inet sbproxy_spike`, rồi xoá
lúc thoát. Không bao giờ đụng `inet sbproxy`. Mọi chain hook prerouting ở priority
1000 — sau tất cả — và mọi luật chỉ khớp `203.0.113.199`, một địa chỉ TEST-NET-3
(RFC 5737) không bao giờ xuất hiện trên dây. Nên luật chứng minh được nhân chấp
nhận nó mà không chuyển hướng một gói tin nào.

Chạy trên router đang chạy thật là an toàn theo cách dựng đó, nhưng vẫn cần root và
vẫn thêm một bảng trong chốc lát.

Nếu **D2 hỏng**, spike sẽ nói ra, và [`build_nft()`](../../scripts/lib.sh) là chỗ duy
nhất phải sửa để chuyển sang D2a.

## Còn thiếu

Phép đo RAM của D10 (`--ram`) mới chỉ là chỗ trống: nó cần sinh config cho từng mức
số slot và chạy sing-box thật để đo RSS. Xem
[docs/plan-proxy-pool.md §3.5](../../docs/plan-proxy-pool.md). Và phép đo đó chỉ có
nghĩa trên GL-MT6000 — RSS trên x86-64 không nói gì về Filogic 830.
