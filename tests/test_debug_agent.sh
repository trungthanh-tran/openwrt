#!/bin/sh
# tests/test_debug_agent.sh — scripts/debug-agent.sh against a stubbed router.
#
# The assistant's whole value is that a wrong rule is worse than no rule: it
# tells an operator to run a repair. So every finding is produced here from a
# fake router in a known state, and the healthy router is checked as carefully
# as the broken ones -- a rule that fires on a working box would send people
# restarting a service that is fine.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"

pass=0; fail=0
ok()      { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()      { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()      { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
match()   { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else no "$1 — no /$3/"; fi; }
nomatch() { if printf '%s' "$2" | grep -Eq "$3"; then no "$1 — unexpected /$3/"; else ok "$1"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "== debug-agent =="; printf '  skip (jq is not installed)\n'
  echo "DEBUG AGENT TOTAL: pass=0 fail=0 skip=1"; exit 0
fi

SB="$TMP/sbproxy"; mkdir -p "$SB/scripts" "$SB/config" "$SB/agent/cgi"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/debug-agent.sh" "$SB/scripts/"
printf '0.0.0-TEST\n' > "$SB/VERSION"
printf 'alpha|2g|1|password12|p.example|1080|u|pw|1|1||socks5\n' > "$SB/config/wifi-socks.conf"
: > "$SB/config/proxy-pools.conf"
printf 'agent v1\n' > "$SB/agent/cgi/sbproxy"

# Every router-only tool is a stub driven by an environment variable, so one
# fault can be introduced at a time.
cat > "$BIN/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "${2:-}" in
  sing-box.main)         [ "${SB_SERVICE:-1}" = 1 ] || exit 1; echo main ;;
  sing-box.main.enabled) echo "${SB_ENABLED:-1}" ;;
  sing-box.main.user)    [ -n "${SB_USER:-}" ] || exit 1; echo "$SB_USER" ;;
  *) exit 1 ;;
esac
SH
cat > "$BIN/nft" <<'SH'
#!/bin/sh
[ "${NFT_TABLE:-1}" = 1 ] || exit 1
exit 0
SH
cat > "$BIN/ip" <<'SH'
#!/bin/sh
case "${1:-}" in
  rule)  [ "${IP_RULE:-1}" = 1 ] && echo "100: from all fwmark 0x1 lookup 100"; exit 0 ;;
  route) [ "${DEFAULT_ROUTE:-1}" = 1 ] && echo "default via 192.168.1.1 dev eth0"; exit 0 ;;
esac
exit 0
SH
cat > "$BIN/logread" <<'SH'
#!/bin/sh
printf '%s\n' "${SB_LOG:-daemon.info sing-box: started}"
SH
cat > "$BIN/iw" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$BIN/ubus" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$BIN/sing-box" <<'SH'
#!/bin/sh
echo "sing-box version 1.12.0"
SH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# A running sing-box is a process named sing-box under PROC_DIR; the empty tree
# is a stopped one.
PROC_UP="$TMP/proc-up"; PROC_DOWN="$TMP/proc-down"
mkdir -p "$PROC_UP/4242" "$PROC_DOWN"
printf 'sing-box\n' > "$PROC_UP/4242/comm"
printf '4242 (sing-box) S %s 900\n' "$(i=0; while [ $i -lt 18 ]; do printf '0 '; i=$((i+1)); done)" > "$PROC_UP/4242/stat"
printf '1000.00 900.00\n' > "$PROC_UP/uptime"        # started 991s ago
YOUNG="$TMP/proc-young"; mkdir -p "$YOUNG/4242"
cp "$PROC_UP/4242/comm" "$PROC_UP/4242/stat" "$YOUNG/4242/"
printf '12.00 9.00\n' > "$YOUNG/uptime"              # started 3s ago

SBCONF="$TMP/config.json"; printf '{}\n' > "$SBCONF"
HEALTH="$TMP/health.json"; printf '{"ts":1,"probes":{}}\n' > "$HEALTH"
CGI_INSTALLED="$TMP/cgi-installed"; printf 'agent v1\n' > "$CGI_INSTALLED"
ASSETS="$TMP/bootstrap.min.css"; : > "$ASSETS"
WEBAUTH="$TMP/webauth"; printf 'admin:aa:bb\n' > "$WEBAUTH"

