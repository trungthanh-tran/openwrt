#!/bin/sh
# debug-agent.sh — the router's own troubleshooting assistant.
#
#   debug-agent.sh [report]     read-only; JSON findings, worst first
#   debug-agent.sh fix <id>     apply ONE named repair from that report
#
# The web console had every fact on a separate screen -- sing-box card, health
# probes, logs, diagnose -- and left the reading of them to the operator. This
# walks the same evidence in the order faults actually cascade (dependencies,
# configuration, engine, data path, egress, agent, host) and answers the only
# two questions that matter: what is broken, and what fixes it.
#
# Nothing leaves the router: every conclusion is a rule over local state, so it
# works on a box with no Internet and no API key. `report` never changes
# anything; `fix` runs only the repairs named in do_fix, one at a time.
#
# Each finding carries both languages. The console shows one of them, and
# writing the pair next to the rule keeps the two from drifting apart.
set -u
SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"; export SB_ROOT
# shellcheck source=/dev/null
. "$SB_ROOT/scripts/lib.sh"
# shellcheck source=/dev/null
[ -f /etc/sbproxy/env ] && . /etc/sbproxy/env

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 1; }

SINGBOX_CONF="${SINGBOX_CONF:-/etc/sing-box/config.json}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/sbproxy-health.json}"
CGI_DEST="${CGI_DEST:-/www/cgi-bin/sbproxy}"
UI_ASSETS="${UI_ASSETS:-/www/sbproxy/assets/bootstrap.min.css}"
WEBAUTH_FILE="${WEBAUTH_FILE:-/etc/sbproxy/webauth}"
LOG_LINES="${DEBUG_LOG_LINES:-8}"

have() { command -v "$1" >/dev/null 2>&1; }
sb_log() { logread -e sing-box 2>/dev/null | tr -d '\r' | tail -n "$LOG_LINES"; }

FIND_FILE="$(mktemp "${TMPDIR:-/tmp}/sbproxy-debug.XXXXXX" 2>/dev/null)" || FIND_FILE=""
[ -n "$FIND_FILE" ] || { echo '{"ok":false,"error":"cannot create a temporary file"}'; exit 1; }
trap 'rm -f "$FIND_FILE"' EXIT INT TERM

crit=0; warn_n=0; info=0

# add <id> <crit|warn|info> <fix-id|""> <title vi> <title en> <detail vi> <detail en> [evidence]
#
# `fix` names one of the repairs in do_fix below. The console turns it into a
# button and never decides for itself what may run.
add() {
  case "$2" in
    crit) crit=$((crit + 1)) ;;
    warn) warn_n=$((warn_n + 1)) ;;
    *)    info=$((info + 1)) ;;
  esac
  jq -cn --arg id "$1" --arg severity "$2" --arg fix "$3" \
         --arg title "$4" --arg title_en "$5" \
         --arg detail "$6" --arg detail_en "$7" --arg evidence "${8:-}" \
    '{id:$id, severity:$severity, fix:$fix, title:$title, title_en:$title_en,
      detail:$detail, detail_en:$detail_en, evidence:$evidence}' >> "$FIND_FILE"
}

# ---------------------------------------------------------------------------
# 1. Dependencies — nothing below can be trusted while one of these is absent
# ---------------------------------------------------------------------------
missing=""
for c in sing-box nft iw jq ubus; do
  have "$c" || missing="${missing:+$missing }$c"
done
[ -z "$missing" ] || add "deps_missing" "crit" "" \
  "Thiếu gói bắt buộc: $missing" \
  "Missing required packages: $missing" \
  "Cài lại bằng: sh $SB_ROOT/scripts/install-deps.sh (router phải ra được Internet)." \
  "Reinstall them with: sh $SB_ROOT/scripts/install-deps.sh (the router needs Internet access)."

# ---------------------------------------------------------------------------
# 2. Configuration files
# ---------------------------------------------------------------------------
eol_files=""
for f in "$SETTINGS" "$CONF" "$POOLS"; do
  [ -f "$f" ] || continue
  [ -n "$(tr -dc '\r' < "$f" 2>/dev/null)" ] && eol_files="${eol_files:+$eol_files }$f"
