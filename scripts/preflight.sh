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
if command -v wifi >/dev/null 2>&1; then
  for r in radio0 radio1 radio2; do
    b=$(uci -q get wireless.$r.band); h=$(uci -q get wireless.$r.hwmode)
    [ -n "$b$h" ] && echo "  $r -> band=${b:-?} hwmode=${h:-?}"
  done
fi
warn "Set RADIO_2G/RADIO_5G in settings.sh to match the table above."

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
  if command -v apk >/dev/null 2>&1; then installed="$(apk list -I "$p" 2>/dev/null)"
  else installed="$(opkg list-installed "$p" 2>/dev/null)"; fi
  if [ -n "$installed" ]; then echo "  [OK] $p"; else echo "  [MISSING] $p"; fi
done

echo; echo "==== 6. Config ===="
if [ -f "$CONF" ]; then validate_settings; validate_conf; check_unique_idx; check_bssid_limit; echo "  [OK] $CONF is valid."
else warn "$CONF does not exist — copy it from config/wifi-socks.conf.example"; fi

echo; echo "Preflight complete. Review all [MISSING]/[WARN] items above before running apply.sh."
