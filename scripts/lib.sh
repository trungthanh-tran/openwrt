# lib.sh — shared helpers and generators. POSIX sh for BusyBox ash.
# shellcheck shell=sh

# --- Resolve paths ----------------------------------------------------------
SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
CONF="${CONF:-$SB_ROOT/config/wifi-socks.conf}"
SETTINGS="${SETTINGS:-$SB_ROOT/config/settings.sh}"

# shellcheck source=/dev/null
[ -f "$SETTINGS" ] && . "$SETTINGS"

# --- Logging ----------------------------------------------------------------
log()  { printf '[sbproxy] %s\n' "$*" >&2; }
warn() { printf '[sbproxy][WARN] %s\n' "$*" >&2; }
die()  { printf '[sbproxy][ERR] %s\n' "$*" >&2; exit 1; }

# DRYRUN=1 prints mutating commands instead of executing them.
run() {
  # shellcheck disable=SC2294  # Commands are intentionally stored as strings for DRYRUN logging.
  if [ "${DRYRUN:-0}" = "1" ]; then printf 'DRYRUN> %s\n' "$*" >&2
  else eval "$@"; fi
}

require_root() { [ "$(id -u)" = "0" ] || die "This command must be run as root."; }
require_conf() { [ -f "$CONF" ] || die "Missing configuration: $CONF (copy from config/wifi-socks.conf.example)"; }

validate_platform() {
  board="$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
  model="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000' || true)"
  case "$board:$model" in
    glinet,gl-mt6000:*|*:*GL-MT6000*) : ;;
    *) die "Unsupported device: board=${board:-?}, model=${model:-?} (GL-MT6000 required)." ;;
  esac
  [ -z "$(cat /etc/glversion 2>/dev/null)" ] || warn "GL.iNet OEM firmware detected; support is experimental and requires separate testing."
}

validate_settings() {
  case "${WIFI_COUNTRY:-}" in
    [A-Z][A-Z]) : ;;
    *) die "WIFI_COUNTRY must be a two-letter uppercase country code in config/settings.sh (for example, VN)." ;;
  esac
  [ "${IPV6_MODE:-disable}" = "disable" ] || die "v0.2 only supports IPV6_MODE=disable."
}

