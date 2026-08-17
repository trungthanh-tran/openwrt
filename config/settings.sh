# settings.sh — project-wide tunables sourced by lib.sh.
# Adjust this file for your hardware before running apply.sh.

# --- Radio-to-band mapping --------------------------------------------------
# OpenWrt does not guarantee radio0=2.4G. Verify with scripts/preflight.sh.
RADIO_2G="radio0"
RADIO_5G="radio1"
# Required ISO 3166-1 alpha-2 code for the router's operating country.
# Leaving it empty makes preflight/apply fail to prevent unlawful radio settings.
WIFI_COUNTRY=""

# --- Hardware limits --------------------------------------------------------
# Maximum BSSIDs per radio; verify with `iw list` under valid interface combinations.
BSSID_LIMIT=16

# --- Networking -------------------------------------------------------------
# Third subnet octet = NET_BASE + idx; for example 10 + 1 gives 192.168.11.0/24.
NET_BASE=10
# sing-box TPROXY port = TPROXY_PORT_BASE + idx.
TPROXY_PORT_BASE=12000
# Firewall mark and routing table used by TPROXY.
TPROXY_MARK=1
TPROXY_TABLE=100
TPROXY_RULE_PRIORITY=10000
TPROXY_MARK_MASK=255

# v0.2 proxies IPv4 only. `disable` turns off RA/DHCPv6 on sbproxy SSIDs to prevent bypass.
IPV6_MODE="disable"

# --- Firewall ---------------------------------------------------------------
# Guest-zone input policy. ACCEPT keeps DHCP/DNS and TPROXY reliable while separate
# rules block admin ports. Use REJECT only after adding DHCP/DNS permits and testing.
ZONE_INPUT="ACCEPT"
# Router administration ports blocked from guest zones.
ADMIN_PORTS="22 80 443"

# --- Wi-Fi defaults ---------------------------------------------------------
WIFI_ENCRYPTION="psk2"     # Use `sae` for WPA3 or `sae-mixed` for transition mode.

# --- Paths ------------------------------------------------------------------
SINGBOX_CONF="/etc/sing-box/config.json"
NFT_FILE="/etc/sbproxy.nft"
BACKUP_DIR="/root/sbproxy-backups"

# --- STUN/TURN ports blocked for WebRTC leak mitigation --------------------
STUN_TCP_PORTS="3478, 3479, 5349, 5350"
STUN_UDP_PORTS="3478, 3479, 5349, 5350, 19302-19309"