done
[ -z "$eol_files" ] || add "config_eol" "warn" "config_eol" \
  "Cấu hình lưu kiểu Windows (CRLF)" \
  "Configuration saved with Windows (CRLF) line endings" \
  "Ký tự xuống dòng của Windows dính vào cuối mọi giá trị: WIFI_COUNTRY=\"VN\" bị đọc thành VN kèm CR nên preflight từ chối. File: $eol_files" \
  "The carriage return sticks to the end of every value: WIFI_COUNTRY=\"VN\" reads as VN plus CR, which preflight rejects. Files: $eol_files"

[ -f "$SETTINGS" ] || add "settings_missing" "crit" "" \
  "Không có config/settings.sh" \
  "config/settings.sh is missing" \
  "Mọi thiết lập đều rỗng. Đẩy lại mã nguồn (Web Deploy → Cài / Cập nhật) hoặc chép lại từ gói cài." \
  "Every setting reads as unset. Push the code again (Web Deploy → Install / Update) or copy the file from the package."

if [ ! -s "$CONF" ]; then
  add "conf_empty" "info" "" \
    "Chưa khai báo WiFi nào" \
    "No Wi-Fi is configured yet" \
    "config/wifi-socks.conf đang trống — thêm SSID ở màn hình WiFi rồi bấm Áp dụng." \
    "config/wifi-socks.conf is empty — add an SSID on the Wi-Fi screen, then apply."
elif ! ( validate_conf ) >/dev/null 2>&1; then
  add "conf_invalid" "crit" "" \
    "wifi-socks.conf không hợp lệ" \
    "wifi-socks.conf is invalid" \
    "Sửa dòng bị lỗi ở màn hình WiFi; chi tiết in ra khi chạy: cd $SB_ROOT && sh scripts/apply.sh" \
    "Fix the offending row on the Wi-Fi screen; the details are printed by: cd $SB_ROOT && sh scripts/apply.sh"
fi

# ---------------------------------------------------------------------------
# 3. The engine
# ---------------------------------------------------------------------------
sb_enabled=""
if have uci && uci -q get sing-box.main >/dev/null 2>&1; then
  sb_enabled="$(uci -q get sing-box.main.enabled 2>/dev/null || true)"
fi
[ "$sb_enabled" = "0" ] && add "singbox_disabled" "crit" "singbox_restart" \
  "Service sing-box đang tắt trong /etc/config/sing-box" \
  "The sing-box service is disabled in /etc/config/sing-box" \
  "enabled=0 nên init script không bao giờ khởi động sing-box." \
  "enabled=0, so the init script never starts sing-box."

if [ ! -f "$SINGBOX_CONF" ]; then
  add "singbox_conf_missing" "crit" "apply" \
    "Chưa có $SINGBOX_CONF" \
    "$SINGBOX_CONF does not exist" \
    "Cấu hình sing-box chưa từng được sinh ra — chạy Áp dụng để tạo." \
    "The sing-box configuration has never been generated — apply to create it."
else
  sb_user=""
  have uci && sb_user="$(uci -q get sing-box.main.user 2>/dev/null || true)"
  sb_owner="$(ls -l "$SINGBOX_CONF" 2>/dev/null | awk '{print $3}')"
  case "$sb_user" in
    ''|root) : ;;
    *) [ "$sb_user" = "$sb_owner" ] || add "singbox_conf_access" "crit" "singbox_restart" \
         "sing-box không đọc được config của chính nó" \
         "sing-box cannot read its own configuration" \
         "$SINGBOX_CONF thuộc về '$sb_owner' nhưng service chạy dưới user '$sb_user' — nó chết ngay khi khởi động với 'permission denied'." \
         "$SINGBOX_CONF is owned by '$sb_owner' while the service runs as '$sb_user' — it dies at startup with 'permission denied'." ;;
  esac
fi

sb_pid="$(singbox_pid 2>/dev/null || true)"
if [ -z "$sb_pid" ]; then
  add "singbox_down" "crit" "singbox_restart" \
    "sing-box KHÔNG chạy" \
    "sing-box is NOT running" \
    "WiFi vẫn phát nhưng không thiết bị nào ra được Internet qua proxy." \
    "Wi-Fi still broadcasts, but no device reaches the Internet through the proxy." \
    "$(sb_log)"
