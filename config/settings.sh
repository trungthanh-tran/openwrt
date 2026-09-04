# settings.sh — project-wide tunables sourced by lib.sh.
# shellcheck disable=SC2034  # Values are consumed by scripts that source this file.
# Adjust this file for your hardware before running apply.sh.

# --- Platform ---------------------------------------------------------------
# Refuse to run on anything other than the boards this project is tested on.
# Set to 1 to downgrade that to a warning when trying another device; nothing
# else changes, and the scripts are still only verified on the GL-MT6000.
# lib.sh sources this file after the environment is already in place, so this
# has to let an exported value stand -- otherwise `ALLOW_UNSUPPORTED_BOARD=1 sh
# scripts/apply.sh`, which is what the VM guide tells people to run, is silently
# overwritten back to 0 here.
ALLOW_UNSUPPORTED_BOARD="${ALLOW_UNSUPPORTED_BOARD:-0}"

# --- Radio-to-band mapping --------------------------------------------------
# OpenWrt does not guarantee radio0=2.4G. preflight.sh lists the radios this
# board really has and names the right values when these are wrong.
RADIO_2G="radio0"
RADIO_5G="radio1"
# Required ISO 3166-1 alpha-2 code for the router's operating country.
# Leaving it empty makes preflight/apply fail to prevent unlawful radio settings.
WIFI_COUNTRY="VN"

# --- Hardware limits --------------------------------------------------------
# Maximum BSSIDs per radio; verify with `iw list` under valid interface combinations.
BSSID_LIMIT=16

# --- Networking -------------------------------------------------------------
# Third subnet octet = NET_BASE + idx; for example 10 + 1 gives 192.168.11.0/24.
NET_BASE=10
# sing-box TPROXY port = TPROXY_PORT_BASE + idx.
TPROXY_PORT_BASE=12000

# --- Proxy pool -------------------------------------------------------------
# An SSID may carry several proxies (config/proxy-pools.conf). Each one is a
# "slot" with its own TPROXY port, so a device can be pinned to a single proxy
# without regenerating any configuration:
#   pool port = POOL_PORT_BASE + idx * POOL_PORT_STRIDE + slot
# The whole block from POOL_PORT_BASE upwards is reserved; keep it clear of
# TPROXY_PORT_BASE. Leaving proxy-pools.conf absent keeps every SSID on the
# single proxy named in its wifi-socks.conf row, exactly as before.
POOL_PORT_BASE=13000
# Ports reserved per idx. Fixed on purpose: the port of an SSID must not move
# when the pool grows or shrinks. Also the hard ceiling on slots per SSID.
POOL_PORT_STRIDE=256
# Per-SSID cap on proxies. Never larger than POOL_PORT_STRIDE.
POOL_SLOTS_PER_SSID_MAX=256

# The kernel's TPROXY documentation describes a "divert" rule that short-cuts
# any packet already belonging to an open transparent socket, so only the first
# packet of a connection runs the classification rules. It needs the nftables
# socket expression (kmod-nft-socket), which not every image carries.
#   auto = use it when this router's nft accepts it (default)
#   on   = always emit it; off = never
POOL_DIVERT="auto"
# Which device is pinned to which slot. Runtime state, like BANS_FILE, and the
# source of truth that build_nft bakes into the generated ruleset.
# Lines: idx|mac|slot|source   (source is auto or manual)
ASSIGN_FILE="/etc/sbproxy.assign"
# Capacity of each SSID's pin map. nftables picks a fixed-size hash only when a
# size is declared; without one it falls back to the slower resizable table.
# The map does not grow past this, so keep it well above the DHCP pool.
POOL_MAP_SIZE=512

# Which slot a device that has just appeared gets:
#   random       bốc ngẫu nhiên rồi dính luôn (mặc định)
#   round-robin  quay vòng theo số máy đã ghim
#   least-loaded slot ít máy nhất
#   sticky-hash  băm MAC; cùng máy luôn ra cùng proxy kể cả sau khi xoá state
POOL_ASSIGN_POLICY="random"
# 1 = bốc proxy mới mỗi lần thiết bị vào lại, thay vì giữ nguyên. Ghim tay
# không bao giờ bị đổi, kể cả khi bật.
POOL_ROTATE_ON_RECONNECT=0
# Nhịp quét lưới an toàn của sbproxy-assignd, giây.
POOL_SCAN_INTERVAL=3
# Firewall mark and routing table used by TPROXY.
TPROXY_MARK=1
TPROXY_TABLE=100
TPROXY_RULE_PRIORITY=10000
TPROXY_MARK_MASK=255

# v0.2 proxies IPv4 only. `disable` turns off RA/DHCPv6 on sbproxy SSIDs to prevent bypass.
IPV6_MODE="disable"
# Fake-IP range sing-box hands to proxied clients so SOCKS receives hostnames,
# not resolved IPs. Must not overlap any real subnet in use (198.18.0.0/15 is
# the RFC 2544 benchmark range and is safe on typical networks).
FAKEIP_RANGE="198.18.0.0/15"
# Resolver sing-box forwards real lookups to. Any reachable IP or hostname; use
# the ISP resolver or an internal server when 1.1.1.1 is blocked or unwanted.
DNS_UPSTREAM="1.1.1.1"

# --- Firewall ---------------------------------------------------------------
# Guest-zone input policy. ACCEPT keeps DHCP/DNS and TPROXY reliable while separate
# rules block admin ports. Use REJECT only after adding DHCP/DNS permits and testing.
ZONE_INPUT="ACCEPT"
# Router administration ports blocked from guest zones.
ADMIN_PORTS="22 80 443"

# --- Wi-Fi defaults ---------------------------------------------------------
WIFI_ENCRYPTION="psk2"     # Use `sae` for WPA3 or `sae-mixed` for transition mode.

# --- sing-box compatibility --------------------------------------------------
# The generated config uses the modern (1.12+) syntax and needs no
# ENABLE_DEPRECATED_* flags. Requires sing-box >= 1.12; apply.sh enforces this.
# Escape hatch: if a future sing-box demands a flag by name, put it here and
# rerun apply.sh — it is injected into `sing-box check` and the init script.
SINGBOX_COMPAT_ENV=""

# --- Paths ------------------------------------------------------------------
SINGBOX_CONF="/etc/sing-box/config.json"
# Persists the fake-IP map across sing-box restarts.
SINGBOX_CACHE="/etc/sing-box/cache.db"
NFT_FILE="/etc/sbproxy.nft"
BACKUP_DIR="/root/sbproxy-backups"
# Persistent per-SSID MAC bans (lines: idx|mac). Source of truth re-applied by
# apply.sh so bans survive re-applies; ban.sh/unban.sh maintain it.
BANS_FILE="/etc/sbproxy.bans"
# Devices that have ever connected (lines: idx|mac|first_seen|last_seen|ip|host).
# clients.sh refreshes the tmpfs copy on every poll — a console polls every few
# seconds, and writing flash that often would wear it out — and only flushes to
# the persistent copy when a device is seen for the FIRST time, so history
# survives a reboot at a handful of writes per new device.
SEEN_FILE="/tmp/sbproxy.seen"
SEEN_STORE="/etc/sbproxy.seen"
# Cap on remembered devices; the oldest last_seen entries are dropped first.
SEEN_MAX=400

# --- STUN/TURN ports blocked for WebRTC leak mitigation --------------------
STUN_TCP_PORTS="3478, 3479, 5349, 5350"
STUN_UDP_PORTS="3478, 3479, 5349, 5350, 19302-19309"