validate_conf() {
  awk -F'|' -v net_base="${NET_BASE:-10}" -v port_base="${TPROXY_PORT_BASE:-12000}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^#/ || /^[[:space:]]*$/ { next }
    NF != 10 && NF != 11 { printf "line %d: expected 10 or 11 columns, found %d\n", NR, NF; bad=1; next }
    {
      idx=trim($3); port=trim($6); band=trim($2); iso=trim($9); web=trim($10); host=trim($5)
      oui=(NF==11)?trim($11):""
      if (oui != "" && oui !~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) { printf "line %d: mac_oui must use the AA:BB:CC format or be empty\n", NR; bad=1 }
      # BusyBox awk can retain trim() results as pure strings and perform a
      # lexical comparison (for example, "3" > "200").  Coerce validated
      # decimal fields before every bounds check so adding IDX 3+ and using
      # ports beginning with 7-9 works the same on OpenWrt and workstation awk.
      idx_num=idx+0; port_num=port+0
      if (idx !~ /^[1-9][0-9]*$/ || idx_num > 200) { printf "line %d: invalid idx\n", NR; bad=1 }
      if (idx ~ /^[1-9][0-9]*$/ && (net_base + idx_num > 254 || port_base + idx_num > 65535)) { printf "line %d: idx makes the subnet/port exceed its valid range\n", NR; bad=1 }
      if (port !~ /^[0-9]+$/ || port_num < 1 || port_num > 65535) { printf "line %d: invalid port\n", NR; bad=1 }
      if (band != "2g" && band != "5g") { printf "line %d: band must be 2g or 5g\n", NR; bad=1 }
      if (iso !~ /^[01]$/ || web !~ /^[01]$/) { printf "line %d: isolate/webrtc must be 0 or 1\n", NR; bad=1 }
      if (length($1) < 1 || length($1) > 32) { printf "line %d: SSID must be 1..32 UTF-8 bytes long\n", NR; bad=1 }
      if (length($4) < 8 || length($4) > 63) { printf "line %d: Wi-Fi password must be 8..63 UTF-8 bytes long\n", NR; bad=1 }
      if (host == "") { printf "line %d: sock_host is empty\n", NR; bad=1 }
      else if (length(host) > 253 || host !~ /^[A-Za-z0-9._:-]+$/) { printf "line %d: invalid sock_host\n", NR; bad=1 }
      if (length($7) > 255 || length($8) > 255) { printf "line %d: SOCKS user/pass may be at most 255 bytes\n", NR; bad=1 }
      if ($1 ~ /[[:cntrl:]|]/ || $4 ~ /[[:cntrl:]|]/ || $5 ~ /[[:cntrl:]|]/ || $7 ~ /[[:cntrl:]|]/ || $8 ~ /[[:cntrl:]|]/) { printf "line %d: field contains a forbidden or control character\n", NR; bad=1 }
      seen[idx]++; if (seen[idx] > 1) { printf "line %d: duplicate idx %s\n", NR, idx; bad=1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$CONF" || die "wifi-socks.conf is invalid."
}

# --- Client / device management helpers ------------------------------------
# Print "<section> <ifname>" (e.g. "w1 phy0-ap0") for every running wifi-iface.
wifi_ifaces() {
  ubus call network.wireless status 2>/dev/null \
    | jq -r 'to_entries[].value.interfaces[]? | "\(.section) \(.ifname)"' 2>/dev/null \
    | awk 'NF==2 && $1 ~ /^w[0-9]+$/'
}

# Runtime ifname for one managed idx (empty when the SSID is down).
ifname_of_idx() {
  wifi_ifaces | awk -v s="w$1" '$1==s { print $2; exit }'
}

# Space-separated banned MACs for one idx from BANS_FILE (lines: idx|mac).
bans_for_idx() {
  f="${BANS_FILE:-/etc/sbproxy.bans}"
  [ -f "$f" ] || return 0
  awk -F'|' -v i="$1" '$1==i && $2!="" { print tolower($2) }' "$f" | sort -u
}

# Re-apply MAC filters from BANS_FILE onto every desired SSID. Runs after the
# main `uci batch` in apply.sh so bans persist across re-applies.
apply_bans() {
  desired_idx | while read -r idx; do
    [ -n "$idx" ] || continue
    uci -q delete "wireless.w$idx.maclist" 2>/dev/null || true
    b="$(bans_for_idx "$idx")"
    if [ -n "$b" ]; then
      uci set "wireless.w$idx.macfilter=deny"
      for m in $b; do uci add_list "wireless.w$idx.maclist=$m"; done
    else
      uci -q delete "wireless.w$idx.macfilter" || true
      uci -q delete "wireless.w$idx.maclist" || true
    fi
  done
  uci commit wireless
}

# Band (2g/5g) configured for one idx, from CONF.
band_of_idx() {
  awk -F'|' -v i="$1" '!/^#/ { g=$3; gsub(/[[:space:]]/,"",g); if (g==i) { b=$2; gsub(/[[:space:]]/,"",b); print b; exit } }' "$CONF"
}

# --- Values derived from the Wi-Fi index -----------------------------------
net_octet()    { echo $(( NET_BASE + $1 )); }         # 192.168.<octet>.0/24
tproxy_port()  { echo $(( TPROXY_PORT_BASE + $1 )); }
radio_of() { case "$1" in 2g) echo "$RADIO_2G";; 5g) echo "$RADIO_5G";; *) die "invalid band: $1";; esac; }