else
  sb_up="$(singbox_uptime_s 2>/dev/null || true)"
  case "$sb_up" in ''|*[!0-9]*) sb_up="" ;; esac
  if [ -n "$sb_up" ] && [ "$sb_up" -lt 15 ]; then
    add "singbox_flapping" "crit" "singbox_restart" \
      "sing-box vừa khởi động lại (${sb_up}s) — nhiều khả năng đang crash-loop" \
      "sing-box is only ${sb_up}s old — it is probably crash-looping" \
      "procd bật lại tiến trình mỗi vài giây nên lúc nào cũng thấy một PID, dù service không sống nổi. Đọc log kèm bên dưới." \
      "procd respawns it every few seconds, so there is always a pid even though the service never survives. Read the log below." \
      "$(sb_log)"
  fi
  if sb_log | grep -qi 'permission denied'; then
    add "singbox_denied" "crit" "singbox_restart" \
      "Log sing-box báo 'permission denied'" \
      "The sing-box log says 'permission denied'" \
      "Service không đọc được file cấu hình của nó; khởi động lại sẽ sửa quyền rồi thử lại." \
      "The service cannot read its configuration file; the restart repairs the access and tries again." \
      "$(sb_log)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. The data path — only meaningful once at least one SSID is configured
# ---------------------------------------------------------------------------
if [ -s "$CONF" ]; then
  if have nft && ! nft list table inet sbproxy >/dev/null 2>&1; then
    add "nft_missing" "crit" "apply" \
      "Thiếu bảng nftables 'inet sbproxy'" \
      "The nftables table 'inet sbproxy' is missing" \
      "Không còn luật TPROXY nào: traffic của khách không bao giờ tới sing-box." \
      "No TPROXY rule is loaded: client traffic never reaches sing-box."
  fi
  if have ip && ! ip rule 2>/dev/null | grep -q '0x1'; then
    add "ip_rule_missing" "crit" "apply" \
      "Thiếu policy route cho fwmark 0x1" \
      "The fwmark 0x1 policy route is missing" \
      "Gói đã được đánh dấu nhưng không được đưa vào bảng route ${TPROXY_TABLE:-100}." \
      "Packets are marked but never enter route table ${TPROXY_TABLE:-100}."
  fi
  bridge_nf_ok || add "bridge_nf" "crit" "bridge_nf" \
    "bridge-nf-call-iptables đang bật (=1)" \
    "bridge-nf-call-iptables is on (=1)" \
    "TPROXY khớp luật nhưng gói không bao giờ được giao cho sing-box, nên mọi SSID qua proxy đều treo." \
    "TPROXY matches but the packet is never delivered to sing-box, so every proxied SSID hangs."
fi

# ---------------------------------------------------------------------------
# 5. Egress
# ---------------------------------------------------------------------------
if have ip && ! ip route show default 2>/dev/null | grep -q .; then
  add "wan_down" "crit" "" \
    "Router không có default route" \
    "The router has no default route" \
    "Bản thân router chưa ra được Internet — kiểm tra WAN ở màn hình Đường ra Internet." \
    "The router itself has no Internet — check the uplink on the Internet egress screen."
fi

# ---------------------------------------------------------------------------
# 6. The agent, and the page you are reading this on
# ---------------------------------------------------------------------------
if [ -f "$CGI_DEST" ] && [ -f "$SB_ROOT/agent/cgi/sbproxy" ]; then
  cmp -s "$SB_ROOT/agent/cgi/sbproxy" "$CGI_DEST" || add "agent_stale" "warn" "install_agent" \
    "Agent đã cài cũ hơn mã nguồn trên router" \
    "The installed agent is older than the code on the router" \
    "$CGI_DEST khác với agent/cgi/sbproxy — bản vá vừa đẩy lên chưa có hiệu lực." \
    "$CGI_DEST differs from agent/cgi/sbproxy — the code you just pushed is not live yet."
fi
[ -f "$UI_ASSETS" ] || add "ui_assets_missing" "warn" "install_agent" \
  "Thiếu asset offline của web console" \
  "The console's offline assets are missing" \
  "Trang vẫn dùng được nhưng mất giao diện: không có $UI_ASSETS." \
  "The page still works but loses its styling: $UI_ASSETS is not there."
