# lib.sh — shared helpers and generators. POSIX sh for BusyBox ash.
# shellcheck shell=sh

# --- Resolve paths ----------------------------------------------------------
SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
CONF="${CONF:-$SB_ROOT/config/wifi-socks.conf}"
POOLS="${POOLS:-$SB_ROOT/config/proxy-pools.conf}"
ROUTES="${ROUTES:-$SB_ROOT/config/routing-rules.conf}"
SETTINGS="${SETTINGS:-$SB_ROOT/config/settings.sh}"

# A settings.sh edited on Windows -- or copied there and back by a Windows
# deploy tool -- keeps CRLF line endings, and sourcing such a file hides a
# carriage return at the end of every value: WIFI_COUNTRY becomes "VN<CR>" and
# validation then rejects a file that looks perfectly correct on screen.
# Source a stripped copy instead, and remember it so validate_settings can tell
# the operator where the real problem is.
SETTINGS_CRLF=0
if [ -f "$SETTINGS" ]; then
  if [ -n "$(tr -dc '\r' < "$SETTINGS" 2>/dev/null)" ]; then
    _sb_set_tmp="$(mktemp "${TMPDIR:-/tmp}/sbproxy-settings.XXXXXX" 2>/dev/null || true)"
    if [ -n "$_sb_set_tmp" ] && tr -d '\r' < "$SETTINGS" > "$_sb_set_tmp" 2>/dev/null; then
      SETTINGS_CRLF=1
      # shellcheck source=/dev/null
      . "$_sb_set_tmp"
      rm -f "$_sb_set_tmp"
    else
      [ -z "$_sb_set_tmp" ] || rm -f "$_sb_set_tmp"
      # shellcheck source=/dev/null
      . "$SETTINGS"
    fi
    unset _sb_set_tmp
  else
    # shellcheck source=/dev/null
    . "$SETTINGS"
  fi
fi

# --- Logging ----------------------------------------------------------------
log()  { printf '[sbproxy] %s\n' "$*" >&2; }
warn() { printf '[sbproxy][WARN] %s\n' "$*" >&2; }
die()  { printf '[sbproxy][ERR] %s\n' "$*" >&2; exit 1; }

# Replace every literal occurrence of $2 in $1 with ***. Never mask with sed:
# the secret is data, but sed reads it as a regex and as part of the s|||
# command, so `|`, `[`, `&` or `;` in a real password broke the masking or
# leaked the cleartext. awk index() compares plain bytes only.
mask_secret() { # text secret -> masked text
  if [ -z "$2" ]; then printf '%s' "$1"; return; fi
  printf '%s' "$1" | S="$2" awk '
    { line = $0; masked = ""
      while ((i = index(line, ENVIRON["S"])) > 0) {
        masked = masked substr(line, 1, i - 1) "***"
        line = substr(line, i + length(ENVIRON["S"]))
      }
      print masked line }'
}

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
    *)
      if [ "${ALLOW_UNSUPPORTED_BOARD:-0}" = "1" ]; then
        warn "Unsupported device: board=${board:-?}, model=${model:-?} — continuing because ALLOW_UNSUPPORTED_BOARD=1 (tested on the GL-MT6000 only)."
      else
        die "Unsupported device: board=${board:-?}, model=${model:-?} (GL-MT6000 required; set ALLOW_UNSUPPORTED_BOARD=1 in config/settings.sh to override)."
      fi
      ;;
  esac
  [ -z "$(cat /etc/glversion 2>/dev/null)" ] || warn "GL.iNet OEM firmware detected; support is experimental and requires separate testing."
}

# CRLF in the pipe-separated config files cannot be stripped centrally the way
# settings.sh can -- a dozen awk readers open them directly -- so name the
# problem instead of letting it surface as a stray control character.
check_crlf() {
  [ -f "$1" ] || return 0
  [ -n "$(tr -dc '\r' < "$1" 2>/dev/null)" ] || return 0
  warn "$2 has Windows (CRLF) line endings; values end with a carriage return. Fix it with: sed -i 's/\r\$//' $1"
}

# Whether apply should set a country on the radios at all. An empty
# WIFI_COUNTRY leaves whatever OpenWrt has in place: the project never clears a
# regulatory setting it cannot supply.
radio_country_set() { case "${WIFI_COUNTRY:-}" in [A-Z][A-Z]) return 0 ;; *) return 1 ;; esac; }

validate_settings() {
  # Without this file every setting reads as unset, and the first one checked
  # (WIFI_COUNTRY) took the blame for it.
  [ -f "$SETTINGS" ] || die "Settings file not found: $SETTINGS (copy config/settings.sh from the package, or re-push the code)."
  [ "${SETTINGS_CRLF:-0}" = "1" ] && warn "config/settings.sh has Windows (CRLF) line endings; it was read without them. Fix it once with: sed -i 's/\r\$//' $SETTINGS"
  check_crlf "$CONF" "config/wifi-socks.conf"
  check_crlf "$POOLS" "config/proxy-pools.conf"
  # The country code is no longer a gate. Refusing to run over it stopped
  # apply, pool changes, deleting an SSID and reset alike on a router whose
  # settings.sh had merely lost the key, while the radios themselves were
  # perfectly happy. "vn " and "VN" mean the same thing, and an unusable value
  # means "leave the radios' own country alone" -- see radio_country_set.
  WIFI_COUNTRY="$(printf '%s' "${WIFI_COUNTRY:-}" | tr -d ' \r\t' | tr 'a-z' 'A-Z')"
  case "$WIFI_COUNTRY" in
    ''|[A-Z][A-Z]) : ;;
    *) warn "WIFI_COUNTRY='$WIFI_COUNTRY' in $SETTINGS is not a two-letter code; the radios keep the country they already have."
       WIFI_COUNTRY="" ;;
  esac
  [ "${IPV6_MODE:-disable}" = "disable" ] || die "v0.2 only supports IPV6_MODE=disable."
  # Empty means "use the built-in default", the same as everywhere else here.
  case "${DNS_UPSTREAM:-1.1.1.1}" in
    *[!A-Za-z0-9.:_-]*) die "DNS_UPSTREAM may only contain letters, digits, . : _ and -." ;;
  esac
  validate_pool_settings
}

# The pool port block must be internally consistent and must not collide with
# the legacy one-port-per-SSID range. The entire span from POOL_PORT_BASE is
# treated as reserved, which is stricter than the formula strictly needs and
# leaves no room for an off-by-one to become a silent port clash.
validate_pool_settings() {
  _base="${POOL_PORT_BASE:-13000}"
  _stride="${POOL_PORT_STRIDE:-256}"
  _cap="${POOL_SLOTS_PER_SSID_MAX:-256}"
  _legacy="${TPROXY_PORT_BASE:-12000}"
  case "$_base:$_stride:$_cap:$_legacy" in
    *[!0-9:]*) die "POOL_PORT_BASE, POOL_PORT_STRIDE and POOL_SLOTS_PER_SSID_MAX must be integers." ;;
  esac
  # A typo here decides whether unpinned devices are served or cut off, so it
  # fails the run rather than silently picking one of the two.
  case "${POOL_UNASSIGNED:-default}" in
    default|block) : ;;
    *) die "POOL_UNASSIGNED must be default or block." ;;
  esac
  # cap >= 1 together with cap <= stride is what forces stride >= 1; a separate
  # stride floor here would be unreachable.
  [ "$_cap" -ge 1 ] || die "POOL_SLOTS_PER_SSID_MAX must be at least 1."
  [ "$_cap" -le "$_stride" ] || \
    die "POOL_SLOTS_PER_SSID_MAX ($_cap) must not exceed POOL_PORT_STRIDE ($_stride)."
  # Highest port the formula can ever produce: idx=200, slot=stride-1.
  _hi=$(( _base + 200 * _stride + _stride - 1 ))
  [ "$_hi" -le 65535 ] || \
    die "POOL_PORT_BASE=$_base with POOL_PORT_STRIDE=$_stride reaches port $_hi, past 65535."
  if [ "$_base" -le $(( _legacy + 200 )) ] && [ $(( _legacy + 1 )) -le "$_hi" ]; then
    die "The pool port block ($_base..$_hi) overlaps TPROXY_PORT_BASE ($(( _legacy + 1 ))..$(( _legacy + 200 )))."
  fi
}

