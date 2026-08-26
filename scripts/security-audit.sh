#!/bin/sh
# Audit local-management exposure and secret permissions without changing state.
set -u

warn=0
report() { printf '[%s] %s\n' "$1" "$2"; }

# proxy-pools.conf holds the credentials of every proxy in every pool, so it
# belongs on this list as much as wifi-socks.conf does.
for file in /etc/sbproxy/token /root/sbproxy/config/wifi-socks.conf \
            /root/sbproxy/config/proxy-pools.conf /etc/sing-box/config.json; do
  [ -e "$file" ] || continue
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
  case "$mode" in 600|400) report OK "$file permissions: $mode" ;; *) report WARN "$file permissions: $mode (expected 600 or 400)"; warn=$((warn + 1)) ;; esac
done

if uci -q show firewall | grep -E "\.src='wan'.*|\.name='.*(SSH|LuCI|sbproxy).*'" >/tmp/sbproxy-security-audit.$$ 2>/dev/null; then
  report WARN 'Review WAN firewall rules that may expose management services:'
  cat /tmp/sbproxy-security-audit.$$
  warn=$((warn + 1))
else
  report OK 'No obvious named WAN management rule was found.'
fi
rm -f /tmp/sbproxy-security-audit.$$

if uci -q get dropbear.@dropbear[0].PasswordAuth 2>/dev/null | grep -qi '^off$'; then
  report OK 'Dropbear password authentication is disabled.'
else
  report WARN 'Dropbear password authentication is enabled or unspecified; configure SSH keys before disabling it.'
  warn=$((warn + 1))
fi

report INFO 'Verify from outside the LAN that ports 22, 80, and 443 are not reachable.'
[ "$warn" -eq 0 ] || exit 1