[ -s "$WEBAUTH_FILE" ] || add "webauth_missing" "info" "" \
  "Chưa có tài khoản web" \
  "No web account exists yet" \
  "Trang sẽ hỏi tạo tài khoản đầu tiên; hoặc chạy trên router: sbproxy-webauth set admin" \
  "The page will ask you to create the first one; or run on the router: sbproxy-webauth set admin"

# ---------------------------------------------------------------------------
# 7. Proxy health, as last measured by healthd
# ---------------------------------------------------------------------------
if [ -s "$HEALTH_FILE" ]; then
  bad_probes="$(jq -r '[(.probes // {}) | to_entries[] | select(.value.state == "fail") | .key] | join(", ")' \
                  "$HEALTH_FILE" 2>/dev/null || true)"
  # healthd records why each probe failed (curl's exit and its first error
  # line). Without it "fail" is indistinguishable from a proxy that works for
  # browsing but cannot reach the probe URL -- a difference that decides
  # whether the operator should change the proxy or the probe.
  bad_why="$(jq -r '[(.probes // {}) | to_entries[] | select(.value.state == "fail")
                      | "idx " + .key + ": " + (.value.error // ("HTTP " + ((.value.code // 0) | tostring)))]
                    | join("\n")' "$HEALTH_FILE" 2>/dev/null || true)"
  [ -z "$bad_probes" ] || add "proxy_fail" "warn" "" \
    "Proxy hỏng ở SSID: $bad_probes" \
    "Failing proxy on SSID: $bad_probes" \
    "Kiểm tra host/port/user/pass và whitelist IP của nhà cung cấp; hoặc đổi sang slot khác ở màn hình Pool. Nếu proxy vẫn dùng được bình thường thì có thể chỉ URL probe (${PROBE_URL:-https://www.gstatic.com/generate_204}) bị chặn — đổi PROBE_URL trong /etc/sbproxy/env." \
    "Check host/port/user/pass and the provider's IP allow-list, or switch to another slot on the Pool screen. If the proxy is in fact usable, only the probe URL (${PROBE_URL:-https://www.gstatic.com/generate_204}) may be blocked — set PROBE_URL in /etc/sbproxy/env." \
    "$bad_why"
fi

# ---------------------------------------------------------------------------
# 8. The host itself
# ---------------------------------------------------------------------------
year="$(date +%Y 2>/dev/null || echo 0)"
case "$year" in
  ''|*[!0-9]*) : ;;
  *) [ "$year" -ge 2024 ] || add "clock_unset" "warn" "" \
       "Đồng hồ router sai (năm $year)" \
       "The router's clock is wrong (year $year)" \
       "Chứng chỉ TLS sẽ bị coi là chưa hợp lệ và nhiều proxy sẽ từ chối kết nối. Kiểm tra NTP." \
       "TLS certificates are treated as not yet valid and many proxies refuse the connection. Check NTP." ;;
esac
overlay="$(df /overlay 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 + 0 }')"
case "${overlay:-}" in
  ''|*[!0-9]*) : ;;
  *) [ "$overlay" -lt 90 ] || add "disk_full" "warn" "" \
       "Phân vùng /overlay đã dùng ${overlay}%" \
       "/overlay is ${overlay}% full" \
       "Hết chỗ thì backup, log và cập nhật đều hỏng. Xoá bớt backup cũ." \
       "With no room left, backups, logs and updates all fail. Delete old backups." ;;
esac

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
emit_report() {
  # Worst first, and stable inside a severity so the list does not jump around
  # between two scans of the same router.
  jq -s --argjson crit "$crit" --argjson warn "$warn_n" --argjson info "$info" \
        --arg ts "$(date +%s)" \
        --arg version "$(tr -d ' \r\n' < "$SB_ROOT/VERSION" 2>/dev/null || true)" '
    def rank: if .severity == "crit" then 0 elif .severity == "warn" then 1 else 2 end;
    ( [ to_entries[] | .value + {order: .key} ] | sort_by(rank, .order) | map(del(.order)) ) as $f
    | { ok: true,
        ts: ($ts | tonumber),
        version: $version,
        summary: { crit: $crit, warn: $warn, info: $info },
        healthy: ($crit == 0 and $warn == 0),
        verdict: ( if $crit > 0 then ($f | map(select(.severity == "crit")) | .[0])
                   elif $warn > 0 then ($f | map(select(.severity == "warn")) | .[0])
                   else null end
                 | if . == null then "Không phát hiện vấn đề nào." else .title end ),
        verdict_en: ( if $crit > 0 then ($f | map(select(.severity == "crit")) | .[0])
                      elif $warn > 0 then ($f | map(select(.severity == "warn")) | .[0])
                      else null end
                    | if . == null then "No problems found." else .title_en end ),
        findings: $f }' "$FIND_FILE"
}