# --- Radio discovery --------------------------------------------------------
# Boards differ in how many radios they carry and in which one holds which
# band, so read them from UCI instead of assuming radio0=2.4G. Every `uci -q
# get` is guarded: it exits non-zero for anything absent, and callers run under
# `set -e`.
list_radios() {
  uci -q show wireless 2>/dev/null \
    | sed -n "s/^wireless\.\([^.=]*\)='\{0,1\}wifi-device'\{0,1\}$/\1/p" | tr '\n' ' '
}

# Band of one radio section: 2g, 5g, 6g, or ? when it cannot be determined.
radio_band() {
  _band="$(uci -q get "wireless.$1.band" || true)"
  case "$_band" in 2g|5g|6g) echo "$_band"; return 0 ;; esac
  case "$(uci -q get "wireless.$1.hwmode" || true)" in
    11ng*|11g*|*11g) echo "2g" ;;
    11a*|11na*) echo "5g" ;;   # 11a, 11ac, 11ax and 11na all live on 5 GHz
    *) echo "?" ;;
  esac
}

# First radio serving $1 (2g|5g|6g), or nothing when the board has none.
radio_for_band() {
  for _radio in $(list_radios); do
    if [ "$(radio_band "$_radio")" = "$1" ]; then echo "$_radio"; return 0; fi
  done
  return 0
}

# Compare one settings.sh radio choice with the hardware.
#   $1 = band (2g|5g)  $2 = configured section  $3 = variable name
# Prints an [OK] line when they agree and warns with the right value otherwise.
check_radio_mapping() {
  _radios=" $(list_radios) "
  _detected="$(radio_for_band "$1")"
  if [ -z "$2" ]; then
    warn "$3 is not set in config/settings.sh${_detected:+ - this board uses $_detected for $1}"
  elif [ "${_radios#* "$2" }" = "$_radios" ]; then
    warn "$3=$2 does not exist on this board${_detected:+ - use $_detected}"
  elif [ "$(radio_band "$2")" != "$1" ]; then
    warn "$3=$2 is a $(radio_band "$2") radio, not $1${_detected:+ - use $_detected}"
  else
    echo "  [OK] $3=$2 is the $1 radio."
  fi
}

# Generate a random MAC.
#   gen_mac              -> locally administered, unicast, first octet 02.
#   gen_mac aa:bb:cc     -> given vendor OUI + 3 random octets (impersonates a
#                           common Wi-Fi vendor; OUI first octet is already
#                           globally-unique/unicast).
random_octets() {
  count="$1"
  if command -v hexdump >/dev/null 2>&1; then
    head -c "$count" /dev/urandom | hexdump -v -e '/1 "%u "'
  elif command -v od >/dev/null 2>&1; then
    od -An -tu1 -N "$count" /dev/urandom
  else
    die "hexdump/od is required to generate a random MAC address"
  fi
}

gen_mac() {
  oui="$(printf '%s' "${1:-}" | tr -d ' \r' | tr 'A-Z' 'a-z')"
  if [ -n "$oui" ]; then
    # shellcheck disable=SC2046,SC2183  # intentional word-split supplies three octets
    printf '%s:%02x:%02x:%02x\n' "$oui" \
      $(random_octets 3)
  else
    # shellcheck disable=SC2046,SC2183  # intentional word-split supplies five octets
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
      $(random_octets 5)
  fi
}

uci_dquote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Iterate over valid SSID rows and call:
#   cb name band idx key host port user pass isolate webrtc mac_oui
# mac_oui (column 11) is optional; older 10-column configs pass it empty.
for_each_ssid() {
  _cb="$1"
  while IFS='|' read -r name band idx key host port user pass isolate webrtc mac_oui; do
    case "$name" in ''|\#*) continue;; esac
    [ -n "$idx" ] || { warn "Skipping row with missing idx: $name"; continue; }
    "$_cb" "$name" "$band" "$idx" "$key" "$host" "$port" "$user" "$pass" "${isolate:-1}" "${webrtc:-0}" "$mac_oui"
  done < "$CONF"
}