validate_conf() {
  awk -F'|' -v net_base="${NET_BASE:-10}" -v port_base="${TPROXY_PORT_BASE:-12000}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^#/ || /^[[:space:]]*$/ { next }
    NF != 10 && NF != 11 && NF != 12 { printf "line %d: expected 10, 11 or 12 columns, found %d\n", NR, NF; bad=1; next }
    {
      idx=trim($3); port=trim($6); band=trim($2); iso=trim($9); web=trim($10); host=trim($5)
      oui=(NF==11)?trim($11):""
      if (NF>=11) oui=trim($11)
      proxy_type=(NF==12)?tolower(trim($12)):"socks5"
      if (proxy_type == "") proxy_type="socks5"
      if (proxy_type != "socks5" && proxy_type != "http") { printf "line %d: proxy_type must be socks5 or http\n", NR; bad=1 }
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
      if (iso !~ /^[01]$/) { printf "line %d: isolate must be 0 or 1\n", NR; bad=1 }
      # webrtc: 0 keeps it, 1 blocks STUN/TURN, 2 forces it through the proxy.
      if (web !~ /^[012]$/) { printf "line %d: webrtc must be 0, 1 or 2\n", NR; bad=1 }
      if (length($1) < 1 || length($1) > 32) { printf "line %d: SSID must be 1..32 UTF-8 bytes long\n", NR; bad=1 }
      if (length($4) < 8 || length($4) > 63) { printf "line %d: Wi-Fi password must be 8..63 UTF-8 bytes long\n", NR; bad=1 }
      if ((host == "") != (port == "")) { printf "line %d: sock_host and port must both be empty or both be set\n", NR; bad=1 }
      if (host != "" && (length(host) > 253 || host !~ /^[A-Za-z0-9._:-]+$/)) { printf "line %d: invalid sock_host\n", NR; bad=1 }
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

# `wifi reload` can race the MediaTek driver on the GL-MT6000: hostapd may
# return before the BSS is attached to its bridge, leaving the SSID invisible
# and dnsmasq unable to receive DHCPDISCOVER.  Re-assert the L3 interface,
# bridge and BSS after the reload.  All operations are best-effort so a radio
# that is genuinely unavailable does not make ban/unban/apply fail halfway.
recover_wifi_networks() {
  # Do not ifup individual BSSes or reload hostapd objects on a shared radio.
  # MediaTek can rename phy*-apN while hostapd is being reloaded; that race
  # leaves one BSS at channel 0/NO-CARRIER and makes it invisible.  Let netifd
  # settle first, then recover the whole radio once only when an AP is really
  # missing carrier.
  sleep "${WIFI_RECOVER_WAIT:-4}"
  _rw_bad=0
  for _rw_if in $(iw dev 2>/dev/null | awk '$1 == "Interface" && $2 ~ /^phy[0-9]+-ap[0-9]+$/ { print $2 }'); do
    ip link show "$_rw_if" 2>/dev/null | grep -q 'LOWER_UP' || _rw_bad=1
  done
  if [ "$_rw_bad" = 1 ]; then
    warn "A Wi-Fi AP has no carrier after reload; restarting all radios once to avoid a shared-radio BSS rename race."
    wifi down >/dev/null 2>&1 || true
    sleep 2
    wifi up >/dev/null 2>&1 || true
    sleep "${WIFI_RADIO_RECOVER_WAIT:-6}"
  fi
  for _rw_idx in $(desired_idx); do
    # `wifi up` already recreates the network sections. Calling ifup on an
    # individual BSS here can make netifd rename shared-radio interfaces while
    # hostapd is still attaching them, undoing the radio recovery.
    ip link set "br-w$_rw_idx" up >/dev/null 2>&1 || true
  done
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

# Which SSID an address belongs to, reading net_octet backwards. Prints nothing
# for the router's own LAN or for anything outside the managed range, so a
# caller can treat "no answer" as "not ours".
idx_of_ip() { # ip
  printf '%s' "${1:-}" | awk -F. -v base="${NET_BASE:-10}" '
    NF == 4 && $1 == "192" && $2 == "168" && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
      idx = $3 - base
      if (idx >= 1 && idx <= 200) print idx
    }'
}

# Where dnsmasq must call us from, and whether its current setting is free to
# take. Never overwrite a foreign dhcpscript: it belongs to something else that
# would quietly stop running.
DHCP_HOOK="/usr/libexec/sbproxy-dhcp-assign"
dhcp_hook_state() { # current value of dhcp.@dnsmasq[0].dhcpscript
  case "${1:-}" in
    "")           echo unset ;;
    "$DHCP_HOOK") echo ours ;;
    *)            echo foreign ;;
  esac
}

# Point dnsmasq at the hook, unless somebody else already owns dhcpscript.
# Losing the fast path costs a few seconds of pinning latency; breaking another
# script's hook costs whatever that script was for.
wire_dhcp_hook() {
  command -v uci >/dev/null 2>&1 || return 0
  _wd_now="$(uci -q get dhcp.@dnsmasq[0].dhcpscript || true)"
  case "$(dhcp_hook_state "$_wd_now")" in
    ours) return 0 ;;
    foreign)
      warn "Leaving dnsmasq's dhcpscript at '$_wd_now'. Devices will be pinned by sbproxy-assignd instead, a few seconds after they join."
      return 0
      ;;
  esac
  run "uci set dhcp.@dnsmasq[0].dhcpscript='$DHCP_HOOK'"
  run "uci commit dhcp"
  log "dnsmasq will now pin each device as its lease is handed out."
}