# ---------------------------------------------------------------------------
# Repairs. Only these ids exist; anything else is refused by name.
# ---------------------------------------------------------------------------
fix_result() { # ok changed log [hint vi] [hint en]
  jq -n --argjson ok "$1" --argjson changed "$2" --arg log "$3" \
        --arg hint "${4:-}" --arg hint_en "${5:-}" \
    '{ok:$ok, changed:$changed, log:$log, hint:$hint, hint_en:$hint_en}'
}

do_fix() {
  case "$1" in
    singbox_restart)
      out="$(sh "$SB_ROOT/scripts/restart-singbox.sh" 2>&1)"; rc=$?
      # restart-singbox.sh already answers in JSON; hand its own fields through
      # so this shows exactly what the manual restart button shows.
      if printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -c '{ok: (.ok // false), changed: true, log: (.log // ""),
                                     hint: (.hint // ""), hint_en: (.hint // ""),
                                     running: .running, pid: .pid, uptime_s: .uptime_s,
                                     repaired: .repaired}'
      else
        fix_result "$([ "$rc" -eq 0 ] && echo true || echo false)" true "$out"
      fi
      ;;
    config_eol)
      changed=""
      for f in "$SETTINGS" "$CONF" "$POOLS"; do
        [ -f "$f" ] || continue
        [ -n "$(tr -dc '\r' < "$f" 2>/dev/null)" ] || continue
        run "sed -i 's/\r\$//' '$f'" && changed="${changed:+$changed }$f"
      done
      if [ -n "$changed" ]; then
        fix_result true true "Đã bỏ ký tự CR trong: $changed" \
          "Chạy lại quét hoặc Áp dụng để dùng giá trị đã sạch." \
          "Scan again, or apply, to use the cleaned values."
      else
        fix_result true false "Không file cấu hình nào còn CRLF."
      fi
      ;;
    bridge_nf)
      _bnf="${BRNF_PATH:-/proc/sys/net/bridge/bridge-nf-call-iptables}"
      if [ -f "$_bnf" ] && run "echo 0 > '$_bnf'"; then
        fix_result true true "Đã đặt $_bnf = 0" \
          "Thiết lập này mất khi router khởi động lại; apply.sh sẽ đặt lại." \
          "This resets when the router reboots; apply.sh sets it again."
      else
        fix_result false false "Không ghi được $_bnf"
      fi
      ;;
    apply)
      out="$(cd "$SB_ROOT" && sh scripts/apply.sh 2>&1)"; rc=$?
      fix_result "$([ "$rc" -eq 0 ] && echo true || echo false)" true "$out" \
        "Áp dụng có reload WiFi: thiết bị đang kết nối sẽ rớt vài giây." \
        "Applying reloads Wi-Fi: connected devices drop for a few seconds."
      ;;
    install_agent)
      out="$(cd "$SB_ROOT" && sh agent/install-agent.sh 2>&1)"; rc=$?
      fix_result "$([ "$rc" -eq 0 ] && echo true || echo false)" true "$out" \
        "Tải lại trang (Ctrl+F5) để dùng bản agent mới." \
        "Reload the page (Ctrl+F5) to pick up the new agent."
      ;;
    *)
      jq -n --arg id "$1" '{ok:false, changed:false, log:"",
                            error:("không có cách sửa nào tên: " + $id)}'
      return 1
      ;;
  esac
}

case "${1:-report}" in
  report) emit_report ;;
  fix)
    [ "$#" -ge 2 ] || { echo '{"ok":false,"error":"fix cần một id"}'; exit 1; }
    do_fix "$2"
    ;;
  *) echo '{"ok":false,"error":"usage: debug-agent.sh [report|fix <id>]"}'; exit 1 ;;
esac