# --- Duplicate index validation --------------------------------------------
check_unique_idx() {
  dup=$(awk -F'|' '!/^#/ && NF>=3 {gsub(/ /,"",$3); if($3!="") print $3}' "$CONF" \
        | sort | uniq -d)
  [ -z "$dup" ] || die "duplicate idx in configuration: $dup"
}

# --- BSSID limit warning ----------------------------------------------------
check_bssid_limit() {
  c2=$(awk -F'|' '!/^#/ && $2 ~ /2g/ {n++} END{print n+0}' "$CONF")
  c5=$(awk -F'|' '!/^#/ && $2 ~ /5g/ {n++} END{print n+0}' "$CONF")
  log "SSID count: 2.4G=$c2, 5G=$c5 (limit per band = $BSSID_LIMIT)"
  [ "$c2" -le "$BSSID_LIMIT" ] || warn "2.4G ($c2) EXCEEDS the BSSID limit ($BSSID_LIMIT) -> some APs may fail or remain unavailable."
  [ "$c5" -le "$BSSID_LIMIT" ] || warn "5G ($c5) EXCEEDS the BSSID limit ($BSSID_LIMIT) -> some APs may fail or remain unavailable."
}

# ---------------------------------------------------------------------------
# Emit UCI commands for one SSID to stdout for `uci batch`.
# Keep an existing MAC stable across applies; generate one only when absent.
# ---------------------------------------------------------------------------
emit_uci_one() {
  name="$1"; band="$2"; idx="$3"; key="$4"; isolate="$9"
  mac_oui="$(printf '%s' "${11}" | tr -d ' \r' | tr 'A-Z' 'a-z')"
  name_q="$(uci_dquote "$name")"; key_q="$(uci_dquote "$key")"
  radio="$(radio_of "$band")"
  octet="$(net_octet "$idx")"
  mac="$(uci -q get "wireless.w$idx.macaddr" 2>/dev/null || true)"
  # Keep an existing MAC stable, but regenerate when absent or when a vendor
  # OUI is requested and the current MAC does not already start with it, so
  # changing the vendor dropdown actually takes effect on the next apply.
  if [ -z "$mac" ]; then
    mac="$(gen_mac "$mac_oui")"
  elif [ -n "$mac_oui" ]; then
    case "$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" in
      "$mac_oui":*) : ;;
      *) mac="$(gen_mac "$mac_oui")" ;;
    esac
  fi

  # network: bridge device + interface L3
  cat <<EOF
set network.brw$idx=device
set network.brw$idx.name=br-w$idx
set network.brw$idx.type=bridge
set network.w$idx=interface
set network.w$idx.proto=static
set network.w$idx.device=br-w$idx
set network.w$idx.ipaddr=192.168.$octet.1
set network.w$idx.netmask=255.255.255.0
set dhcp.w$idx=dhcp
set dhcp.w$idx.interface=w$idx
set dhcp.w$idx.start=100
set dhcp.w$idx.limit=100
set dhcp.w$idx.leasetime=12h
set dhcp.w$idx.dhcpv6=disabled
set dhcp.w$idx.ra=disabled
set dhcp.w$idx.ndp=disabled
set firewall.z$idx=zone
set firewall.z$idx.name=z$idx
set firewall.z$idx.network=w$idx
set firewall.z$idx.input=$ZONE_INPUT
set firewall.z$idx.output=ACCEPT
set firewall.z$idx.forward=REJECT
set wireless.w$idx=wifi-iface
set wireless.w$idx.device=$radio
set wireless.w$idx.mode=ap
set wireless.w$idx.network=w$idx
set wireless.w$idx.ssid="$name_q"
set wireless.w$idx.encryption=$WIFI_ENCRYPTION
set wireless.w$idx.key="$key_q"
set wireless.w$idx.isolate=$isolate
set wireless.w$idx.macaddr=$mac
set wireless.w$idx.disabled=0
EOF

  # Block router administration ports from a guest zone when input is ACCEPT.
  if [ "$ZONE_INPUT" = "ACCEPT" ]; then
    cat <<EOF