# The logical OpenWrt interface that currently owns the IPv4 default route.
# Return the UCI/ubus name (for example wan or wwan), never the kernel device
# name: the packaged sing-box init script consumes logical names in its
# `ifaces` option and restarts the service on interface.*.up.
default_route_interface() {
  command -v ubus >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ubus call network.interface dump 2>/dev/null \
    | jq -r '
        .interface[]?
        | select(.up == true)
        | select(([ (.route // [])[]?
                    | select((.target // "") == "0.0.0.0"
                             and ((.mask // 0) == 0)) ] | length) > 0)
        | (.interface // empty)' 2>/dev/null \
    | head -n 1
}

default_route_ready() {
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 route show default 2>/dev/null | grep -q '^default '
}

# Network reload may return before a Wi-Fi/USB uplink has reacquired its
# lease. Keep the wait bounded: apply must still finish on an intentionally
# offline router, while an ordinary reload gets enough time to avoid starting
# sing-box with "network: missing default interface".
wait_for_default_route() { # [seconds]
  _wdr_left="${1:-${SINGBOX_ROUTE_WAIT:-15}}"
  case "$_wdr_left" in ''|*[!0-9]*) _wdr_left=15 ;; esac
  while [ "$_wdr_left" -gt 0 ]; do
    default_route_ready && return 0
    sleep 1
    _wdr_left=$((_wdr_left - 1))
  done
  default_route_ready
}

# Use the restart trigger already provided by OpenWrt's sing-box init script.
# Persisting the logical uplink fixes the boot race too: sing-box may start
# before DHCP has installed a default route, then gets restarted by procd when
# that interface reaches interface.*.up.
ensure_singbox_uplink_trigger() { # [logical interface]
  command -v uci >/dev/null 2>&1 || return 0
  uci -q get sing-box.main >/dev/null 2>&1 || return 0
  _sut_iface="${1:-$(default_route_interface)}"
  case "$_sut_iface" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  case "$_sut_iface" in w[0-9]*|br-w[0-9]*) return 0 ;; esac
  [ "$(uci -q get sing-box.main.ifaces 2>/dev/null)" = "$_sut_iface" ] && return 0
  run "uci set sing-box.main.ifaces='$_sut_iface'"
  run "uci commit sing-box"
  log "sing-box will restart when uplink $_sut_iface comes up."
}

tproxy_port()  { echo $(( TPROXY_PORT_BASE + $1 )); }
# TPROXY port of one pool slot: pool_port <idx> <slot>.
pool_port()    { echo $(( ${POOL_PORT_BASE:-13000} + $1 * ${POOL_PORT_STRIDE:-256} + $2 )); }
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
#   cb name band idx key host port user pass isolate webrtc mac_oui proxy_type
# Columns 11/12 are optional; legacy rows default to an empty OUI and SOCKS5.
for_each_ssid() {
  _cb="$1"
  while IFS='|' read -r name band idx key host port user pass isolate webrtc mac_oui proxy_type extra; do
    case "$name" in ''|\#*) continue;; esac
    [ -z "$extra" ] || { warn "Skipping row with too many columns: $name"; continue; }
    [ -n "$idx" ] || { warn "Skipping row with missing idx: $name"; continue; }
    "$_cb" "$name" "$band" "$idx" "$key" "$host" "$port" "$user" "$pass" "${isolate:-1}" "${webrtc:-0}" "$mac_oui" "${proxy_type:-socks5}"
  done < "$CONF"
}

# --- Proxy pool -------------------------------------------------------------
# config/proxy-pools.conf gives one SSID several proxies. Format, one per line:
#   idx|proxy_type|host|port|user|pass|label      (label optional)
# The slot number is the row's position within its idx, counted from zero, so
# rows must never be reordered without also remapping /etc/sbproxy.assign.
#
# An absent file, or an idx with no rows, means that SSID has no proxy route.
# SSIDs are pool-only; there is no wifi-socks.conf fallback.

# Normalised rows of one idx: slot|type|host|port|user|pass|label
pool_rows() {
  [ -f "${POOLS:-}" ] || return 0
  awk -F'|' -v want="$1" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 6 || NF > 7 { next }
    trim($1) != want { next }
    # User and password are passed through untrimmed: leading or trailing
    # spaces are legal in a credential and are not ours to silently drop.
    { printf "%d|%s|%s|%s|%s|%s|%s\n", n++, tolower(trim($2)), trim($3), trim($4),
             $5, $6, (NF >= 7 ? trim($7) : "") }
  ' "$POOLS"
}

# Every idx that has at least one proxy, in numeric order and without repeats.
# Read from the pool file rather than from wifi-socks.conf: an SSID with no pool
# has nothing for the assignment machinery to do.
pooled_idxs() {
  [ -f "${POOLS:-}" ] || return 0
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 6 || NF > 7 { next }
    { i = trim($1); if (i ~ /^[1-9][0-9]*$/ && !(i in seen)) { seen[i] = 1; print i } }
  ' "$POOLS" | sort -n
}

pool_count() { pool_rows "$1" | awk 'END { print NR + 0 }'; }

# True when idx has at least one pool proxy.
pool_enabled() { [ "$(pool_count "$1")" -gt 0 ]; }

# Iterate over one idx's slots and call:
#   cb slot type host port user pass label
# Reads from a temporary file rather than a pipe: a pipeline would run the loop
# in a subshell and discard whatever the callback accumulates.
for_each_pool() {
  _pool_idx="$1"; _pool_cb="$2"
  _pool_tmp="${TMPDIR:-/tmp}/sbproxy-pool.$$"
  pool_rows "$_pool_idx" > "$_pool_tmp"
  while IFS='|' read -r slot ptype phost pport puser ppass plabel; do
    [ -n "$slot" ] || continue
    "$_pool_cb" "$slot" "$ptype" "$phost" "$pport" "$puser" "$ppass" "$plabel"
  done < "$_pool_tmp"
  rm -f "$_pool_tmp"
}

# Whether a SOCKS5 outbound may relay UDP. Off means "network":"tcp" on every
# socks outbound and a QUIC drop in nftables, which is the pre-UDP behaviour.
socks_udp_enabled() { [ "${SOCKS_UDP:-1}" = "1" ]; }

# Whether the main LAN is a proxied source. It is pool-only: idx 0 of
# proxy-pools.conf holds its proxies, and only a pinned device uses one, so
# turning this on leaves every unpinned wired machine exactly as it was.
lan_proxy_enabled() { [ "${LAN_PROXY:-0}" = "1" ] && pool_enabled 0; }

# --- Traffic stats ----------------------------------------------------------
traffic_stats_enabled() { [ "${TRAFFIC_STATS:-0}" = "1" ]; }

# The clash_api secret, created on first use. It is not in settings.sh because
# that file is committed, and the API can reconfigure sing-box, not just report
# on it — an empty secret would leave that open to anything on the router.
clash_api_secret() {
  _cs_file="${CLASH_API_SECRET_FILE:-/etc/sbproxy/clash-secret}"
  if [ ! -s "$_cs_file" ]; then
    mkdir -p "$(dirname "$_cs_file")" 2>/dev/null || return 1
    _cs_tmp="$_cs_file.tmp.$$"
    # BusyBox carries both, but a stripped image may drop either one.
    ( umask 077
      if command -v hexdump >/dev/null 2>&1; then
        head -c 24 /dev/urandom | hexdump -v -e '/1 "%02x"'
      else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
      fi > "$_cs_tmp" ) 2>/dev/null || { rm -f "$_cs_tmp"; return 1; }
    [ -s "$_cs_tmp" ] || { rm -f "$_cs_tmp"; return 1; }
    chmod 600 "$_cs_tmp" 2>/dev/null || true
    mv "$_cs_tmp" "$_cs_file" || { rm -f "$_cs_tmp"; return 1; }
  fi
  tr -d ' \r\n' < "$_cs_file"
}

# Refuse an external controller that is reachable from the network: it can
# change routing, so exposing it would hand the proxy layer to any LAN client.
validate_traffic_stats() {
  traffic_stats_enabled || return 0
  case "${CLASH_API_LISTEN:-127.0.0.1:9090}" in
    127.0.0.1:*|localhost:*|'[::1]':*) : ;;
    *) die "CLASH_API_LISTEN must stay on localhost; it controls sing-box, not just reports on it." ;;
  esac
  [ -n "$(clash_api_secret 2>/dev/null)" ] \
    || die "Could not create ${CLASH_API_SECRET_FILE:-/etc/sbproxy/clash-secret} for the stats API."
}

# Whether any slot of one idx is an HTTP proxy. An HTTP proxy cannot carry UDP,
# so an SSID that can route a device to one keeps dropping QUIC even when
# SOCKS_UDP is on — otherwise that device's QUIC would reach sing-box and be
# blackholed instead of failing fast enough for the browser to use TCP.
pool_has_http() {
  [ -f "${POOLS:-}" ] || return 1
  pool_rows "$1" | awk -F'|' '$2 == "http" { found = 1 } END { exit found ? 0 : 1 }'
}

# Every pool host, deduplicated — the nftables bypass needs all of them, not
# just the hosts named in wifi-socks.conf.
pool_hosts() {
  [ -f "${POOLS:-}" ] || return 0
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 6 || NF > 7 { next }
    { h = trim($3); if (h != "" && !seen[h]++) print h }
  ' "$POOLS"
}

# --- Device pinning ---------------------------------------------------------
# ASSIGN_FILE records identity by MAC, because a MAC is stable across leases and
# is what an operator recognises. The nftables map, however, is keyed by IPv4:
# a 4-byte key is the only width nftables serves from its fixed-size hash, and
# it avoids depending on the link-layer header being readable in the inet
# prerouting hook. The two are joined here through the DHCP leases.

# Valid assignment rows of one idx: mac|slot
assign_rows() {
  [ -f "${ASSIGN_FILE:-}" ] || return 0
  awk -F'|' -v want="$1" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 3 { next }
    trim($1) != want { next }
    {
      mac = tolower(trim($2)); slot = trim($3)
      if (mac !~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/) next
      if (slot !~ /^[0-9]+$/) next
      if (mac in seen) next          # first row wins, so a stale duplicate cannot flip a device
      seen[mac] = 1
      print mac "|" slot
    }
  ' "$ASSIGN_FILE"
}

# Current IPv4 lease of one MAC, or nothing.
lease_ip_of() {
  [ -f "${LEASES:-/tmp/dhcp.leases}" ] || return 0
  awk -v m="$1" 'tolower($2) == m && $3 ~ /^[0-9.]+$/ { print $3; exit }' \
    "${LEASES:-/tmp/dhcp.leases}"
}

# "ip : port" pairs for one idx's map. A device with no lease, or pinned to a
# slot the pool no longer has, is simply left out: it then falls through to the
# SSID default rule, which is a working proxy rather than no proxy at all.
assign_elements() {
  _ae_idx="$1"
  # Callers only reach this for a pooled SSID, so there is no pool-size guard
  # here; assign_rows has already rejected anything malformed.
  _ae_slots="$(pool_count "$_ae_idx")"
  _ae_tmp="${TMPDIR:-/tmp}/sbproxy-assign.$$"
  assign_rows "$_ae_idx" > "$_ae_tmp"
  _ae_out=""
  while IFS='|' read -r _ae_mac _ae_slot; do
    [ -n "$_ae_mac" ] || continue
    [ "$_ae_slot" -lt "$_ae_slots" ] || continue
    _ae_ip="$(lease_ip_of "$_ae_mac")"
    [ -n "$_ae_ip" ] || continue
    _ae_out="$_ae_out${_ae_out:+, }$_ae_ip : $(pool_port "$_ae_idx" "$_ae_slot")"
  done < "$_ae_tmp"
  rm -f "$_ae_tmp"
  printf '%s' "$_ae_out"
}

# --- Writing the pin state --------------------------------------------------

assign_valid_mac() {
  case "$1" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}

# Pin one device to one slot. Replaces any earlier pin for that device on that
# SSID, so the file can never hold two answers for the same question.
assign_set() { # idx mac slot source(auto|manual)
  _as_idx="$1"
  _as_mac="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
  _as_slot="${3:-}"
  _as_src="${4:-auto}"
  case "$_as_idx" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac
  assign_valid_mac "$_as_mac" || die "invalid MAC address (expected AA:BB:CC:DD:EE:FF)"
  case "$_as_slot" in *[!0-9]*|'') die "slot must be a non-negative integer" ;; esac
  case "$_as_src" in auto|manual) : ;; *) die "source must be auto or manual" ;; esac
  _as_slots="$(pool_count "$_as_idx")"
  [ "$_as_slots" -gt 0 ] || die "Wi-Fi idx=$_as_idx has no proxy pool"
  [ "$_as_slot" -lt "$_as_slots" ] || \
    die "slot $_as_slot does not exist; idx=$_as_idx has $_as_slots proxies (0..$(( _as_slots - 1 )))"

  _as_tmp="${TMPDIR:-/tmp}/sbproxy-assign-w.$$"
  : > "$_as_tmp"
  # grep -v exits 1 when it filters everything out, which would abort a caller
  # running under `set -e`.
  [ -f "${ASSIGN_FILE:-}" ] && { grep -v "^$_as_idx|$_as_mac|" "$ASSIGN_FILE" > "$_as_tmp" || true; }
  printf '%s|%s|%s|%s\n' "$_as_idx" "$_as_mac" "$_as_slot" "$_as_src" >> "$_as_tmp"
  mv "$_as_tmp" "$ASSIGN_FILE"
}

assign_clear() { # idx mac
  [ -f "${ASSIGN_FILE:-}" ] || return 0
  _ac_mac="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
  _ac_tmp="${TMPDIR:-/tmp}/sbproxy-assign-c.$$"
  grep -v "^$1|$_ac_mac|" "$ASSIGN_FILE" > "$_ac_tmp" || true
  mv "$_ac_tmp" "$ASSIGN_FILE"
}

# Bring the state file back in line with the pools. A pin into a slot the pool
# no longer has is moved rather than dropped: dropping it would silently push
# that device onto the shared default proxy, which is the one outcome this
# feature exists to prevent. Pins for an SSID that lost its pool entirely have
# nowhere to go and are removed.
assign_prune() {
  [ -f "${ASSIGN_FILE:-}" ] || return 0
  _ap_tmp="${TMPDIR:-/tmp}/sbproxy-assign-p.$$"
  : > "$_ap_tmp"
  while IFS='|' read -r _ap_idx _ap_mac _ap_slot _ap_src; do
    case "$_ap_idx" in ''|\#*) continue ;; *[!0-9]*) continue ;; esac
    assign_valid_mac "$_ap_mac" || continue
    case "$_ap_slot" in *[!0-9]*|'') continue ;; esac
    _ap_slots="$(pool_count "$_ap_idx")"
    if [ "$_ap_slots" -le 0 ]; then
      log "Dropping pin $_ap_mac on idx=$_ap_idx: that Wi-Fi no longer has a proxy pool"
      continue
    fi
    if [ "$_ap_slot" -ge "$_ap_slots" ]; then
      _ap_new=$(( _ap_slot % _ap_slots ))
      log "Reassigning $_ap_mac on idx=$_ap_idx: slot $_ap_slot is gone, now slot $_ap_new"
      _ap_slot="$_ap_new"; _ap_src=auto
    fi
    printf '%s|%s|%s|%s\n' "$_ap_idx" "$_ap_mac" "$_ap_slot" "${_ap_src:-auto}" >> "$_ap_tmp"
  done < "$ASSIGN_FILE"
  mv "$_ap_tmp" "$ASSIGN_FILE"
}

# Spread devices evenly over an SSID's pool: shuffle, then deal round-robin, so
# the counts differ by at most one and the order is not predictable from the
# MAC list. The seed is reported so a preview and the write that follows it
# cannot disagree.
pool_shuffle_seed() {
  _ps_seed=""
  if command -v cksum >/dev/null 2>&1; then
    _ps_seed="$(head -c 8 /dev/urandom 2>/dev/null | cksum 2>/dev/null \
      | awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }')"
  fi
  [ -n "$_ps_seed" ] || _ps_seed="$(date +%s 2>/dev/null || printf '0')"
  _ps_rand="$(awk 'BEGIN { srand(); print int(rand() * 2147483647) }' </dev/null 2>/dev/null || printf '0')"
  case "$_ps_rand" in *[!0-9]*|'') _ps_rand=0 ;; esac
  printf '%u\n' "$(( _ps_seed ^ $$ ^ _ps_rand ))" 2>/dev/null \
    || printf '%s\n' "$_ps_seed"
}

