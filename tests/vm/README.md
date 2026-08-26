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

## Đã chạy: nhân WSL2 6.18, 2026-08-26

| | |
|---|---|
| **D2** — `tproxy ip to :ip saddr map @m` | **đạt** |
| **D2a** — một set mỗi slot | đạt |
| **D3** — `iifname vmap` + chain riêng mỗi SSID | đạt |
| **D4** — map có `size` và `elements` nướng sẵn | đạt |
| `add` / `list` / `delete element` lúc chạy | đạt |
| 32 SSID nạp cùng lúc | đạt |
| **D9** — `socket transparent 1` | *bỏ qua* — nhân WSL không có `nft_socket` |

**D2 đạt trên nhân thật.** Đó là câu hỏi lớn nhất còn treo: F2, F3, F4 đều dựng
trên nó, và D2a giờ chỉ còn là phương án lui trên giấy.

Nhân WSL2 không phải nhân OpenWrt trên MT7986, nên đây là bằng chứng mạnh chứ
chưa phải kết luận cuối. Nhưng nếu D2 hỏng ở tầng biểu thức nftables thì nó đã
hỏng ở đây rồi.

**D9 chưa trả lời được ở đâu ngoài OpenWrt**: WSL không build `nft_socket`, nft
báo `No such file or directory`. Spike phân biệt trường hợp này với việc nhân
*hiểu* biểu thức rồi từ chối — cái đầu là thiếu module, cái sau mới là lỗi thiết
kế. Trên router: `opkg install kmod-nft-socket`; nếu image không có thì
`POOL_DIVERT=off`.

Lần chạy này cũng lộ ra hai lỗi của chính spike: `chain w1 { … accept }` một
dòng thiếu dấu `;` trước `}`, nên nft báo lỗi cú pháp dây chuyền qua cả chục
dòng sau và đọc y như nhân từ chối thiết kế; và D9 báo *trượt* trong khi lẽ ra
phải báo *bỏ qua*. Cả hai đã sửa.

## WSL: đường tắt cho D2 và D9, không phải máy ảo router

**WSL không chạy được OpenWrt theo cách có ích ở đây.** WSL2 dùng nhân của
Microsoft chứ không phải nhân OpenWrt. Có thể import rootfs OpenWrt thành một
distro, nhưng sẽ không có **procd** — nên `uci`, `ubus` và mọi `/etc/init.d/*`
đều không chạy. `apply.sh`, `install-agent.sh`, dnsmasq và `dhcpscript` đều nằm
ngoài tầm.

Nhưng WSL2 có **nhân Linux thật**. Nếu nhân đó có `nft_tproxy` và `nft_socket`
thì `spike.sh` chạy thẳng trong WSL và trả lời **D2 với D9** — hai câu hỏi rủi ro
nhất — mà không cần dựng máy ảo nào.

### Cài

Chạy PowerShell **với quyền admin**:

```powershell
wsl --install -d Ubuntu
```

Khởi động lại máy khi được hỏi. Lần đầu mở Ubuntu sẽ hỏi tên người dùng và mật
khẩu.

### Kiểm nhân có đủ không

```bash
sudo apt update && sudo apt install -y nftables
sudo modprobe nft_tproxy nft_socket && lsmod | grep -E 'nft_tproxy|nft_socket'
```

- **Ra hai dòng** → chạy được spike. Sang bước dưới.
- **`modprobe: FATAL: Module ... not found`** → nhân WSL không build hai module
  đó. WSL hết đường; dùng QEMU (xem phần dưới), hoặc chạy QEMU *bên trong* WSL
  nếu máy bật được ảo hoá lồng.

### Chạy spike

```bash
cd /mnt/d/working/gitlab.vgplay.vn/research/openwrt-multiwifi-socks5
sudo sh tests/vm/spike.sh
```

Spike nạp luật vào bảng riêng trong namespace mạng của WSL rồi xoá đi; không
đụng gì tới Windows.

**Kết quả nghĩa là gì.** Nhân WSL không phải nhân OpenWrt trên MT7986, nên
*đạt* ở đây là dấu hiệu tốt chứ chưa phải kết luận. Nhưng *trượt* ở đây là cảnh
báo mạnh, và biết sớm thì rẻ hơn nhiều: D2 là nền của F2, F3 và F4.

### Chạy luôn bộ test workstation dưới shell thật

Tiện thể, WSL cho chạy suite dưới `dash`/BusyBox — gần với `ash` của router hơn
git-bash trên Windows:

```bash
sudo apt install -y busybox shellcheck jq
cd /mnt/d/working/gitlab.vgplay.vn/research/openwrt-multiwifi-socks5
sh tests/run-all.sh
```

## Dựng máy ảo

### Trên Windows, bằng QEMU

QEMU chưa có sẵn trên máy này. Cài trước:

```powershell
winget install --id SoftwareFreedomConservancy.QEMU
```

Mở lại terminal, rồi:

```powershell
.\tests\vm\qemu-win.ps1 -Fetch    # tải và giải nén image, chỉ một lần
.\tests\vm\qemu-win.ps1           # khởi động
```

Trong console của VM, đặt mật khẩu root rồi thoát bằng `Ctrl-A X` khi cần:

```sh
passwd
```

Từ terminal khác:

```powershell
ssh -p 2222 root@127.0.0.1
```

> `qemu-win.ps1` **chưa từng chạy thử** — máy viết ra nó không có hypervisor nào.
> Coi lần chạy đầu là bring-up, không phải đường đã kiểm chứng.

### Bằng tay, hoặc trên Hyper-V / VirtualBox

Lấy image x86-64 của bản ổn định hiện tại (25.12.5 tại thời điểm viết):

```
https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/openwrt-25.12.5-x86-64-generic-ext4-combined-efi.img.gz
```

Giải nén, nới đĩa lên ~2 GB (image gốc rất nhỏ, `opkg install sing-box` sẽ hết
chỗ), rồi khởi động với **hai** NIC — NIC thứ nhất thành `br-lan`, NIC thứ hai
thành WAN.

### Cài phụ thuộc trong VM

```sh
opkg update
opkg install nftables kmod-nft-tproxy kmod-nft-core kmod-nft-socket ip-full jq sing-box
```

`kmod-nft-socket` là phụ thuộc mới duy nhất của cả plan (D9). Nếu image không có
gói đó thì `spike.sh` sẽ nói rõ, và luật divert phải tắt bằng `POOL_DIVERT=off`.

### Đẩy code lên

Dùng đúng đường cài đặt vẫn dùng cho router thật:

```sh
scp -P 2222 -r . root@127.0.0.1:/root/sbproxy
ssh -p 2222 root@127.0.0.1 'cd /root/sbproxy && sh agent/install-agent.sh'
```

Hoặc mở console desktop và trỏ nó vào `http://127.0.0.1:2222`.

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
