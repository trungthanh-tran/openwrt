#!/bin/sh
# restart-singbox.sh — repair, restart, and PROVE sing-box came back, as JSON.
#
#   restart-singbox.sh   -> {ok, running, pid, uptime_s, enabled, config_ok,
#                            repaired, hint, log}
#
# `ok` is true only when one sing-box process is still alive a few seconds
# later. A router-state problem (service disabled, unreadable config, broken
# config.json, crash on start) is reported in the JSON, not as a non-zero exit:
# the agent relays the answer to the console, and the console is what shows the
# operator why the proxy engine is down.
#
# The two faults this repairs before giving up:
#   * the packaged service left disabled (`enabled 0`), which makes
#     `/etc/init.d/sing-box restart` succeed while starting nothing;
#   * a config.json the service user cannot read, which crash-loops it with
#     "permission denied" — created by any apply that ran under a tight umask.
set -u
SB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export SB_ROOT
. "$SB_ROOT/scripts/lib.sh"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 0; }
SINGBOX_INIT="${SINGBOX_INIT:-/etc/init.d/sing-box}"
SINGBOX_CONF="${SINGBOX_CONF:-/etc/sing-box/config.json}"
wait_s="${SINGBOX_START_WAIT:-6}"
case "$wait_s" in ''|*[!0-9]*) wait_s=6 ;; esac

log_text=""; repaired=""
note() { log_text="${log_text}${log_text:+
}$*"; }
did() { repaired="${repaired}${repaired:+, }$1"; note "repair: $1"; }

recent_log() {
  command -v logread >/dev/null 2>&1 || return 0
  logread -e sing-box 2>/dev/null | tail -n "${1:-15}" | tr -d '\r'
}
# The service reads its config as some user; ask the log whether that failed.
denied_recently() { recent_log 40 | grep -qi 'permission denied'; }

start_once() { # -> sets restart_rc
  if [ -x "$SINGBOX_INIT" ]; then
    _out="$("$SINGBOX_INIT" restart 2>&1)"; restart_rc=$?
    note "$SINGBOX_INIT restart -> exit $restart_rc"
    [ -z "$_out" ] || note "$_out"
  else
    restart_rc=127
    note "$SINGBOX_INIT is missing: the sing-box package is not installed"
  fi
}

# Wait for a process, then require the SAME pid a moment later: procd respawns
# a crashing service every few seconds, so "a pid exists" is not "it started".
settled() {
  _w="$wait_s"
  while [ "$_w" -gt 0 ]; do
    singbox_pid >/dev/null 2>&1 && break
    sleep 1; _w=$((_w - 1))
  done
  singbox_running_stable
}

# 1. The service flag the OpenWrt package ships as 0.
was_enabled="$(uci -q get sing-box.main.enabled 2>/dev/null || true)"
svc_out="$( (ensure_singbox_service) 2>&1 )"
[ -z "$svc_out" ] || note "$svc_out"
[ "$was_enabled" = "0" ] && did "enabled the sing-box service (it was off)"

# 2. Make sure the service user can read its own configuration, then start.
acc_out="$( (ensure_singbox_conf_access "$SINGBOX_CONF") 2>&1 )"
[ -z "$acc_out" ] || note "$acc_out"
start_once
running=false; settled && running=true

# 3. Still down because it cannot read the config? The service is running as a
#    user that has no access to a file full of proxy passwords. Hand the
#    service to root — this project needs a privileged sing-box anyway (TPROXY
#    sockets, a cache file under /etc) — and try exactly once more.
if [ "$running" = false ] && denied_recently; then
  note "sing-box cannot read $SINGBOX_CONF (permission denied)"
  svc_user="$(uci -q get sing-box.main.user 2>/dev/null || true)"
  if command -v uci >/dev/null 2>&1 && [ "$svc_user" != "root" ]; then
    uci set sing-box.main.user='root' 2>/dev/null && uci commit sing-box 2>/dev/null \
      && did "set the sing-box service to run as root (was '${svc_user:-package default}')"
    start_once
    settled && running=true
  fi
fi

# 4. What the answer says about the two usual causes.
pid=""; uptime_s=null
if [ "$running" = true ]; then
  pid="$(singbox_pid 2>/dev/null || true)"
  _up="$(singbox_uptime_s 2>/dev/null || true)"
  case "$_up" in ''|*[!0-9]*) : ;; *) uptime_s="$_up" ;; esac
fi
enabled="$(uci -q get sing-box.main.enabled 2>/dev/null || true)"
config_ok=null; check_out=""
if [ -f "$SINGBOX_CONF" ] && command -v sing-box >/dev/null 2>&1; then
  if check_out="$( (singbox_check "$SINGBOX_CONF") 2>&1 )"; then config_ok=true; else config_ok=false; fi
fi

hint=""
if [ "$running" = true ]; then
  hint="sing-box is running (pid $pid)${repaired:+ after repair: $repaired}"
elif [ "$restart_rc" -eq 127 ]; then
  hint="install the sing-box package (scripts/install-deps.sh) and re-run apply"
elif [ "$enabled" = "0" ]; then
  hint="/etc/config/sing-box still has enabled=0: uci set sing-box.main.enabled=1; uci commit sing-box; then restart again"
elif denied_recently; then
  hint="sing-box still cannot read $SINGBOX_CONF; check its owner and the service user (uci get sing-box.main.user)"
elif [ "$config_ok" = false ]; then
  hint="config.json fails 'sing-box check' — re-run apply (Push & Apply) to regenerate it; details in log"
elif [ ! -f "$SINGBOX_CONF" ]; then
  hint="$SINGBOX_CONF does not exist yet — run apply (Push & Apply) once to generate it"
elif singbox_pid >/dev/null 2>&1; then
  hint="sing-box keeps restarting (a new pid every few seconds): it starts and dies, read the log below"
else
  hint="sing-box exited right after starting; read the log below, then re-run apply"
fi
[ -z "$check_out" ] || [ "$config_ok" != false ] || note "sing-box check: $(printf '%s' "$check_out" | tail -n 5)"
tail_log="$(recent_log 15)"
[ -z "$tail_log" ] || note "--- logread -e sing-box (last 15) ---
$tail_log"

jq -n --argjson running "$running" --arg pid "$pid" --argjson uptime_s "$uptime_s" \
      --arg enabled "$enabled" --argjson config_ok "$config_ok" \
      --arg repaired "$repaired" --arg hint "$hint" --arg log "$log_text" \
      --argjson rc "$restart_rc" \
  '{ok:$running, running:$running, pid:($pid|try tonumber catch null), uptime_s:$uptime_s,
    enabled:(if $enabled == "" then null else $enabled == "1" end),
    config_ok:$config_ok, restart_exit:$rc,
    repaired:(if $repaired == "" then null else $repaired end),
    hint:$hint, log:$log}'
