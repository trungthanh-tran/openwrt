#!/bin/sh
# restart-singbox.sh — restart sing-box and PROVE it came back, as JSON.
#
#   restart-singbox.sh   -> {ok, running, pid, enabled, config_ok, hint, log}
#
# `ok` is true only when a sing-box process is alive afterwards. A router-state
# problem (service disabled, broken config.json, crash on start) is reported in
# the JSON, not as a non-zero exit: the agent relays the answer to the console,
# and the console is what shows the operator why the proxy engine is down.
#
# Same repair sequence apply.sh uses: turn the packaged service on if the
# firmware left it disabled, restart, then wait for the process instead of
# trusting the init script's silent success.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 0; }
SINGBOX_INIT="${SINGBOX_INIT:-/etc/init.d/sing-box}"
SINGBOX_CONF="${SINGBOX_CONF:-/etc/sing-box/config.json}"
wait_s="${SINGBOX_START_WAIT:-6}"
case "$wait_s" in ''|*[!0-9]*) wait_s=6 ;; esac

log_text=""
note() { log_text="${log_text}${log_text:+
}$*"; }

# 1. The service flag the OpenWrt package ships as 0.
svc_out="$( (ensure_singbox_service) 2>&1 )"
[ -z "$svc_out" ] || note "$svc_out"

# 2. Restart.
if [ -x "$SINGBOX_INIT" ]; then
  restart_out="$("$SINGBOX_INIT" restart 2>&1)"; restart_rc=$?
  note "$SINGBOX_INIT restart -> exit $restart_rc"
  [ -z "$restart_out" ] || note "$restart_out"
else
  restart_rc=127
  note "$SINGBOX_INIT is missing: the sing-box package is not installed"
fi

# 3. Wait for the process; the init script returning 0 proves nothing.
running=false; pid=""
while [ "$wait_s" -gt 0 ]; do
  if pgrep -f sing-box >/dev/null 2>&1; then
    running=true
    pid="$(pgrep -f sing-box 2>/dev/null | head -n 1 | tr -d ' \r\n')"
    break
  fi
  sleep 1; wait_s=$((wait_s - 1))
done

# 4. The two usual causes, checked so the answer names them.
enabled="$(uci -q get sing-box.main.enabled 2>/dev/null || true)"
config_ok=null; check_out=""
if [ -f "$SINGBOX_CONF" ] && command -v sing-box >/dev/null 2>&1; then
  if check_out="$( (singbox_check "$SINGBOX_CONF") 2>&1 )"; then config_ok=true; else config_ok=false; fi
fi
tail_log=""
command -v logread >/dev/null 2>&1 && tail_log="$(logread -e sing-box 2>/dev/null | tail -n 15 | tr -d '\r')"

hint=""
if [ "$running" = true ]; then
  hint="sing-box is running (pid $pid)"
elif [ "$restart_rc" -eq 127 ]; then
  hint="install the sing-box package (scripts/install-deps.sh) and re-run apply"
elif [ "$enabled" = "0" ]; then
  hint="/etc/config/sing-box still has enabled=0: uci set sing-box.main.enabled=1; uci commit sing-box; then restart again"
elif [ "$config_ok" = false ]; then
  hint="config.json fails 'sing-box check' — re-run apply (Push & Apply) to regenerate it; details in log"
elif [ ! -f "$SINGBOX_CONF" ]; then
  hint="$SINGBOX_CONF does not exist yet — run apply (Push & Apply) once to generate it"
else
  hint="sing-box exited right after starting; read the log below, then re-run apply"
fi
[ -z "$check_out" ] || [ "$config_ok" != false ] || note "sing-box check: $(printf '%s' "$check_out" | tail -n 5)"
[ -z "$tail_log" ] || note "--- logread -e sing-box (last 15) ---
$tail_log"

jq -n --argjson running "$running" --arg pid "$pid" --arg enabled "$enabled" \
      --argjson config_ok "$config_ok" --arg hint "$hint" --arg log "$log_text" \
      --argjson rc "$restart_rc" \
  '{ok:$running, running:$running, pid:($pid|try tonumber catch null),
    enabled:(if $enabled == "" then null else $enabled == "1" end),
    config_ok:$config_ok, restart_exit:$rc, hint:$hint, log:$log}'