set firewall.z${idx}adm=rule
set firewall.z${idx}adm.name=block-admin-w$idx
set firewall.z${idx}adm.src=z$idx
set firewall.z${idx}adm.dest_ip=192.168.$octet.1
set firewall.z${idx}adm.proto=tcp
set firewall.z${idx}adm.target=REJECT
set firewall.z${idx}adm.dest_port="$ADMIN_PORTS"
EOF
  fi
}

# Fail closed if a generated admin-port rule is not limited to the gateway of
# its managed SSID. TPROXY traffic is delivered through the firewall INPUT
# path, so an unscoped dport 80/443 reject would also block proxied websites.
# apply.sh calls this for both CLI applies and Agent/UI applies.
validate_admin_rule_scope() {
  batch="$1"
  [ -f "$batch" ] || die "Missing UCI batch for admin-rule validation: $batch"
  [ "$ZONE_INPUT" = "ACCEPT" ] || return 0

  for idx in $(desired_idx); do
    octet="$(net_octet "$idx")"
    expected_ip="set firewall.z${idx}adm.dest_ip=192.168.$octet.1"
    expected_ports="set firewall.z${idx}adm.dest_port=\"$ADMIN_PORTS\""
    grep -qxF "$expected_ip" "$batch" \
      || die "admin rule w$idx must restrict dest_ip=192.168.$octet.1"
    grep -qxF "$expected_ports" "$batch" \
      || die "admin rule w$idx must overwrite dest_port=\"$ADMIN_PORTS\""
    if grep -q "^add_list firewall\.z${idx}adm\.dest_port=" "$batch"; then
      die "admin rule w$idx must not use add_list for dest_port (it accumulates on every apply)"
    fi
  done
}

# ---------------------------------------------------------------------------
# The generated config uses modern (1.12+) syntax. SINGBOX_COMPAT_ENV is an
# escape hatch for future ENABLE_DEPRECATED_* flags; empty means none needed.
# ---------------------------------------------------------------------------
singbox_check() {
  # shellcheck disable=SC2086  # word-splitting of the flag list is intended
  env ${SINGBOX_COMPAT_ENV:-} sing-box check -c "$1"
}

# The modern DNS config (fakeip server type, rule actions) needs sing-box 1.12+.
require_singbox_version() {
  v="$(sing-box version 2>/dev/null | head -1 | sed 's/.*version \([0-9][0-9.]*\).*/\1/')"
  [ -n "$v" ] || { warn "Could not read the sing-box version; continuing."; return 0; }
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  if [ "$maj" -lt 1 ] || { [ "$maj" -eq 1 ] && [ "$min" -lt 12 ]; }; then
    die "sing-box >= 1.12 is required (found $v): the configuration uses the new DNS syntax."
  fi
}

# The packaged procd init script has no env hook, so inject a
# `procd_set_param env` line after its command line. Idempotent; re-run after
# every apply because package upgrades rewrite the file. When the flag list is
# empty, remove any line injected by an older version instead.
ensure_singbox_compat_env() {
  initf="/etc/init.d/sing-box"
  if [ -z "${SINGBOX_COMPAT_ENV:-}" ]; then
    [ -f "$initf" ] && [ "${DRYRUN:-0}" != "1" ] && sed -i '/procd_set_param env ENABLE_DEPRECATED/d' "$initf"
    return 0
  fi
  [ -f "$initf" ] || { warn "$initf was not found; skipping the service compatibility environment."; return 0; }
  if [ "${DRYRUN:-0}" = "1" ]; then
    printf 'DRYRUN> insert "procd_set_param env %s" into %s\n' "$SINGBOX_COMPAT_ENV" "$initf" >&2
    return 0
  fi
  grep -q 'procd_set_param command' "$initf" || { warn "$initf does not use procd; add env $SINGBOX_COMPAT_ENV manually."; return 0; }
  sed -i '/procd_set_param env ENABLE_DEPRECATED/d' "$initf"
  sed -i "/procd_set_param command/a\\	procd_set_param env $SINGBOX_COMPAT_ENV" "$initf"
  log "Inserted the compatibility environment into $initf"
}