assign_spread() { # idx "mac mac ..."
  _sp_idx="$1"; _sp_macs="${2:-}"
  _sp_n="$(pool_count "$_sp_idx")"
  [ "$_sp_n" -gt 0 ] || die "Wi-Fi idx=$_sp_idx has no proxy pool"
  [ -n "$_sp_macs" ] || return 0
  _sp_seed="${POOL_SHUFFLE_SEED:-$(pool_shuffle_seed)}"
  _sp_tmp="${TMPDIR:-/tmp}/sbproxy-spread.$$"
  # shellcheck disable=SC2086  # the MAC list is intentionally word-split
  printf '%s\n' $_sp_macs \
    | awk -v seed="$_sp_seed" 'BEGIN { srand(seed) } NF { print rand() "\t" $0 }' \
    | sort | cut -f2- > "$_sp_tmp"
  _sp_j=0
  while read -r _sp_mac; do
    [ -n "$_sp_mac" ] || continue
    assign_set "$_sp_idx" "$_sp_mac" "$(( _sp_j % _sp_n ))" manual
    _sp_j=$(( _sp_j + 1 ))
  done < "$_sp_tmp"
  rm -f "$_sp_tmp"
  log "Spread $_sp_j device(s) over $_sp_n proxies on idx=$_sp_idx (seed $_sp_seed)"
}

# Replace one idx's pool with the rows in $2 (type|host|port|user|pass|label,
# one per line) and carry every pin across by proxy identity.
#
# Slot numbers are positions in the new list, so they move freely. What must not
# move is which proxy a device is using: a pin whose proxy is still in the list
# follows it to its new slot, and a pin whose proxy is gone is reassigned to the
# least-loaded slot and marked auto. Nothing is written until the new pool has
# passed validation.
pool_replace() { # idx newrows-file
  _pr_idx="$1"; _pr_src="$2"
  case "$_pr_idx" in *[!0-9]*|'') die "idx must be a positive integer" ;; esac
  [ -f "$_pr_src" ] || die "no such file: $_pr_src"

  _pr_dir="${TMPDIR:-/tmp}"
  _pr_old="$_pr_dir/sbproxy-pool-old.$$"
  _pr_new="$_pr_dir/sbproxy-pool-new.$$"
  _pr_cand="$_pr_dir/sbproxy-pool-cand.$$"
  _pr_map="$_pr_dir/sbproxy-pool-map.$$"

  pool_rows "$_pr_idx" > "$_pr_old"

  # Prefix each incoming row with the idx, dropping blanks, comments and exact
  # duplicates. First occurrence wins, because slot order follows the list.
  awk -F'|' -v idx="$_pr_idx" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 5 || NF > 6 { print "line " NR ": expected 5 or 6 columns, found " NF > "/dev/stderr"; bad = 1; next }
    {
      key = tolower(trim($1)) "|" trim($2) "|" trim($3) "|" $4 "|" $5
      if (key in seen) next
      seen[key] = 1
      printf "%s|%s|%s|%s|%s|%s|%s\n", idx, tolower(trim($1)), trim($2), trim($3), $4, $5, (NF >= 6 ? trim($6) : "")
    }
    END { exit bad ? 1 : 0 }
  ' "$_pr_src" > "$_pr_new" || { rm -f "$_pr_old" "$_pr_new"; die "the new pool is malformed"; }

  # Build the candidate file: every other idx untouched, this idx replaced.
  : > "$_pr_cand"
  if [ -f "${POOLS:-}" ]; then
    awk -F'|' -v idx="$_pr_idx" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      { sub(/\r$/, "") }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      trim($1) == idx { next }
      { print }
    ' "$POOLS" > "$_pr_cand"
  fi
  cat "$_pr_new" >> "$_pr_cand"

  # Validate before anything is replaced, so a bad paste leaves the router alone.
  ( POOLS="$_pr_cand" validate_pools ) || { rm -f "$_pr_old" "$_pr_new" "$_pr_cand"; die "the new pool is invalid"; }

  # old slot -> new slot, by identity. Missing means the proxy is gone.
  awk -F'|' '
    FILENAME == old { key = $2 "|" $3 "|" $4 "|" $5 "|" $6; oldslot[key] = $1; next }
    # n+0 forces numeric context: an uninitialised awk variable concatenates as
    # the empty string, so the very first new slot would come out blank and its
    # device would look like it had lost its proxy.
    { key = $2 "|" $3 "|" $4 "|" $5 "|" $6; if (key in oldslot) print oldslot[key] "|" (n+0); n++ }
  ' old="$_pr_old" "$_pr_old" "$_pr_new" > "$_pr_map"

  mv "$_pr_cand" "$POOLS"
  rm -f "$_pr_new"

  # Carry the pins across.
  if [ -f "${ASSIGN_FILE:-}" ]; then
    _pr_keep="$_pr_dir/sbproxy-pool-keep.$$"
    _pr_lost="$_pr_dir/sbproxy-pool-lost.$$"
    : > "$_pr_keep"; : > "$_pr_lost"
    while IFS='|' read -r _pr_ri _pr_rm _pr_rs _pr_rc; do
      case "$_pr_ri" in ''|\#*) continue ;; esac
      if [ "$_pr_ri" != "$_pr_idx" ]; then
        printf '%s|%s|%s|%s\n' "$_pr_ri" "$_pr_rm" "$_pr_rs" "$_pr_rc" >> "$_pr_keep"
        continue
      fi
      _pr_to="$(awk -F'|' -v s="$_pr_rs" '$1 == s { print $2; exit }' "$_pr_map")"
      if [ -n "$_pr_to" ]; then
        printf '%s|%s|%s|%s\n' "$_pr_ri" "$_pr_rm" "$_pr_to" "$_pr_rc" >> "$_pr_keep"
      else
        printf '%s\n' "$_pr_rm" >> "$_pr_lost"
      fi
    done < "$ASSIGN_FILE"
    mv "$_pr_keep" "$ASSIGN_FILE"

    # Whatever lost its proxy is spread over the new pool rather than dropped --
    # unless the pool is now empty, in which case there is nowhere to put it and
    # the SSID falls back to its wifi-socks.conf proxy. Without this check the
    # reassignment below calls die() and takes the whole caller down with it.
    _pr_left="$(pool_count "$_pr_idx")"
    while read -r _pr_lm; do
      [ -n "$_pr_lm" ] || continue
      if [ "$_pr_left" -le 0 ]; then
        log "Dropped the pin for $_pr_lm on idx=$_pr_idx: that Wi-Fi no longer has a pool"
        continue
      fi
      assign_set "$_pr_idx" "$_pr_lm" "$(assign_pick_slot "$_pr_idx")" auto
      log "Reassigned $_pr_lm on idx=$_pr_idx: its proxy is no longer in the pool"
    done < "$_pr_lost"
    rm -f "$_pr_lost"
  fi

  rm -f "$_pr_old" "$_pr_map"
  log "Replaced the pool of idx=$_pr_idx with $(pool_count "$_pr_idx") proxies"
}

# Slot with the fewest devices currently pinned to it. Ties go to the lowest
# slot, so `auto` is deterministic and a fresh pool fills up in order.
assign_pick_slot() { # idx
  _pk_idx="$1"
  _pk_slots="$(pool_count "$_pk_idx")"
  [ "$_pk_slots" -gt 0 ] || die "Wi-Fi idx=$_pk_idx has no proxy pool"
  assign_rows "$_pk_idx" | awk -F'|' -v n="$_pk_slots" '
    { used[$2]++ }
    END {
      best = 0; least = -1
      for (s = 0; s < n; s++) {
        c = (s in used) ? used[s] : 0
        if (least < 0 || c < least) { least = c; best = s }
      }
      print best
    }'
}

# "<name inside the snapshot>|<live path>" for everything a snapshot carries
# beyond /etc/config and /etc/sing-box.
#
# The pool and the pins live outside /etc/config, and pool.sh takes a snapshot
# immediately before replacing a pool -- so leaving them out would make that
# snapshot the one thing incapable of undoing the operation it was taken for.
#
# wifi-socks.conf and sbproxy.nft keep the names older snapshots used, so those
# snapshots stay restorable.
backup_paths() {
  printf 'wifi-socks.conf|%s\n' "$CONF"
  [ -z "${POOLS:-}" ]       || printf 'proxy-pools.conf|%s\n' "$POOLS"
  [ -z "${ASSIGN_FILE:-}" ] || printf 'sbproxy.assign|%s\n' "$ASSIGN_FILE"
  [ -z "${NFT_FILE:-}" ]    || printf 'sbproxy.nft|%s\n' "$NFT_FILE"
  [ -z "${BANS_FILE:-}" ]   || printf 'sbproxy.bans|%s\n' "$BANS_FILE"
}

backup_snapshot_files() { # destination directory
  backup_paths | while IFS='|' read -r _bs_name _bs_path; do
    [ -f "$_bs_path" ] || continue
    cp "$_bs_path" "$1/$_bs_name" 2>/dev/null || warn "Could not back up $_bs_path"
  done
}

restore_snapshot_files() { # snapshot directory
  backup_paths | while IFS='|' read -r _rs_name _rs_path; do
    [ -f "$1/$_rs_name" ] || continue
    mkdir -p "$(dirname "$_rs_path")" 2>/dev/null || true
    cp "$1/$_rs_name" "$_rs_path" && log "Restored $_rs_path"
  done
}

# A random integer in [0, n).
#
# Seeded from /dev/urandom through cksum on purpose: `hexdump` and `od` are the
# applets that broke self-update in 0.4.10 because many OpenWrt images do not
# build them in, so nothing here may depend on either.
pool_random() { # n
  _pr_counter_file="${POOL_RANDOM_COUNTER_FILE:-/tmp/sbproxy-pool-random-seq}"
  _pr_counter="$(cat "$_pr_counter_file" 2>/dev/null || printf '0')"
  case "$_pr_counter" in ''|*[!0-9]*) _pr_counter=0 ;; esac
  _pr_counter=$(( _pr_counter + 1 ))
  _pr_counter_tmp="$_pr_counter_file.$$"
  printf '%s\n' "$_pr_counter" > "$_pr_counter_tmp" 2>/dev/null && mv "$_pr_counter_tmp" "$_pr_counter_file" 2>/dev/null || rm -f "$_pr_counter_tmp"
  awk -v n="$1" -v seq="$_pr_counter" -v seed="$(pool_shuffle_seed)" \
    'BEGIN { srand(seed + seq * 104729); print int(rand() * n) % n }'
}