write_settings() {  # lib.sh sources settings.sh, so overrides belong in it
  # settings.sh assigns SINGBOX_CONF outright, so an environment variable is
  # overwritten the moment lib.sh is sourced. The fake router declares its own
  # paths the way a real one would.
  cat "$ROOT/config/settings.sh" > "$SB/config/settings.sh"
  {
    printf 'BRNF_PATH="%s"\n' "${1:-$TMP/absent-bridge-nf}"
    printf 'SINGBOX_CONF="%s"\n' "${2:-$SBCONF}"
  } >> "$SB/config/settings.sh"
}
write_settings

report() {  # report [env assignments...]
  env SB_ROOT="$SB" PROC_DIR="$PROC_UP" HEALTH_FILE="$HEALTH" \
      CGI_DEST="$CGI_INSTALLED" UI_ASSETS="$ASSETS" WEBAUTH_FILE="$WEBAUTH" \
      "$@" sh "$SB/scripts/debug-agent.sh" report 2>/dev/null
}
ids()  { printf '%s' "$1" | jq -r '[.findings[].id] | join(" ")'; }
sev()  { printf '%s' "$1" | jq -r --arg id "$2" '.findings[] | select(.id == $id) | .severity'; }
fixof() { printf '%s' "$1" | jq -r --arg id "$2" '.findings[] | select(.id == $id) | .fix'; }

echo "== debug-agent: a healthy router is left alone =="
out="$(report)"
eq "the report is valid JSON"        "$(printf '%s' "$out" | jq -r '.ok')" "true"
eq "nothing is wrong"                "$(printf '%s' "$out" | jq -r '.healthy')" "true"
eq "no critical finding"             "$(printf '%s' "$out" | jq -r '.summary.crit')" "0"
eq "no warning either"               "$(printf '%s' "$out" | jq -r '.summary.warn')" "0"
match "the verdict says so"          "$(printf '%s' "$out" | jq -r '.verdict')" 'Không phát hiện'
match "in English too"               "$(printf '%s' "$out" | jq -r '.verdict_en')" 'No problems found'
eq "the router version is reported"  "$(printf '%s' "$out" | jq -r '.version')" "0.0.0-TEST"

echo "== debug-agent: the engine =="
out="$(report PROC_DIR="$PROC_DOWN")"
match "a stopped sing-box is found"  "$(ids "$out")" 'singbox_down'
eq "and it is critical"              "$(sev "$out" singbox_down)" "crit"
eq "and it offers the restart"       "$(fixof "$out" singbox_down)" "singbox_restart"
match "the log rides along"          "$(printf '%s' "$out" | jq -r '.findings[] | select(.id == "singbox_down") | .evidence')" 'sing-box'
eq "the verdict is the worst one"    "$(printf '%s' "$out" | jq -r '.verdict_en')" "sing-box is NOT running"

out="$(report PROC_DIR="$YOUNG")"
match "a young process reads as flapping" "$(ids "$out")" 'singbox_flapping'
nomatch "and is not also reported as down" "$(ids "$out")" 'singbox_down'

out="$(report SB_LOG='daemon.err sing-box: FATAL read config: permission denied')"
match "permission denied is named"   "$(ids "$out")" 'singbox_denied'
eq "and points at the restart"       "$(fixof "$out" singbox_denied)" "singbox_restart"

out="$(report SB_ENABLED=0)"
match "a disabled service is found"  "$(ids "$out")" 'singbox_disabled'
out="$(report SB_USER=sing-box)"
match "an unreadable config is found" "$(ids "$out")" 'singbox_conf_access'
out="$(report SB_USER=root)"
nomatch "a root service is never accused" "$(ids "$out")" 'singbox_conf_access'
write_settings "$TMP/absent-bridge-nf" "$TMP/absent.json"
out="$(report)"
match "a missing config is found"    "$(ids "$out")" 'singbox_conf_missing'
eq "and apply is the fix"            "$(fixof "$out" singbox_conf_missing)" "apply"
write_settings

