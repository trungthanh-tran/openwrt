#!/bin/sh
# preflight.sh — read-only hardware and environment checks before apply.
set -e
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

validate_platform

echo "==== 1. Device and firmware ===="
[ -f /etc/openwrt_release ] && cat /etc/openwrt_release || warn "/etc/openwrt_release was not found — is this OpenWrt?"
cat /proc/device-tree/model 2>/dev/null && echo || true

echo; echo "==== 2. Radio-to-band mapping (compare with config/settings.sh) ===="
# Radio names, bands and the settings.sh mapping all come from UCI (see the
# radio helpers in lib.sh), so this works on any number of radios in any order.
RADIOS="$(list_radios)"
if [ -z "$RADIOS" ]; then
  warn "No wifi-device section found in UCI — is the wireless driver installed?"
else
  for r in $RADIOS; do
    echo "  $r -> band=$(radio_band "$r") \
hwmode=$(uci -q get "wireless.$r.hwmode" || echo '-') \
path=$(uci -q get "wireless.$r.path" || echo '-')"
  done
  check_radio_mapping 2g "${RADIO_2G:-}" RADIO_2G
  check_radio_mapping 5g "${RADIO_5G:-}" RADIO_5G
fi

echo; echo "==== 3. BSSID limit (maximum APs per radio) ===="
if command -v iw >/dev/null 2>&1; then
  iw list 2>/dev/null | grep -A3 "valid interface combinations" || warn "iw returned no interface combinations."
else
  warn "'iw' is missing — install the iw-full package with apk or opkg."
fi

echo; echo "==== 4. RAM/flash ===="
free 2>/dev/null | grep -i mem || true
df -h / /tmp /overlay 2>/dev/null || true

echo; echo "==== 5. Required packages ===="
for p in sing-box nftables kmod-nft-tproxy ip-full iw-full jq; do
  if command -v apk >/dev/null 2>&1; then installed="$(apk list -I "$p" 2>/dev/null || true)"
  else installed="$(opkg list-installed "$p" 2>/dev/null || true)"; fi
  if [ -n "$installed" ]; then echo "  [OK] $p"; else echo "  [MISSING] $p"; fi
done

echo; echo "==== 6. DHCP hook ===="
_dhcpscript="$(uci -q get dhcp.@dnsmasq[0].dhcpscript || true)"
case "$(dhcp_hook_state "$_dhcpscript")" in
  ours)  echo "  [OK] dnsmasq calls $DHCP_HOOK, so devices are pinned as their lease is handed out." ;;
  unset) echo "  [INFO] dhcpscript is unset; apply.sh will point it at $DHCP_HOOK." ;;
  foreign)
    warn "dnsmasq already calls '$_dhcpscript'. It will NOT be replaced, because that script would stop running."
    warn "Devices will still be pinned by sbproxy-assignd, roughly \${POOL_SCAN_INTERVAL:-3}s after they join."
    warn "To use the faster path, chain $DHCP_HOOK from '$_dhcpscript' yourself."
    ;;
esac

echo; echo "==== 7. Config ===="
if [ -f "$CONF" ]; then validate_settings; validate_conf; validate_pools; check_unique_idx; check_bssid_limit; echo "  [OK] $CONF is valid."
else warn "$CONF does not exist — copy it from config/wifi-socks.conf.example"; fi

echo; echo "Preflight complete. Review all [MISSING]/[WARN] items above before running apply.sh."