# Return pool slots whose latest health probe can safely carry traffic.  A
# missing or malformed health file deliberately returns no result: callers
# fall back to the existing random behaviour while healthd is starting.
pool_requires_udp() { # idx
  [ "$(awk -F'|' -v wanted="$1" '
      $0 !~ /^[[:space:]]*#/ && NF >= 10 {
        i=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", i)
        if (i == wanted) { w=$10; gsub(/^[[:space:]]+|[[:space:]]+$/, "", w); print w; exit }
      }' "$CONF" 2>/dev/null)" = "2" ]
}

pool_health_known() { # idx
  _phk_file="${HEALTH_FILE:-/tmp/sbproxy-health.json}"
  [ -r "$_phk_file" ] || return 1
  jq -e --arg i "$1" '(.pool_probes[$i] // {} | length) > 0' "$_phk_file" >/dev/null 2>&1
}

pool_healthy_slots() { # idx
  _ph_file="${HEALTH_FILE:-/tmp/sbproxy-health.json}"
  [ -r "$_ph_file" ] || return 0
  if pool_requires_udp "$1"; then _ph_udp=true; else _ph_udp=false; fi
  jq -r --arg i "$1" --argjson require_udp "$_ph_udp" \
    '(.pool_probes[$i] // {} | to_entries) as $slots |
     ([$slots[] | select(.value.state == "ok" and (($require_udp | not) or .value.udp_state == "ok")) | .key]) as $ok |
     if ($ok | length) > 0 then $ok[]
     else $slots[] | select(.value.state == "slow" and (($require_udp | not) or .value.udp_state == "ok")) | .key end' \
    "$_ph_file" 2>/dev/null
}

pool_random_healthy() { # idx count
  _prh_slots="$(pool_healthy_slots "$1")"
  [ -n "$_prh_slots" ] || return 1
  _prh_count="$(printf '%s\n' $_prh_slots | awk 'NF { n++ } END { print n + 0 }')"
  [ "$_prh_count" -gt 0 ] || return 1
  printf '%s\n' $_prh_slots | sed -n "$(( $(pool_random "$_prh_count") + 1 ))p"
}

# The slot a MAC always hashes to. Same device, same proxy, even after the
# state file has been thrown away -- which is the only reason to prefer this
# over `random`.
assign_hash_slot() { # mac n
  if command -v cksum >/dev/null 2>&1; then
    printf '%s' "$1" | cksum | awk -v n="$2" '{ print $1 % n }'
  else
    awk -v s="$1" -v n="$2" 'BEGIN {
      h=2166136261
      for (i=1; i<=length(s); i++) {
        h = (h * 16777619 + index("0123456789abcdef:", substr(s,i,1))) % 2147483647
      }
      print h % n
    }'
  fi
}

# The next slot in rotation, derived from how many devices this SSID already
# has pinned rather than from a saved cursor, so it stays right across a
# restart and after the state file is rebuilt.
assign_next_slot() { # idx n
  assign_rows "$1" | awk -v n="$2" 'END { print NR % n }'
}

# Which slot a device that has just appeared should get.
#
# `random` is the default because a phone farm wants two devices to look
# unrelated; the other policies exist for operators who need a layout they can
# predict or reproduce.
assign_policy_slot() { # idx mac
  _ps_idx="$1"
  _ps_mac="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
  _ps_n="$(pool_count "$_ps_idx")"
  [ "$_ps_n" -gt 0 ] || die "Wi-Fi idx=$_ps_idx has no proxy pool"
  case "${POOL_ASSIGN_POLICY:-random}" in
    random)
      if _ps_slot="$(pool_random_healthy "$_ps_idx" "$_ps_n")"; then
        printf '%s' "$_ps_slot"
      elif pool_requires_udp "$_ps_idx" && pool_health_known "$_ps_idx"; then
        die "Wi-Fi idx=$_ps_idx has no TCP+UDP healthy proxy slot"
      else
        pool_random "$_ps_n"
      fi
      ;;
    least-loaded) assign_pick_slot "$_ps_idx" ;;
    sticky-hash)  assign_hash_slot "$_ps_mac" "$_ps_n" ;;
    round-robin)  assign_next_slot "$_ps_idx" "$_ps_n" ;;
    *) die "POOL_ASSIGN_POLICY must be random, round-robin, least-loaded or sticky-hash" ;;
  esac
}

# Pin a device unless it already has a pin, and print the slot it ended up on.
#
# $3=1 marks a genuine (re)connection, which is the only thing
# POOL_ROTATE_ON_RECONNECT acts on: the safety-net sweep runs every few seconds
# and would otherwise move a device to a new proxy continuously.
#
# A pin the operator made by hand is never rotated away.
assign_ensure() { # idx mac [reconnect]
  _ae3_idx="$1"
  _ae3_mac="$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')"
  case "$_ae3_idx" in *[!0-9]*|'') return 0 ;; esac
  assign_valid_mac "$_ae3_mac" || return 0
  pool_enabled "$_ae3_idx" || return 0
  _ae3_have="$(assign_rows "$_ae3_idx" | awk -F'|' -v m="$_ae3_mac" '$1 == m { print $2; exit }')"
  if [ -n "$_ae3_have" ]; then
    _ae3_src="$(awk -F'|' -v i="$_ae3_idx" -v m="$_ae3_mac" \
                  '$1 == i && tolower($2) == m { print $4; exit }' "$ASSIGN_FILE")"
    _ae3_unhealthy=0
    if [ "$_ae3_src" != "manual" ] && pool_requires_udp "$_ae3_idx" && pool_health_known "$_ae3_idx" \
       && ! pool_healthy_slots "$_ae3_idx" | grep -qx "$_ae3_have"; then
      _ae3_unhealthy=1
    fi
    if [ "$_ae3_unhealthy" = "0" ] && { [ "${3:-0}" != "1" ] || [ "${POOL_ROTATE_ON_RECONNECT:-0}" != "1" ] \
       || [ "$_ae3_src" = "manual" ]; }; then
      printf '%s' "$_ae3_have"
      return 0
    fi
  fi
  _ae3_slot="$(assign_policy_slot "$_ae3_idx" "$_ae3_mac")"
  assign_set "$_ae3_idx" "$_ae3_mac" "$_ae3_slot" auto
  assign_live_update "$_ae3_idx" "$_ae3_mac" "$_ae3_slot"
  printf '%s' "$_ae3_slot"
}

# How many pins the live map holds. nft prints them as `ip : port` pairs and
# wraps them over several lines, so count the pairs rather than the lines. The
# map's own `type ipv4_addr : inet_service` line sits before the element block
# and is outside the range.
assign_map_size() { # idx
  nft list map inet sbproxy "w$1map" 2>/dev/null \
    | awk '/elements = \{/, /\}/' | tr ',' '\n' | grep -c ':' || true
}

# Put one SSID's map back in line with the state file when it has drifted.
#
# Restarting sbproxy flushes the whole table, so an `add element` that races a
# restart simply disappears. Rather than lock against that, notice the drift and
# reload. Extra elements count as drift too: a device left in the map after its
# pin was cleared keeps using a proxy nobody assigned it.
assign_sync_map() { # idx
  command -v nft >/dev/null 2>&1 || return 0
  case "$1" in *[!0-9]*|'') return 0 ;; esac
  if ! pool_enabled "$1"; then return 0; fi
  _sm_want="$(assign_elements "$1")"
  _sm_n=0
  [ -z "$_sm_want" ] || _sm_n="$(printf '%s' "$_sm_want" | tr ',' '\n' | grep -c ':')"
  _sm_have="$(assign_map_size "$1")"
  if [ "${_sm_have:-0}" -eq "$_sm_n" ]; then return 0; fi
  log "Map w$1map holds ${_sm_have:-0} pins but the state file has $_sm_n; reloading it"
  nft flush map inet sbproxy "w$1map" >/dev/null 2>&1 || true
  [ -z "$_sm_want" ] || nft add element inet sbproxy "w$1map" "{ $_sm_want }" >/dev/null 2>&1 \
    || warn "Could not reload the map for idx=$1; run scripts/apply.sh to resync."
}

# Push one pin into the running ruleset. Cheap enough to do per device and it
# never restarts anything; a failure only means the next apply will pick it up.
assign_live_update() { # idx mac slot
  command -v nft >/dev/null 2>&1 || return 0
  _al_ip="$(lease_ip_of "$2")"
  [ -n "$_al_ip" ] || return 0
  nft delete element inet sbproxy "w$1map" "{ $_al_ip }" >/dev/null 2>&1 || true
  nft add element inet sbproxy "w$1map" "{ $_al_ip : $(pool_port "$1" "$3") }" >/dev/null 2>&1 \
    || warn "Could not update the live ruleset for $2; run scripts/apply.sh to resync."
}

# Whether bridged traffic is kept out of the IP hooks. A `1` here means every
# proxied SSID will hang: the TPROXY rule matches and the packet is never
# delivered to sing-box. The path is a variable so this is testable.
bridge_nf_ok() {
  _bnf="${BRNF_PATH:-/proc/sys/net/bridge/bridge-nf-call-iptables}"
  [ -f "$_bnf" ] || return 0          # module absent, which is the OpenWrt default
  [ "$(cat "$_bnf" 2>/dev/null)" = "1" ] || return 0
  return 1
}