echo "== debug-agent: the data path =="
out="$(report NFT_TABLE=0)"
match "a missing nft table is found" "$(ids "$out")" 'nft_missing'
out="$(report IP_RULE=0)"
match "a missing fwmark rule is found" "$(ids "$out")" 'ip_rule_missing'
BRNF="$TMP/bridge-nf"; printf '1\n' > "$BRNF"; write_settings "$BRNF"
out="$(report)"
match "bridge-nf=1 is found"         "$(ids "$out")" 'bridge_nf'
printf '0\n' > "$BRNF"
out="$(report)"
nomatch "bridge-nf=0 is fine"        "$(ids "$out")" 'bridge_nf'
write_settings

# An empty configuration means the data path is not built yet, and reporting
# three critical faults for a router waiting to be configured is noise.
: > "$SB/config/wifi-socks.conf"
out="$(report NFT_TABLE=0 IP_RULE=0)"
nomatch "no data-path noise without SSIDs" "$(ids "$out")" 'nft_missing|ip_rule_missing'
match "the empty configuration is noted"   "$(ids "$out")" 'conf_empty'
eq "as information, not a fault"           "$(sev "$out" conf_empty)" "info"
printf 'alpha|2g|1|password12|p.example|1080|u|pw|1|1||socks5\n' > "$SB/config/wifi-socks.conf"

echo "== debug-agent: egress, agent and host =="
out="$(report DEFAULT_ROUTE=0)"
match "a router with no uplink is found" "$(ids "$out")" 'wan_down'
printf 'agent v2 (newer)\n' > "$SB/agent/cgi/sbproxy"
out="$(report)"
match "a stale installed agent is found" "$(ids "$out")" 'agent_stale'
eq "as a warning"                        "$(sev "$out" agent_stale)" "warn"
eq "fixed by reinstalling"               "$(fixof "$out" agent_stale)" "install_agent"
printf 'agent v1\n' > "$SB/agent/cgi/sbproxy"
out="$(report UI_ASSETS="$TMP/absent.css")"
match "missing UI assets are found"      "$(ids "$out")" 'ui_assets_missing'
out="$(report WEBAUTH_FILE="$TMP/absent-auth")"
eq "a missing web account is only a note" "$(sev "$out" webauth_missing)" "info"
printf '{"ts":1,"probes":{"1":{"state":"fail","error":"curl exit 7: refused"},"2":{"state":"ok"}}}\n' > "$HEALTH"
out="$(report)"
match "a failing proxy is reported"      "$(ids "$out")" 'proxy_fail'
match "and the SSID is named"            "$(printf '%s' "$out" | jq -r '.findings[] | select(.id == "proxy_fail") | .title')" '1'
# "fail" alone cannot tell a dead proxy from a probe URL the proxy will not
# fetch, and those two need opposite fixes.
match "the probe error travels with it"  "$(printf '%s' "$out" | jq -r '.findings[] | select(.id == "proxy_fail") | .evidence')" 'curl exit 7'
match "and the probe URL is named"       "$(printf '%s' "$out" | jq -r '.findings[] | select(.id == "proxy_fail") | .detail_en')" 'PROBE_URL'
printf '{"ts":1,"probes":{}}\n' > "$HEALTH"

# The console used to pre-fill 127.0.0.1:1080, which then became the live
# outbound of every SSID whose operator used a pool instead.
printf 'alpha|2g|1|password12|127.0.0.1|1080|u|pw|1|1||socks5\n' > "$SB/config/wifi-socks.conf"
out="$(report)"
match "a loopback proxy is found"        "$(ids "$out")" 'proxy_loopback'
eq "and it is critical"                  "$(sev "$out" proxy_loopback)" "crit"
match "the SSID is named"                "$(printf '%s' "$out" | jq -r '.findings[] | select(.id == "proxy_loopback") | .title')" '1'
printf 'alpha|2g|1|password12|p.example|1080|u|pw|1|1||socks5\n' > "$SB/config/wifi-socks.conf"
out="$(report)"
nomatch "a real proxy is not accused"    "$(ids "$out")" 'proxy_loopback'