# ---------------------------------------------------------------------------
# Generate /etc/sing-box/config.json
# ---------------------------------------------------------------------------
build_singbox() {
  # Defaults keep older settings.sh copies (without these vars) working.
  FAKEIP_RANGE="${FAKEIP_RANGE:-198.18.0.0/15}"
  SINGBOX_LOG_LEVEL="${SINGBOX_LOG_LEVEL:-warn}"
  # Persist the fakeip<->hostname map across sing-box restarts (e.g. set-sock.sh)
  # so clients holding cached fake-IPs keep working without a fresh DNS query.
  SINGBOX_CACHE="${SINGBOX_CACHE:-/etc/sing-box/cache.db}"
  inbounds=""; outbounds=""; rules=""; sep=""
  _sb_row() {
    name="$1"; idx="$3"; host="$5"; port="$6"; user="$7"; pass="$8"
    tp="$(tproxy_port "$idx")"
    inbounds="$inbounds$sep{\"type\":\"tproxy\",\"tag\":\"in-w$idx\",\"listen\":\"0.0.0.0\",\"listen_port\":$tp}"
    host_json="$(jq -Rn --arg v "$host" '$v')"
    if [ -n "$user" ]; then
      user_json="$(jq -Rn --arg v "$user" '$v')"; pass_json="$(jq -Rn --arg v "$pass" '$v')"
      auth=",\"username\":$user_json,\"password\":$pass_json"
    else auth=""; fi
    # Use TCP-only SOCKS upstreams. UDP/QUIC is blocked in nftables so web
    # clients fall back to TCP HTTP/HTTPS, which all SOCKS5 providers support.
    outbounds="$outbounds$sep{\"type\":\"socks\",\"tag\":\"out-w$idx\",\"server\":$host_json,\"server_port\":$port,\"version\":\"5\",\"network\":\"tcp\"$auth}"
    rules="$rules$sep{\"inbound\":[\"in-w$idx\"],\"action\":\"sniff\",\"timeout\":\"1s\"}"
    sep=","
    rules="$rules$sep{\"inbound\":[\"in-w$idx\"],\"outbound\":\"out-w$idx\"}"
    sep=","
  }
  for_each_ssid _sb_row

  mkdir -p "$(dirname "$SINGBOX_CONF")"
  # Fake-IP DNS: return fake IPs to clients and map them back to hostnames on connect,
  # ensuring that SOCKS outbounds always receive hostnames (remote resolution), not real IPs.
  # - Block HTTPS/SVCB (types 65/64): their real-IP hints could let browsers bypass
  #   fake IPs and connect using raw IP addresses, which SOCKS would reject.
  # - Do not provide inet6_range: SSID networks are IPv4-only, so AAAA returns an empty
  #   NOERROR response and clients do not attempt to use unroutable fake IPv6 addresses.
  cat > "$SINGBOX_CONF" <<EOF
{
  "log": { "level": "$SINGBOX_LOG_LEVEL", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "fakeip", "tag": "fakeip", "inet4_range": "$FAKEIP_RANGE" },
      { "type": "udp", "tag": "upstream", "server": "1.1.1.1" }
    ],
    "rules": [
      { "query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOTIMP" },
      { "query_type": ["A", "AAAA"], "action": "route", "server": "fakeip" }
    ],
    "final": "upstream",
    "reverse_mapping": true
  },
  "inbounds": [ $inbounds ],
  "outbounds": [
    $outbounds${outbounds:+,}
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [ { "action": "sniff", "timeout": "1s" }, { "protocol": "dns", "action": "hijack-dns" }, $rules ],
    "default_domain_resolver": "upstream",
    "final": "direct"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "$SINGBOX_CACHE", "store_fakeip": true }
  }
}
EOF
  log "Wrote $SINGBOX_CONF"
}