validate_pools() {
  [ -f "${POOLS:-}" ] || return 0
  awk -F'|' -v cap="${POOL_SLOTS_PER_SSID_MAX:-256}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 6 && NF != 7 { printf "line %d: expected 6 or 7 columns, found %d\n", NR, NF; bad=1; next }
    {
      idx=trim($1); type=tolower(trim($2)); host=trim($3); port=trim($4)
      label=(NF == 7) ? trim($7) : ""
      # BusyBox awk compares trim() results as strings unless coerced, so "3"
      # would sort above "200"; force both numeric before any bounds check.
      idx_num=idx+0; port_num=port+0
      # idx 0 is the main LAN pool (LAN_PROXY); 1..200 are the SSIDs.
      if (idx !~ /^(0|[1-9][0-9]*)$/ || idx_num > 200) { printf "line %d: invalid idx\n", NR; bad=1 }
      if (type != "socks5" && type != "http") { printf "line %d: proxy_type must be socks5 or http\n", NR; bad=1 }
      if (host == "") { printf "line %d: host is empty\n", NR; bad=1 }
      else if (length(host) > 253 || host !~ /^[A-Za-z0-9._:-]+$/) { printf "line %d: invalid host\n", NR; bad=1 }
      if (port !~ /^[0-9]+$/ || port_num < 1 || port_num > 65535) { printf "line %d: invalid port\n", NR; bad=1 }
      if (length($5) > 255 || length($6) > 255) { printf "line %d: proxy user/pass may be at most 255 bytes\n", NR; bad=1 }
      if (length(label) > 64) { printf "line %d: label may be at most 64 bytes\n", NR; bad=1 }
      if ($0 ~ /[[:cntrl:]]/) { printf "line %d: field contains a control character\n", NR; bad=1 }
      if (idx ~ /^[1-9][0-9]*$/ && ++seen[idx_num] > cap) {
        printf "line %d: idx %s has more than %d proxies\n", NR, idx, cap; bad=1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$POOLS" || die "proxy-pools.conf is invalid."
}

# --- Routing rules ----------------------------------------------------------
# config/routing-rules.conf sends one destination straight out the WAN, blocks
# it, or forces it back through the proxy. Absent file = every destination goes
# through the proxy, which is what happened before this existed.
validate_routes() {
  [ -f "${ROUTES:-}" ] || return 0
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 3 { printf "line %d: expected 3 columns, found %d\n", NR, NF; bad=1; next }
    {
      action=tolower(trim($1)); type=tolower(trim($2)); value=trim($3)
      if (action != "direct" && action != "block" && action != "proxy") {
        printf "line %d: action must be direct, block or proxy\n", NR; bad=1
      }
      if (type != "domain" && type != "domain_suffix" && type != "domain_keyword" && type != "ip_cidr") {
        printf "line %d: type must be domain, domain_suffix, domain_keyword or ip_cidr\n", NR; bad=1
      }
      if (value == "") { printf "line %d: value is empty\n", NR; bad=1 }
      else if (length(value) > 253) { printf "line %d: value may be at most 253 bytes\n", NR; bad=1 }
      # The generator writes these straight into JSON, so the charset is the
      # quoting: nothing here can close a string or inject a field.
      else if (value !~ /^[A-Za-z0-9._:\/-]+$/) {
        printf "line %d: value may only contain letters, digits and . _ - : /\n", NR; bad=1
      }
      else if (type == "ip_cidr" && value !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
        printf "line %d: ip_cidr must look like 1.2.3.0/24\n", NR; bad=1
      }
      else if (type != "ip_cidr" && value ~ /\//) {
        printf "line %d: a domain value must not contain /\n", NR; bad=1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$ROUTES" || die "routing-rules.conf is invalid."
}

# Sing-box route rules for config/routing-rules.conf, in file order, so the
# first match wins exactly as the file reads top to bottom. Emitted with a
# leading comma: they are spliced after rules that are always present.
#
# `direct` and `block` are one rule each. `proxy` cannot be, because the
# outbound it means is whichever one this packet's inbound would have chosen,
# and no single rule can say that. It becomes one inbound-scoped rule per
# inbound instead, which is also why the pairs are passed in: dropping the line
# and relying on fall-through would let a broader `direct` line BELOW it match,
# and shadowing exactly that is the only reason the action exists.
routes_json() { # "in-tag:out-tag in-tag:out-tag ..."
  [ -f "${ROUTES:-}" ] || return 0
  awk -F'|' -v pairs="${1:-}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { npairs = split(pairs, pair, " ") }
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF != 3 { next }
    {
      action=tolower(trim($1)); type=tolower(trim($2)); value=trim($3)
      if (value == "") next
      if (action == "proxy") {
        for (i = 1; i <= npairs; i++) {
          split(pair[i], t, ":")
          printf ",{\"inbound\":[\"%s\"],\"%s\":[\"%s\"],\"outbound\":\"%s\"}", t[1], type, value, t[2]
        }
        next
      }
      if (action == "block") verdict = "\"action\":\"reject\""
      else verdict = "\"outbound\":\"direct\""
      printf ",{\"%s\":[\"%s\"],%s}", type, value, verdict
    }
  ' "$ROUTES"
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

# The OpenWrt sing-box package ships /etc/config/sing-box with
# `option enabled '0'`, and its init script returns from start_service without
# starting anything while that flag is 0. `/etc/init.d/sing-box enable` only
# adds the boot symlink, so on a freshly flashed router `restart` succeeds
# silently and nothing listens on the TPROXY ports: the WAN works and every
# proxied SSID is dead. Turn the flag on and point the service at our file.
ensure_singbox_service() {
  command -v uci >/dev/null 2>&1 || return 0
  uci -q get sing-box.main >/dev/null 2>&1 || return 0   # not the UCI-driven package
  _sbs_changed=0
  if [ "$(uci -q get sing-box.main.enabled 2>/dev/null)" != "1" ]; then
    run "uci set sing-box.main.enabled=1"; _sbs_changed=1
  fi
  _sbs_conf="${SINGBOX_CONF:-/etc/sing-box/config.json}"
  if [ "$(uci -q get sing-box.main.conffile 2>/dev/null)" != "$_sbs_conf" ]; then
    run "uci set sing-box.main.conffile='$_sbs_conf'"; _sbs_changed=1
  fi
  if [ "$_sbs_changed" = 1 ]; then
    run "uci commit sing-box"
    log "Enabled the sing-box service in /etc/config/sing-box (it ships disabled)."
  fi
}

# The PID of the running sing-box, or nothing.
#
# `pgrep -f sing-box` is too loose to trust: it also matches `logread -e
# sing-box`, `sh scripts/restart-singbox.sh` and any other command line that
# merely mentions the name, so a console asking "is the proxy engine alive?"
# could be answered by its own diagnostics. /proc/<pid>/comm is the process
# name itself, read with the shell builtin so this costs no forks.
singbox_pid() {
  for _sp_proc in "${PROC_DIR:-/proc}"/[0-9]*; do
    [ -r "$_sp_proc/comm" ] || continue
    read -r _sp_comm < "$_sp_proc/comm" 2>/dev/null || continue
    [ "$_sp_comm" = "sing-box" ] || continue
    printf '%s\n' "${_sp_proc##*/}"
    return 0
  done
  return 1
}

# True only when the SAME sing-box is still there a moment later.
#
# procd respawns a crashing service every few seconds, so a single sample
# finds a live PID and calls a crash loop healthy — exactly how a router whose
# sing-box could not read its config reported "Running: yes (pid 17956)" while
# the log filled with FATAL lines.
singbox_running_stable() {
  _srs_first="$(singbox_pid)" || return 1
  sleep "${SINGBOX_STABLE_WAIT:-3}"
  _srs_second="$(singbox_pid)" || return 1
  [ "$_srs_first" = "$_srs_second" ]
}

# How long the running sing-box has been up, in seconds ("" when it is down).
# A value that keeps resetting is the signature of a crash loop.
singbox_uptime_s() {
  _su_pid="$(singbox_pid)" || return 1
  _su_proc="${PROC_DIR:-/proc}"
  [ -r "$_su_proc/$_su_pid/stat" ] && [ -r "$_su_proc/uptime" ] || return 1
  _su_start="$(awk '{ print $22 }' "$_su_proc/$_su_pid/stat" 2>/dev/null)"
  case "$_su_start" in ''|*[!0-9]*) return 1 ;; esac
  awk -v start="$_su_start" -v hz="${USER_HZ:-100}" \
      '{ printf "%d", ($1 - start / hz) + 0.5; exit }' "$_su_proc/uptime"
}

# Let the service read its own configuration.
#
# The OpenWrt package can run sing-box as an unprivileged user (procd hands it
# the capabilities TPROXY needs), so a config.json only root can read makes it
# crash-loop on "permission denied". That is easy to create by accident: the
# agent CGI reads request bodies under `umask 077`, and an apply run through
# it wrote a 0600 root-owned file, while the same apply over SSH (umask 022)
# produced a readable one.
#
# The file carries proxy passwords, so it is never made world-readable: it is
# handed to whatever user the service actually runs as and kept at 0600.
ensure_singbox_conf_access() {
  _sca_conf="${1:-${SINGBOX_CONF:-/etc/sing-box/config.json}}"
  [ -f "$_sca_conf" ] || return 0
  command -v uci >/dev/null 2>&1 || return 0
  _sca_user="$(uci -q get sing-box.main.user 2>/dev/null || true)"
  case "$_sca_user" in
    root)
      # root reads anything, so the file can be as private as its contents
      # deserve.
      run "chmod 600 '$_sca_conf'"
      return 0 ;;
    "")
      # No service user is declared, so the account that opens this file is
      # unknown, and tightening it here could break the routers that work
      # today. The mode is left as the caller's umask made it -- every path
      # that writes it now runs at 022 -- and a service that still cannot read
      # its config is repaired by scripts/restart-singbox.sh.
      return 0 ;;
    *[!A-Za-z0-9_.-]*)
      warn "Refusing to chown to an odd service user: $_sca_user"; return 0 ;;
  esac
  # A named unprivileged user: hand it the file, then make the file private --
  # it carries proxy passwords and nobody else needs to read it. The cache sits
  # in the same directory and sing-box writes it, so that comes along.
  _sca_dir="$(dirname "$_sca_conf")"
  run "chown '$_sca_user' '$_sca_conf' '$_sca_dir'" \
    || { warn "Could not give $_sca_user access to $_sca_conf"; return 0; }
  run "chmod 600 '$_sca_conf'"
  _sca_cache="${SINGBOX_CACHE:-}"
  if [ -n "$_sca_cache" ] && [ -f "$_sca_cache" ]; then
    run "chown '$_sca_user' '$_sca_cache'" || true
  fi
  log "sing-box runs as '$_sca_user'; gave it access to $_sca_conf"
}

# Can the service user open a TPROXY socket at all?
#
# procd grants capabilities from /etc/capabilities/<service>.json. Without
# net_admin in there, an unprivileged sing-box cannot bind a transparent
# listener and dies with "operation not permitted" on every start -- a
# different failure from an unreadable config, and one no chown can fix.
singbox_caps_file() { printf '%s' "${SINGBOX_CAPS:-/etc/capabilities/sing-box.json}"; }
singbox_user() { command -v uci >/dev/null 2>&1 && uci -q get sing-box.main.user 2>/dev/null || true; }
singbox_can_tproxy() {
  _sct_user="$(singbox_user)"
  case "$_sct_user" in ''|root) return 0 ;; esac   # root needs no capability
  _sct_caps="$(singbox_caps_file)"
  [ -f "$_sct_caps" ] || return 1
  grep -qi 'net_admin' "$_sct_caps" 2>/dev/null
}

