(function () {
  "use strict";
const EN_TEXT = {
  "Dải IP local riêng (/24)": "Dedicated local IP range (/24)",
  "(tuỳ chọn, RFC1918: 10/8, 172.16/12, 192.168/16)": "(optional, RFC1918: 10/8, 172.16/12, 192.168/16)",
  "Để trống để dùng dải 192.168.(NET_BASE + idx).0/24.": "Leave empty to use 192.168.(NET_BASE + idx).0/24.",
  "SSID này chỉ dùng proxy trong Pool. Thiết bị chưa được gán slot sẽ bị chặn; không có proxy mặc định.": "This SSID uses proxy pool slots only. Unassigned devices are blocked; there is no default proxy.",
    "Tài khoản": "Account", "Token agent": "Agent token", "Agent URL": "Agent URL", "(tuỳ chọn)": "(optional)",
    "Cài đặt proxy": "Proxy settings", "Cài đặt proxy →": "Proxy settings →", "Cấu hình WiFi, SOCKS và chính sách kết nối trên router.": "Configure Wi-Fi, SOCKS and connection policies on the router.", "Cấu hình SSID, proxy pool và chính sách kết nối.": "Configure SSIDs, proxy pools and connection policies.",
    "Analytics": "Analytics", "Tổng quan nhanh về WiFi, proxy và health.": "A quick overview of Wi-Fi, proxy and health.",
    "Quan sát client đang kết nối và quản lý proxy theo từng thiết bị.": "Monitor connected clients and manage proxy assignment per device.",
    "Xem danh sách thiết bị": "View device list", "Kiểm tra IP, SSID, trạng thái online và proxy đang dùng.": "Check IP, SSID, online status and the active proxy.", "Mở thiết bị →": "Open devices →",
    "Tài khoản sbproxy ⓘ": "sbproxy account ⓘ", "Token trực tiếp ⓘ": "Direct token ⓘ",
    "Kết nối router": "Connect router", "Thêm WiFi": "Add Wi-Fi", "Nhập .conf": "Import .conf",
    "Đẩy & Áp lên router": "Push & Apply to router", "Thiết bị": "Devices", "Tải từ router": "Pull from router",
    "Cập nhật": "Update", "Tải wifi-socks.conf": "Download wifi-socks.conf", "Tải JSON": "Download JSON",
    "Xoá hết": "Clear all", "Băng": "Band", "Sức khỏe": "Health", "Chưa có WiFi nào": "No Wi-Fi configured",
    "Bấm “＋ Thêm WiFi” để tạo, hoặc “⤓ Nhập .conf” để dán file có sẵn.": "Click “＋ Add Wi-Fi” to create one, or “⤓ Import .conf” to paste an existing file.",
    "Copy": "Copy", "Tên WiFi (SSID)": "Wi-Fi name (SSID)", "Băng tần": "Band", "idx (số duy nhất)": "idx (unique number)",
    "Loại proxy": "Proxy type", "Nhập nhanh proxy": "Quick proxy input", "Tách": "Parse",
    "Hãng WiFi giả lập (MAC)": "Emulated Wi-Fi vendor (MAC)", "(3 byte đầu của MAC theo hãng; 3 byte sau random)": "(first 3 MAC bytes identify the vendor; last 3 are random)",
    "Mật khẩu WiFi": "Wi-Fi password", "(≥ 8 ký tự)": "(≥ 8 characters)", "Cổng": "Port",
    "(trống nếu không auth)": "(empty when authentication is disabled)", "Cách ly client": "Isolate clients", "Chặn WebRTC": "Block WebRTC",
    "Giữ nguyên": "Keep as-is", "Bypass WebRTC": "Bypass WebRTC",
    "Huỷ": "Cancel", "Lưu": "Save", "Kết nối agent trên router": "Connect to the router agent",
    "Chưa kết nối. Đăng nhập bằng tài khoản sbproxy.": "Not connected. Log in with the sbproxy account.",
    "Tên đăng nhập": "Username", "Mật khẩu": "Password", "Đăng xuất": "Log out",
    "Tài khoản riêng của sbproxy, tạo ở lần mở web đầu tiên; đổi trong UI hoặc bằng lệnh sbproxy-webauth trên router.": "Dedicated sbproxy login. Change it here or with sbproxy-webauth.",
    "Nâng cao: URL khác hoặc token trực tiếp": "Advanced: a different URL or a raw token",
    "Tạo tài khoản quản trị đầu tiên": "Create the first admin account",
    "Router chưa có tài khoản web. Tạo tài khoản đầu tiên để đăng nhập.": "The router has no web account yet. Create the first one to log in.",
    "(1-32 ký tự chữ, số, . _ -)": "(1-32 characters: letters, digits, . _ -)",
    "Nhập lại mật khẩu": "Repeat the password", "Tạo tài khoản": "Create account",
    "Đổi mật khẩu": "Change password",
    "Bị cấm": "Blocked", "Chặn MAC…": "Block a MAC…", "Xuất CSV": "Export CSV",
    "Trạng thái": "Status", "Trạng thái: tất cả": "Status: all", "WiFi: tất cả": "Wi-Fi: all",
    "Thao tác đã chọn…": "Selected actions…", "Ngắt kết nối": "Disconnect", "Thực hiện": "Run",
    "0 đã chọn": "0 selected", "Chọn tất cả": "Select all", "Xóa proxy": "Delete proxy",
    "Sửa proxy": "Edit proxy", "Huỷ sửa": "Cancel edit",
    "Thêm proxy & phân phối": "Add proxies & distribute", "Thêm proxy": "Add proxies", "Thêm proxy ·": "Add proxies ·",
    "Proxy mới được thêm vào SSID. Chỉ thiết bị đã chọn được phân phối lại.": "New proxies are added to the SSID. Only selected devices are redistributed.",
    "Đang tải pool…": "Loading pool…", "Thêm & phân phối": "Add & distribute",
    "Tự làm mới": "Auto refresh", "Đang kết nối": "Connected", "Đã ngắt": "Disconnected",
    "Tự động": "Automatic", "Tự động nhận dạng": "Detect automatically",
    "Mỗi dòng một proxy. Thay đổi pool không reload Wi‑Fi.": "One proxy per line. Pool changes do not reload Wi-Fi.",
    "Xoá slot đã nhập": "Delete the listed slots", "Thêm vào pool": "Add to the pool",
    "Xóa pool": "Delete the pool", "Xem thêm": "Show more", "Thử lại": "Retry",
    "Đổi mật khẩu tài khoản web của sbproxy. Cần mật khẩu hiện tại.": "Change the sbproxy password.",
    "Mật khẩu hiện tại": "Current password", "Mật khẩu mới": "New password",
    "Nhập lại mật khẩu mới": "Repeat the new password",
    "Cấu hình": "Configuration",
    "(để trống nếu mở UI ngay từ router)": "(leave empty when the UI is served by the router)",
    "(in ra bởi install-agent.sh)": "(printed by install-agent.sh)", "Ngắt": "Disconnect", "Đóng": "Close", "Kết nối": "Connect",
    "Tạo backup ngay": "Create backup now", "Đường ra": "Egress", "Đường ra Internet": "Internet egress",
    "Kiểm tra lại": "Check again", "Đổi đường ra": "Switch egress", "Reset toàn bộ": "Reset everything", "Thiết bị đang kết nối": "Connected devices", "Làm mới": "Refresh",
    "Bản đang chạy trên router": "Version running on router", "File package": "Package file",
    "Cho phép hạ version (force)": "Allow version downgrade (force)", "Kết quả": "Result",
    "IP / Tên máy": "IP / Hostname", "Thời gian kết nối": "Connected", "Vào (in)": "Received", "Ra (out)": "Sent", "Sóng": "Signal",
    "Tổng WiFi": "Total Wi-Fi", "SOCKS riêng biệt": "Distinct SOCKS", "Cách ly / WebRTC": "Isolation / WebRTC",
    "Sửa": "Edit", "Bỏ cấm": "Unblock", "Cấm": "Block", "mới nhất ·": "latest ·",
    "Về máy": "Download", "Khôi phục": "Restore", "Đang tải danh sách…": "Loading list…",
    "Chưa có backup nào.": "No backups available.", "Đang tải…": "Loading…",
    "Không có thiết bị nào đang kết nối.": "No connected devices.", "ẩn danh": "anonymous",
    "Ngẫu nhiên / ẩn danh (02:xx)": "Random / anonymous (02:xx)",
    "Cập nhật agent trên router": "Update the router agent", "Nhật ký": "Logs", "Nhật ký debug": "Debug logs",
    "Trợ lý gỡ lỗi": "Troubleshooting assistant", "Quét lại": "Scan again",
    "Mức độ": "Severity", "Phát hiện": "Finding", "Cách sửa": "Fix",
    "Chạy hoàn toàn trên router: không cần Internet, không có dữ liệu nào rời khỏi máy. Mỗi kết luận kèm cách sửa, và chỉ chạy khi bạn bấm xác nhận.":
      "It runs entirely on the router: no Internet, and nothing leaves the box. Every finding carries its fix, and a fix runs only when you confirm it.",
    "Log theo ngày, tự xoá sau 7 ngày. File tải về không chứa mật khẩu hoặc token.": "Daily logs are deleted after 7 days. Downloads contain no passwords or tokens.",
    "Ngày log": "Log date", "Tải gói debug": "Download debug report",
    "Cập nhật KHÔNG reload WiFi — cấu hình chỉ đổi khi bạn bấm “Đẩy & Áp” sau đó.": "Update does not reload Wi-Fi. Click “Push & Apply” to activate changes."
  };
  Object.assign(EN_TEXT, {
    "Thiết bị chưa gán proxy": "Unassigned devices",
    "Chặn": "Block",
    "sẽ giữ DHCP/gateway nhưng chặn DNS và Internet tới khi thiết bị được gán proxy.": "DHCP/gateway remain available, but DNS and Internet are blocked until a proxy is assigned.",
    "Chặn Internet": "Block Internet",
    "Dùng proxy mặc định": "Use the default proxy",
    "Lưu & Apply": "Save & Apply"
  });
  // Blocks that contain inline markup are swapped whole rather than per text node.
  Object.assign(EN_TEXT, {
    "Mỗi dòng là một proxy.": "One proxy per line.", "Bạn có thể dán nhiều proxy cùng lúc vào ô này.": "You can paste multiple proxies into this field at once.",
    "Cài đặt": "Settings", "Router settings": "Router settings", "Quản lý SSID, pool proxy và trạng thái từng đường mạng.": "Manage SSIDs, proxy pools and each network path.", "Thêm, nhập, xuất và áp dụng cấu hình lên router.": "Add, import, export and apply router configuration.", "Danh sách SSID và thao tác riêng cho từng WiFi.": "SSID list and per-Wi-Fi actions.", "Xem nội dung cấu hình trước khi sao chép hoặc debug.": "Review configuration before copying or debugging.", "Chưa kết nối": "Not connected",
    "Kết nối agent, phiên bản và dịch vụ proxy.": "Agent connection, version and proxy service.",
    "Kiểm tra health": "Health check", "Restart sing-box": "Restart sing-box",
    "Egress": "Egress", "Đường ra Internet thực tế của router.": "The router's actual Internet egress.",
    "Chưa kiểm tra": "Not checked", "Chi tiết egress": "Egress details",
    "Chẩn đoán SSID": "SSID diagnostics", "Kiểm tra Wi-Fi, bridge, DHCP, nftables, route, sing-box và proxy.": "Check Wi-Fi, bridge, DHCP, nftables, routing, sing-box and proxy.",
    "Chọn SSID cần chẩn đoán": "SSID to diagnose", "Chạy chẩn đoán": "Run diagnostics", "Nhật ký 7 ngày": "7-day logs",
    "Bảo trì router": "Router maintenance", "Chỉ các mục kiểm tra và vận hành cần thiết trên router.": "Only the checks and operations needed on the router.", "Các thao tác có thể làm thay đổi hoặc khôi phục hệ thống.": "Actions that can change or restore the system.",
    "Cập nhật agent": "Update agent"
  });
const EN_HTML = {
    rbHint: 'Backups are created on Apply / SOCKS changes. Before firmware updates, click <b>Download</b>.',
    devHint: 'Devices are grouped by Wi-Fi. <b>Disconnect</b> is temporary; <b>Block</b> is permanent.',
    gwHint: 'Select an interface, then click <b>Switch egress</b>. Wi-Fi and proxies stay unchanged.',
    upStatus: 'Choose a <b>sbproxy update package</b>. The router backs up first and keeps the current Wi-Fi/SOCKS config.'
  };
const EN_ATTR = {
    "Tài khoản riêng của sbproxy, tạo ở lần mở web đầu tiên; có thể đổi trong UI hoặc bằng lệnh sbproxy-webauth trên router.": "The sbproxy account is created on first launch; change it in the UI or with sbproxy-webauth on the router.",
    "Token được in ra bởi install-agent.sh. Chỉ dùng phương thức này trên mạng quản trị tin cậy.": "Token printed by install-agent.sh. Use this method only on a trusted management network.",
    "Backup và rollback trên router": "Back up and roll back the router",
    "Xem đường ra Internet của router": "View the router's Internet egress",
    "Cập nhật sbproxy trên router": "Update sbproxy on the router",
    "Kiểm tra và vận hành router": "Check and operate the router",
    "Quản lý cấu hình WiFi và proxy": "Manage Wi-Fi and proxy configuration",
    "Mở các công cụ router": "Open router tools",
    "Kết nối agent trên router": "Connect to the router agent", "Đăng xuất": "Log out", "Đổi giao diện sáng/tối": "Toggle light/dark theme",
    "Ghi config lên router rồi chạy apply.sh": "Write the configuration to the router and run apply.sh",
    "Thiết bị đang kết nối từng WiFi (kick / cấm)": "Devices connected to each Wi-Fi (disconnect / block)",
    "Tải wifi-socks.conf từ router": "Download wifi-socks.conf from the router",
    "Backup & Rollback trên router": "Back up and roll back the router",
    "Xem và đổi đường ra Internet của router": "View and switch the router's Internet egress",
    "Đá mọi thiết bị, xoá mọi SSID và pool, rồi apply": "Kick every device, delete every SSID and pool, then apply",
    "Cập nhật code sbproxy trên router bằng package .tar.gz/.zip": "Update sbproxy on the router using a .tar.gz/.zip package",
    "Xem và tải nhật ký debug 7 ngày": "View and download 7 days of debug logs",
    "Quét lỗi trên router và đề xuất cách sửa": "Scan the router for faults and offer a fix",
    "Ngày log": "Log date",
    "Mở / đóng menu": "Open / close the menu",
    "Test proxy đang nhập từ router (không cần lưu trước)": "Test the entered proxy from the router (no need to save first)",
    "Ghi nhớ interface đang chọn là đường ra mong đợi": "Remember the selected interface as the expected uplink",
    "Bỏ ghim: chấp nhận đường ra mà default route đang dùng": "Unpin: accept whichever uplink the default route uses",
    "Định dạng của nhà cung cấp proxy": "The proxy provider's line format",
    "Loại proxy cho các dòng vừa dán": "Proxy type for the pasted lines",
    "Thao tác với thiết bị đã chọn": "Actions for selected devices",
    "Chọn tất cả thiết bị hiển thị": "Select all visible devices",
    "Thao tác với proxy đã chọn": "Actions for selected proxies",
    "Đổi BSSID/MAC ngẫu nhiên cho WiFi này (client phải nối lại)": "New random BSSID/MAC for this Wi-Fi (clients must reconnect)"
  };

  // Labels carry a leading icon ("＋ Thêm WiFi"); the map is keyed on the words
  // only, so split the icon off, translate the rest, then put the icon back.
  const ICON_PREFIX = /^([^\p{L}\p{N}(]*)(.*)$/su;
  function translatePhrase(vi) {
    const [, icon, words] = vi.match(ICON_PREFIX);
    if (language === "vi") return vi;
    const body = EN_TEXT[words.trim()];
    return body === undefined ? vi : icon + body;
  }

  window.SBPROXY_I18N_EN = { EN_TEXT, EN_HTML, EN_ATTR };
})();