desired_idx() {
  awk -F'|' '!/^#/ && (NF==10 || NF==11) { gsub(/[[:space:]]/,"",$3); if ($3 != "") print $3 }' "$CONF" | sort -n -u
}

emit_stale_uci() {
  current="$(desired_idx | tr '\n' ' ')"
  old="$(cat "${MANAGED_FILE:-/etc/sbproxy.managed}" 2>/dev/null || true)"
  for idx in $old; do
    case " $current " in *" $idx "*) continue ;; esac
    for section in "wireless.w$idx" "network.w$idx" "network.brw$idx" "dhcp.w$idx" \
                   "firewall.z$idx" "firewall.z${idx}adm"; do
      echo "delete $section"
    done
  done
}

# ---------------------------------------------------------------------------
# Generate /etc/sbproxy.nft: per-interface TPROXY and per-zone WebRTC blocking.
# ---------------------------------------------------------------------------
build_nft() {
  # Bypass SOCKS server IPs so the proxy's own connection is not intercepted.
  sock_bypass=""
  webrtc_rules=""
  udp443_rules=""
  tproxy_rules=""
  dns_rules=""
  _nft_row() {
    idx="$3"; host="$5"; webrtc="${10}"
    tp="$(tproxy_port "$idx")"
    # bypass sock host
    case "$host" in
      *[!0-9.]*) : ;;  # Hostname: skip the IP bypass; sing-box resolves it.
      *) sock_bypass="$sock_bypass    ip daddr $host return\n" ;;
    esac
    # Hijack DNS into sing-box before the local-net bypass so fake-IP answers
    # replace dnsmasq for proxied SSIDs (including hardcoded public resolvers).
    dns_rules="$dns_rules    iifname \"br-w$idx\" udp dport 53 tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    dns_rules="$dns_rules    iifname \"br-w$idx\" tcp dport 53 tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    # Most upstream SOCKS5 endpoints do not implement UDP ASSOCIATE. Drop
    # QUIC/HTTP3 so browsers fall back to TCP/HTTPS through SOCKS5.
    udp443_rules="$udp443_rules    iifname \"br-w$idx\" udp dport 443 drop\n"
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto tcp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    tproxy_rules="$tproxy_rules    iifname \"br-w$idx\" meta l4proto udp tproxy ip to :$tp meta mark set $TPROXY_MARK accept\n"
    if [ "$webrtc" = "1" ]; then
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" tcp dport { $STUN_TCP_PORTS } drop\n"
      webrtc_rules="$webrtc_rules    iifname \"br-w$idx\" udp dport { $STUN_UDP_PORTS } drop\n"
    fi
  }
  for_each_ssid _nft_row

  {
    echo "# GENERATED by sbproxy build_nft — DO NOT EDIT; this file is overwritten."
    echo "table inet sbproxy {"
    echo "  chain webrtc {"
    echo "    type filter hook forward priority filter; policy accept;"
    printf "%b" "$webrtc_rules"
    echo "  }"
    echo "  chain prerouting {"
    echo "    type filter hook prerouting priority mangle; policy accept;"
    echo "    # Hijack DNS from proxied SSIDs into sing-box (fake-IP), ahead of the local-net bypass."
    printf "%b" "$dns_rules"
    echo "    # Do not proxy local or multicast traffic."
    echo "    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return"
    echo "    # Bypass SOCKS servers through the WAN."
    printf "%b" "$sock_bypass"
    echo "    # Drop QUIC/HTTP3; force TCP/HTTPS through SOCKS5."
    printf "%b" "$udp443_rules"
    echo "    # Send each Wi-Fi to its matching sing-box TPROXY port."
    printf "%b" "$tproxy_rules"
    echo "  }"
    echo "}"
  } > "$NFT_FILE"
  log "Wrote $NFT_FILE"
}