echo "== debug-agent: CRLF configuration =="
printf 'WIFI_COUNTRY="VN"\r\n' >> "$SB/config/settings.sh"
out="$(report)"
match "a CRLF settings.sh is found"  "$(ids "$out")" 'config_eol'
eq "and the assistant can fix it"    "$(fixof "$out" config_eol)" "config_eol"

echo "== debug-agent: ordering and shape =="
out="$(report PROC_DIR="$PROC_DOWN" UI_ASSETS="$TMP/absent.css")"
eq "the worst finding is first" "$(printf '%s' "$out" | jq -r '.findings[0].severity')" "crit"
eq "notes sort last"            "$(printf '%s' "$out" | jq -r '.findings[-1].severity')" "warn"
eq "every finding has both languages" \
   "$(printf '%s' "$out" | jq '[.findings[] | select((.title_en | length) > 0 and (.detail_en | length) > 0)] | length')" \
   "$(printf '%s' "$out" | jq '.findings | length')"
eq "every fix names a known repair" \
   "$(printf '%s' "$out" | jq -r '[.findings[].fix | select(. != "")] | map(select(. == "singbox_restart" or . == "config_eol" or . == "bridge_nf" or . == "apply" or . == "install_agent")) | length')" \
   "$(printf '%s' "$out" | jq -r '[.findings[].fix | select(. != "")] | length')"
nomatch "no secret travels in the report" "$out" 'password12|pw'

echo "== debug-agent: fixing =="
fix() { env SB_ROOT="$SB" "$@" sh "$SB/scripts/debug-agent.sh" fix "$1" 2>&1; }
out="$(env SB_ROOT="$SB" sh "$SB/scripts/debug-agent.sh" fix bogus 2>&1)"; rc=$?
eq "an unknown repair is refused"   "$(printf '%s' "$out" | jq -r '.ok')" "false"
eq "and exits non-zero"             "$rc" "1"
match "the refusal names the id"    "$out" 'bogus'

# The CRLF appended above is still in the fake router's settings.sh.
out="$(env SB_ROOT="$SB" sh "$SB/scripts/debug-agent.sh" fix config_eol 2>&1)"
eq "the CRLF repair reports success" "$(printf '%s' "$out" | jq -r '.ok')" "true"
eq "and says it changed something"   "$(printf '%s' "$out" | jq -r '.changed')" "true"
eq "the carriage returns are gone"   "$(tr -dc '\r' < "$SB/config/settings.sh" | wc -c | tr -d ' ')" "0"
out="$(env SB_ROOT="$SB" sh "$SB/scripts/debug-agent.sh" fix config_eol 2>&1)"
eq "running it again changes nothing" "$(printf '%s' "$out" | jq -r '.changed')" "false"
eq "and still succeeds"               "$(printf '%s' "$out" | jq -r '.ok')" "true"

printf '1\n' > "$BRNF"; write_settings "$BRNF"
out="$(env SB_ROOT="$SB" sh "$SB/scripts/debug-agent.sh" fix bridge_nf 2>&1)"
eq "the bridge-nf repair succeeds"  "$(printf '%s' "$out" | jq -r '.ok')" "true"
eq "and the flag is off"            "$(cat "$BRNF")" "0"
write_settings

# DRYRUN is honoured, so a repair can be rehearsed without touching the router.
printf 'WIFI_COUNTRY="VN"\r\n' >> "$SB/config/settings.sh"
out="$(env SB_ROOT="$SB" DRYRUN=1 sh "$SB/scripts/debug-agent.sh" fix config_eol 2>/dev/null)"
eq "a dry run still answers ok"     "$(printf '%s' "$out" | jq -r '.ok')" "true"
if [ -n "$(tr -dc '\r' < "$SB/config/settings.sh")" ]; then
  ok "a dry run changes no file"
else
  no "a dry run changes no file"
fi
write_settings

printf '\nDEBUG AGENT TOTAL: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