# Give the service the privilege TPROXY needs, or stop pretending it has it.
#
# The capability file belongs to the sing-box package; this project does not
# rewrite it. When it cannot grant net_admin, the service is moved to root --
# which is what this project needs anyway (transparent listeners, a cache under
# /etc) -- and the change is stated, never silent.
force_singbox_root() {
  command -v uci >/dev/null 2>&1 || return 1
  _fsr_user="$(singbox_user)"
  [ "$_fsr_user" = "root" ] && return 1
  run "uci set sing-box.main.user='root'" || { warn "Could not change the sing-box service user."; return 1; }
  run "uci commit sing-box" || true
  # The file was handed to the old service user so it could read it. That
  # account no longer runs anything, and the file holds every proxy password,
  # so take it back now that root is the reader.
  ensure_singbox_conf_access "${SINGBOX_CONF:-/etc/sing-box/config.json}"
  log "sing-box will run as root so its TPROXY inbounds can bind (was '${_fsr_user:-package default}')."
}

ensure_singbox_privileges() {
  command -v uci >/dev/null 2>&1 || return 0
  _ssp_user="$(singbox_user)"
  case "$_ssp_user" in ''|root) return 0 ;; esac
  # A sing-box that is running right now has already bound its TPROXY ports,
  # whatever this file says: some firmwares grant the capability by other
  # means. Evidence beats inference, and moving a working service to root
  # would be a privilege escalation nobody asked for.
  singbox_pid >/dev/null 2>&1 && return 0
  singbox_can_tproxy && return 0
  warn "sing-box runs as '$_ssp_user' but $(singbox_caps_file) does not grant net_admin: TPROXY listeners cannot bind."
  force_singbox_root || true
}

# Did the last start fail because the service user is too weak, rather than
# because the configuration is wrong? Both privilege failures look like this.
singbox_privilege_error_recently() {
  command -v logread >/dev/null 2>&1 || return 1
  logread -e sing-box 2>/dev/null | tail -n 40 \
    | grep -qiE 'operation not permitted|permission denied'
}

_singbox_wait_stable() {
  _sws_wait="${SINGBOX_START_WAIT:-6}"
  while [ "$_sws_wait" -gt 0 ]; do
    # Stability, not mere presence: a respawning crash loop always has a pid.
    singbox_running_stable && return 0
    sleep 1; _sws_wait=$((_sws_wait - 1))
  done
  return 1
}

# After `/etc/init.d/sing-box restart`, prove the process is up. A silent
# failure here is the worst kind: apply reports success and the SSIDs hang.
verify_singbox_running() {
  [ "${DRYRUN:-0}" = "1" ] && return 0
  _singbox_wait_stable && { log "sing-box is running (pid $(singbox_pid))."; return 0; }
  warn "sing-box is NOT running after restart. Recent log:"
  command -v logread >/dev/null 2>&1 && logread -e sing-box 2>/dev/null | tail -n 15 >&2
  if [ "$(uci -q get sing-box.main.enabled 2>/dev/null)" = "0" ]; then
    warn "/etc/config/sing-box still has enabled=0."
  fi
  # A capability file can exist and still not be applied (an older procd, a
  # firmware that ships none at all), so the check before the start is not
  # proof. When the log says the service user was the problem, repair it here
  # and try once more: an install that ends with a dead engine and a message
  # to look up is how this fault kept coming back after every fresh flash.
  if singbox_privilege_error_recently && force_singbox_root; then
    run "/etc/init.d/sing-box restart"
    _singbox_wait_stable && {
      log "sing-box is running (pid $(singbox_pid)) after being given root."
      return 0
    }
    warn "sing-box still does not stay up as root. Recent log:"
    command -v logread >/dev/null 2>&1 && logread -e sing-box 2>/dev/null | tail -n 15 >&2
  fi
  die "sing-box did not start; every proxied SSID would have no Internet. Fix the cause above and re-run apply."
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
  # Quoted through jq so a hostname or an unusual resolver cannot break the JSON.
  dns_upstream_json="$(jq -Rn --arg v "${DNS_UPSTREAM:-1.1.1.1}" '$v')"
  inbounds=""; outbounds=""; rules=""; sep=""
  # Every inbound with the outbound it routes to, for the `proxy` routing rules.
  _sb_pairs=""
  # One outbound object. Shared by the wifi-socks.conf row and by pool slots so
  # the two can never drift in how they quote a credential or pick a type.
  _sb_outbound() { # tag type host port user pass
    _o_host="$(jq -Rn --arg v "$3" '$v')"
    if [ -n "$5" ]; then
      _o_auth=",\"username\":$(jq -Rn --arg v "$5" '$v'),\"password\":$(jq -Rn --arg v "$6" '$v')"
    else _o_auth=""; fi
    # An HTTP proxy has no UDP transport at all, so it stays TCP-only and its
    # SSID keeps dropping QUIC. A SOCKS5 proxy carries UDP through UDP
    # ASSOCIATE; pinning "network" to tcp is what refuses it.
    if [ "$2" = "http" ]; then
      printf '{"type":"http","tag":"%s","server":%s,"server_port":%s%s}' \
        "$1" "$_o_host" "$4" "$_o_auth"
    elif socks_udp_enabled; then
      printf '{"type":"socks","tag":"%s","server":%s,"server_port":%s,"version":"5"%s}' \
        "$1" "$_o_host" "$4" "$_o_auth"
    else
      printf '{"type":"socks","tag":"%s","server":%s,"server_port":%s,"version":"5","network":"tcp"%s}' \
        "$1" "$_o_host" "$4" "$_o_auth"
    fi
  }
  # One tproxy port per pool proxy, so nftables can pin a device to a proxy by
  # choosing a port — no sing-box reload when an assignment changes. Reads
  # `idx` from its caller, which is either a wifi-socks.conf row or the LAN.
  # It carries its own separator because the LAN pool can be the very first
  # thing emitted, with no SSID row ahead of it.
  _sb_slot() { # slot type host port user pass label
    _s_tag="w$idx-s$1"
    inbounds="$inbounds$sep{\"type\":\"tproxy\",\"tag\":\"in-$_s_tag\",\"listen\":\"0.0.0.0\",\"listen_port\":$(pool_port "$idx" "$1")}"
    _sb_pairs="$_sb_pairs in-$_s_tag:out-$_s_tag"
    outbounds="$outbounds$sep$(_sb_outbound "out-$_s_tag" "$2" "$3" "$4" "$5" "$6")"
    rules="$rules$sep{\"inbound\":[\"in-$_s_tag\"],\"action\":\"sniff\",\"timeout\":\"1s\"}"
    rules="$rules,{\"inbound\":[\"in-$_s_tag\"],\"outbound\":\"out-$_s_tag\"}"
    sep=","
  }
  _sb_row() {
    name="$1"; idx="$3"; host="$5"; port="$6"; user="$7"; pass="$8"; proxy_type="${12:-socks5}"
    tp="$(tproxy_port "$idx")"
    if ! pool_enabled "$idx"; then
      warn "SSID idx=$idx has no proxy pool; no default proxy will be generated."
    fi
    for_each_pool "$idx" _sb_slot
  }
  for_each_ssid _sb_row
  # The main LAN is pool-only: idx 0 has no wifi-socks.conf row, so it gets slot
  # inbounds and nothing else. An unpinned wired device matches no slot and is
  # never sent to sing-box at all.
  if lan_proxy_enabled; then
    idx=0
    for_each_pool 0 _sb_slot
  fi
  # Routing rules are evaluated before any inbound is mapped to its outbound,
  # or a destination could never be taken away from the proxy.
  _sb_routes="$(routes_json "${_sb_pairs# }")"

  # Per-connection accounting for scripts/traffic.sh. Off unless asked for: it
  # is a control API, so it costs a listening socket and a secret to protect.
  _sb_clash=""
  if traffic_stats_enabled; then
    _sb_secret="$(clash_api_secret 2>/dev/null || true)"
    if [ -n "$_sb_secret" ]; then
      _sb_clash=",
    \"clash_api\": { \"external_controller\": $(jq -Rn --arg v "${CLASH_API_LISTEN:-127.0.0.1:9090}" '$v'), \"secret\": $(jq -Rn --arg v "$_sb_secret" '$v') }"
    else
      warn "TRAFFIC_STATS=1 but the API secret could not be created; stats stay off."
    fi
  fi

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
      { "type": "tcp", "tag": "upstream", "server": $dns_upstream_json }
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
    "rules": [ { "action": "sniff", "timeout": "1s" }, { "protocol": "dns", "action": "hijack-dns" }$_sb_routes${rules:+,} $rules ],
    "default_domain_resolver": "upstream",
    "final": "direct"
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "$SINGBOX_CACHE", "store_fakeip": true }$_sb_clash
  }
}
EOF
  # Never leave the mode to the caller's umask: run through the agent CGI it
  # is 077, and a 0600 root-owned config is unreadable to the service user.
  ensure_singbox_conf_access "$SINGBOX_CONF"
  log "Wrote $SINGBOX_CONF"
}

desired_idx() {
  # The column counts accepted here must stay the same set validate_conf
  # accepts. A row validate_conf calls valid but this cannot see is an SSID
  # emit_stale_uci then tears down as if it had been removed -- which is what
  # happened to every SSID that named its proxy_type in a 12th column.
  awk -F'|' '!/^#/ && NF >= 10 && NF <= 12 { gsub(/[[:space:]]/,"",$3); if ($3 != "") print $3 }' "$CONF" | sort -n -u
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
  # Every accumulator and row field is prefixed. build_singbox showed what a
  # bare `pass` or `idx` here does to a caller that happens to use the name.
  _nft_webrtc=""; _nft_chains=""; _nft_vmap=""; _nft_hosts=""; _nft_sep=""; _nft_maps=""

  # Only IPv4 literals can be matched by `ip daddr`. A hostname is skipped, as
  # before: sing-box resolves it and the connection leaves through the proxy.
  _nft_add_host() {
    case "${1:-}" in ''|*[!0-9.]*) return 0 ;; esac
    case " $_nft_hosts " in *" $1 "*) return 0 ;; esac
    _nft_hosts="$_nft_hosts $1"
  }

  _nft_row() {
    _r_idx="$3"; _r_host="$5"; _r_webrtc="${10}"; _r_type="${12:-socks5}"
    _r_tp="$(tproxy_port "$_r_idx")"
    _nft_add_host "$_r_host"
    _nft_vmap="$_nft_vmap$_nft_sep\"br-w$_r_idx\" : jump w$_r_idx"
    _nft_sep=", "
    if [ "$_r_webrtc" = "1" ]; then
      _nft_webrtc="$_nft_webrtc    iifname \"br-w$_r_idx\" tcp dport { $STUN_TCP_PORTS } drop\n"
      _nft_webrtc="$_nft_webrtc    iifname \"br-w$_r_idx\" udp dport { $STUN_UDP_PORTS } drop\n"
    fi
    # One chain per SSID, entered through a verdict map, so a packet evaluates
    # only its own SSID's rules instead of every SSID's in one flat chain. The
    # rule order inside the chain matches the old flat chain exactly.
    # An SSID with a pool can refuse service to a device that has no proxy
    # pinned yet, instead of quietly falling back to the wifi-socks.conf one.
    _r_gate=1
    _nft_chains="$_nft_chains  chain w$_r_idx {\n"
    _nft_chains="$_nft_chains    # Hijack DNS into sing-box (fake-IP), ahead of the local-net bypass.\n"
    if [ "$_r_gate" = 1 ] && pool_enabled "$_r_idx"; then
      # DNS goes through the pinned device's own slot, so an unpinned device
      # does not even resolve — no name lookup, no fake IP, no connection.
      _nft_chains="$_nft_chains    meta l4proto { tcp, udp } th dport 53 tproxy ip to :ip saddr map @w${_r_idx}map meta mark set $TPROXY_MARK accept\n"
    elif pool_enabled "$_r_idx"; then
      _nft_chains="$_nft_chains    meta l4proto { tcp, udp } th dport 53 tproxy ip to :$_r_tp meta mark set $TPROXY_MARK accept\n"
    else
      _nft_chains="$_nft_chains    meta l4proto { tcp, udp } th dport 53 drop\n"
    fi
    # webrtc=2 ("bypass"): the STUN/TURN exchange is forced into sing-box ahead
    # of every return rule below, so the STUN server answers with the proxy's
    # address and the browser publishes that as its server-reflexive candidate
    # instead of the router's real IP. Needs a proxy that relays UDP
    # (SOCKS5 UDP ASSOCIATE); on one that does not, WebRTC finds no candidate
    # and falls back to no media, which is the same visible result as webrtc=1.
    if [ "$_r_webrtc" = "2" ]; then
      _nft_chains="$_nft_chains    # Bypass WebRTC: STUN/TURN answers with the proxy IP, never the real one.\n"
      # A pinned device has to reach its OWN pool proxy here too, or its calls
      # would advertise the SSID default proxy's address while the rest of its
      # traffic left through another one.
      if pool_enabled "$_r_idx"; then
        _nft_chains="$_nft_chains    tcp dport { $STUN_TCP_PORTS } tproxy ip to :ip saddr map @w${_r_idx}map meta mark set $TPROXY_MARK accept\n"
        _nft_chains="$_nft_chains    udp dport { $STUN_UDP_PORTS } tproxy ip to :ip saddr map @w${_r_idx}map meta mark set $TPROXY_MARK accept\n"
      fi
    fi
    _nft_chains="$_nft_chains    # Do not proxy local or multicast traffic.\n"
    _nft_chains="$_nft_chains    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return\n"
    _nft_chains="$_nft_chains    # Bypass the proxy servers themselves through the WAN.\n"
    _nft_chains="$_nft_chains    ip daddr @proxy_hosts return\n"
    # QUIC is only dropped where UDP cannot reach the Internet anyway: with
    # SOCKS_UDP off, or on an SSID that can route a device to an HTTP proxy.
    # Dropping it there is what makes a browser fall back to TCP HTTPS at once
    # instead of waiting out a UDP flow that sing-box could never deliver.
    if ! socks_udp_enabled || [ "$_r_type" = "http" ] || pool_has_http "$_r_idx"; then
      _nft_chains="$_nft_chains    # Drop QUIC/HTTP3; force TCP/HTTPS through the proxy.\n"
      _nft_chains="$_nft_chains    udp dport 443 drop\n"
    fi
    # A pooled SSID looks up the source IP in its own map and is sent straight
    # to that proxy's port. One rule and one hash lookup, whatever the pool
    # size. A miss does not match, so the device falls through to whatever the
    # POOL_UNASSIGNED policy put at the end of the chain.
    if pool_enabled "$_r_idx"; then
      _nft_elements_w="$(assign_elements "$_r_idx")"
      _nft_maps="$_nft_maps  map w${_r_idx}map { type ipv4_addr : inet_service; size ${POOL_MAP_SIZE:-512}${_nft_elements_w:+; elements = { $_nft_elements_w \}}; }\n"
      _nft_chains="$_nft_chains    # Devices pinned to a pool proxy go to that proxy's port.\n"
      _nft_chains="$_nft_chains    meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w${_r_idx}map meta mark set $TPROXY_MARK accept\n"
    fi
    if [ "$_r_gate" = 1 ]; then
      _nft_chains="$_nft_chains    # POOL_UNASSIGNED=block: no proxy pinned, no Internet.\n"
      _nft_chains="$_nft_chains    drop\n"
    else
      _nft_chains="$_nft_chains    # Send this Wi-Fi to its sing-box TPROXY port.\n"
      _nft_chains="$_nft_chains    meta l4proto { tcp, udp } tproxy ip to :$_r_tp meta mark set $TPROXY_MARK accept\n"
    fi
    _nft_chains="$_nft_chains  }\n"
  }
  for_each_ssid _nft_row

  # The main LAN. It has no wifi-socks.conf row and so no default proxy: only a
  # device pinned to an idx-0 slot is proxied, and everything else falls off the
  # end of the chain and routes exactly as it did before LAN_PROXY was set.
  # That is also why DNS follows the pin map — hijacking it unconditionally
  # would drag every unpinned wired machine off dnsmasq and into fake-IP.
  if lan_proxy_enabled; then
    _nft_lan_br="${LAN_BRIDGE:-br-lan}"
    _nft_vmap="$_nft_vmap$_nft_sep\"$_nft_lan_br\" : jump w0"
    _nft_sep=", "
    _nft_elements_lan="$(assign_elements 0)"
    _nft_maps="$_nft_maps  map w0map { type ipv4_addr : inet_service; size ${POOL_MAP_SIZE:-512}${_nft_elements_lan:+; elements = { $_nft_elements_lan \}}; }\n"
    _nft_chains="$_nft_chains  chain w0 {\n"
    _nft_chains="$_nft_chains    # DNS follows the pin, so an unpinned LAN device keeps using dnsmasq.\n"
    _nft_chains="$_nft_chains    meta l4proto { tcp, udp } th dport 53 tproxy ip to :ip saddr map @w0map meta mark set $TPROXY_MARK accept\n"
    _nft_chains="$_nft_chains    # Do not proxy local or multicast traffic.\n"
    _nft_chains="$_nft_chains    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return\n"
    _nft_chains="$_nft_chains    # Bypass the proxy servers themselves through the WAN.\n"
    _nft_chains="$_nft_chains    ip daddr @proxy_hosts return\n"
    if ! socks_udp_enabled || pool_has_http 0; then
      _nft_chains="$_nft_chains    # Drop QUIC/HTTP3; force TCP/HTTPS through the proxy.\n"
      _nft_chains="$_nft_chains    udp dport 443 drop\n"
    fi
    _nft_chains="$_nft_chains    # Devices pinned to a LAN pool proxy go to that proxy's port.\n"
    _nft_chains="$_nft_chains    meta l4proto { tcp, udp } tproxy ip to :ip saddr map @w0map meta mark set $TPROXY_MARK accept\n"
    if [ "${POOL_UNASSIGNED:-default}" = "block" ]; then
      _nft_chains="$_nft_chains    # POOL_UNASSIGNED=block: no proxy pinned, no Internet.\n"
      _nft_chains="$_nft_chains    drop\n"
    fi
    _nft_chains="$_nft_chains  }\n"
  fi

  # Pool proxies need the same WAN bypass as the wifi-socks.conf ones.
  for _nft_ph in $(pool_hosts); do _nft_add_host "$_nft_ph"; done

  _nft_elements=""
  if [ -n "$_nft_hosts" ]; then
    _nft_elements=" elements = { $(printf '%s' "${_nft_hosts# }" | sed 's/ /, /g') };"
  fi
  _nft_divert=""
  if use_divert; then
    _nft_divert="    # A packet of an established transparent socket skips classification.\n"
    _nft_divert="$_nft_divert    meta l4proto tcp socket transparent 1 meta mark set $TPROXY_MARK accept\n"
  fi

  {
    echo "# GENERATED by sbproxy build_nft — DO NOT EDIT; this file is overwritten."
    echo "table inet sbproxy {"
    echo "  set proxy_hosts { type ipv4_addr;$_nft_elements }"
    printf "%b" "$_nft_maps"
    echo "  chain webrtc {"
    echo "    type filter hook forward priority filter; policy accept;"
    printf "%b" "$_nft_webrtc"
    echo "  }"
    echo "  chain prerouting {"
    echo "    type filter hook prerouting priority mangle; policy accept;"
    printf "%b" "$_nft_divert"
    [ -n "$_nft_vmap" ] && echo "    iifname vmap { $_nft_vmap }"
    echo "  }"
    printf "%b" "$_nft_chains"
    echo "}"
  } > "$NFT_FILE"
  log "Wrote $NFT_FILE"
}

# Whether to emit the divert rule. `auto` asks this router's nft whether it
# understands the socket expression; a workstation without nft answers no.
use_divert() {
  case "${POOL_DIVERT:-auto}" in
    on) return 0 ;;
    off) return 1 ;;
  esac
  command -v nft >/dev/null 2>&1 || return 1
  printf '%s\n' 'table inet sbproxy_divert_probe {' \
    '  chain c { type filter hook prerouting priority mangle; meta l4proto tcp socket transparent 1 accept; }' \
    '}' | nft -c -f - >/dev/null 2>&1
}
