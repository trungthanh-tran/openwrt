#!/bin/sh
# Integration tests for agent/sbproxy-healthd with deterministic curl results.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEALTHD="$ROOT/agent/sbproxy-healthd"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP health daemon integration tests: jq is required"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
BIN="$TMP/bin"
CONF="$TMP/wifi-socks.conf"
HEALTH_FILE="$TMP/health.json"
CURL_CALLS="$TMP/curl.log"
mkdir -p "$BIN"
: > "$CURL_CALLS"

cat > "$BIN/curl" <<'SH'
#!/bin/sh
proxy=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -x) proxy="$2"; shift 2 ;;
    -o|-m|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$proxy" >> "$CURL_CALLS"
# probe-proxy.sh side checks: plain TCP, direct Internet, public IP.
if [ -z "$proxy" ]; then
  case "$url" in
    telnet://offline.example:*) exit 7 ;;
    telnet://*) exit 56 ;;
    *ipify*) [ "${NO_PUBLIC_IP:-0}" = 1 ] && exit 6; printf '203.0.113.9'; exit 0 ;;
    *) [ "${DIRECT_DOWN:-0}" = 1 ] && exit 7; printf '204 0.050'; exit 0 ;;
  esac
fi
case "$proxy" in
  *fast.example*) printf '204 0.100' ;;
  *slow.example*) printf '200 0.801' ;;
  *edge.example*) printf '302 0.800' ;;
  *badcode.example*) printf '500 0.050' ;;
  *offline.example*) echo "curl: (7) Failed to connect to offline.example port 5080: Connection refused (user secret:hunter2)" >&2; exit 7 ;;
  *nan.example*) printf '204 NaN' ;;
  *garbled.example*) printf 'garbled output' ;;
  *) printf '301 0.010' ;;
esac
SH
chmod +x "$BIN/curl"

cat > "$CONF" <<'EOF'
# name|band|idx|key|host|port|user|pass|isolate|webrtc
Fast|2g|1|password12|fast.example|1080|||1|1
Slow|5g|2|password12|slow.example|2080|alice|secret|1|1
Edge|2g|3|password12|edge.example|3080|||1|1
BadCode|2g|4|password12|badcode.example|4080|||1|1
Offline|5g|5|password12|offline.example|5080|carol|hunter2|1|1
Http|2g|6|password12|http.example|6080|bob|pw|1|1||http

EOF

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
contains() { if printf '%s' "$2" | grep -Fq "$3"; then ok "$1"; else no "$1 — missing [$3]"; fi; }

echo "== health daemon probe states =="
export CONF HEALTH_FILE CURL_CALLS
export PATH="$BIN:$PATH"
export PROBE_URL='https://probe.example/204' PROBE_TIMEOUT=3 SLOW_MS=800
if sh "$HEALTHD" --once; then ok "--once succeeds"; else no "--once succeeds"; fi
if jq -e . "$HEALTH_FILE" >/dev/null 2>&1; then ok "health output is valid JSON"; else no "health output is valid JSON"; fi
eq "all configured probes emitted" "$(jq '.probes | length' "$HEALTH_FILE")" '6'
eq "204 below threshold is ok" "$(jq -r '.probes["1"].state' "$HEALTH_FILE")" 'ok'
eq "latency rounds to milliseconds" "$(jq -r '.probes["1"].latency_ms' "$HEALTH_FILE")" '100'
eq "latency above threshold is slow" "$(jq -r '.probes["2"].state' "$HEALTH_FILE")" 'slow'
eq "threshold equality remains ok" "$(jq -r '.probes["3"].state' "$HEALTH_FILE")" 'ok'
eq "unexpected HTTP code is fail" "$(jq -r '.probes["4"].state' "$HEALTH_FILE")" 'fail'
eq "unexpected HTTP code is retained" "$(jq -r '.probes["4"].code' "$HEALTH_FILE")" '500'
eq "curl transport failure is fail" "$(jq -r '.probes["5"].state' "$HEALTH_FILE")" 'fail'
eq "curl transport failure code defaults zero" "$(jq -r '.probes["5"].code' "$HEALTH_FILE")" '0'
eq "the failure reason is kept"  "$(jq -r '.probes["5"].error' "$HEALTH_FILE" | cut -c1-40)" 'curl exit 7: curl: (7) Failed to connect'
eq "the password is blanked in the reason" "$(jq -r '.probes["5"].error' "$HEALTH_FILE" | grep -c hunter2)" '0'
eq "a bad HTTP code explains itself" "$(jq -r '.probes["4"].error' "$HEALTH_FILE")" 'probe URL answered HTTP 500 through the proxy'
eq "a healthy probe carries no error" "$(jq -r '.probes["1"] | has("error")' "$HEALTH_FILE")" 'false'

echo "== probe-proxy.sh: one proxy, with the reason =="
PROBE="$ROOT/scripts/probe-proxy.sh"
out="$(sh "$PROBE" fast.example 1080 "" "" socks5)"
eq "probe: a good proxy is ok"        "$(printf '%s' "$out" | jq -r .state)" 'ok'
eq "probe: latency is carried"        "$(printf '%s' "$out" | jq -r .latency_ms)" '100'
out="$(sh "$PROBE" offline.example 5080 carol hunter2 socks5)"
eq "probe: a dead proxy is fail"      "$(printf '%s' "$out" | jq -r .state)" 'fail'
eq "probe: curl exit is carried"      "$(printf '%s' "$out" | jq -r .curl_exit)" '7'
eq "probe: the curl error is carried" "$(printf '%s' "$out" | jq -r .error | cut -c1-9)" 'curl: (7)'
eq "probe: the hint names the cause"  "$(printf '%s' "$out" | jq -r .hint | grep -c 'cannot connect')" '1'
eq "probe: the password is blanked"   "$(printf '%s' "$out" | jq -r '.error + .transcript' | grep -c hunter2)" '0'
eq "probe: TCP refusal is seen"       "$(printf '%s' "$out" | jq -r .checks.tcp_open)" 'false'
eq "probe: direct Internet is seen"   "$(printf '%s' "$out" | jq -r .checks.direct_internet)" 'true'
eq "probe: public IP is reported"     "$(printf '%s' "$out" | jq -r .checks.public_ip)" '203.0.113.9'
eq "probe: verdict is blocked"        "$(printf '%s' "$out" | jq -r .verdict | cut -d: -f1)" 'blocked'
eq "probe: verdict names the IP"      "$(printf '%s' "$out" | jq -r .verdict | grep -c 203.0.113.9)" '1'
out="$(NO_PUBLIC_IP=1 sh "$PROBE" offline.example 5080)"
eq "probe: no public IP -> verdict still reads" "$(printf '%s' "$out" | jq -r .verdict | grep -c 'add the router public IP')" '1'
eq "probe: no public IP is empty, not garbage" "$(printf '%s' "$out" | jq -r .checks.public_ip)" ''
out="$(sh "$PROBE" badcode.example 4080)"
eq "probe: TCP open + handshake fail is socks-refused" "$(printf '%s' "$out" | jq -r .verdict | cut -d: -f1)" 'socks-refused'
out="$(DIRECT_DOWN=1 sh "$PROBE" offline.example 5080)"
eq "probe: no WAN is wan-down"        "$(printf '%s' "$out" | jq -r .verdict | cut -d: -f1)" 'wan-down'
out="$(sh "$PROBE" fast.example 1080)"
eq "probe: a good proxy verdict is ok" "$(printf '%s' "$out" | jq -r .verdict | cut -d: -f1)" 'ok'
out="$(sh "$PROBE" 'bad host' 1080)"
eq "probe: a dirty host is refused"   "$(printf '%s' "$out" | jq -r .ok)" 'false'
out="$(sh "$PROBE" fast.example 1080 "" "" ftp)"
eq "probe: a wrong type is refused"   "$(printf '%s' "$out" | jq -r .ok)" 'false'
if jq -e '.ts | type == "number" and . > 0' "$HEALTH_FILE" >/dev/null; then ok "timestamp is numeric"; else no "timestamp is numeric"; fi
contains "unauthenticated proxy URL uses socks5h" "$(cat "$CURL_CALLS")" 'socks5h://fast.example:1080'
contains "authenticated proxy URL uses credentials" "$(cat "$CURL_CALLS")" 'socks5h://alice:secret@slow.example:2080'
contains "HTTP proxy URL uses HTTP scheme" "$(cat "$CURL_CALLS")" 'http://bob:pw@http.example:6080'
if find "$TMP" -maxdepth 1 -name 'health.json.tmp.*' | grep -q .; then no "temporary output cleaned"; else ok "temporary output cleaned"; fi

echo "== health daemon edge failures =="
rm -f "$HEALTH_FILE"
if CONF="$TMP/missing.conf" sh "$HEALTHD" --once >/dev/null 2>&1; then
  no "missing config fails"
else
  ok "missing config fails"
fi
if [ -e "$HEALTH_FILE" ]; then no "missing config does not publish stale output"; else ok "missing config does not publish output"; fi

NO_DEPS="$TMP/no-deps"
mkdir -p "$NO_DEPS"
if PATH="$NO_DEPS" /bin/sh "$HEALTHD" --once >"$TMP/no-jq.out" 2>&1; then
  no "missing jq fails"
else
  ok "missing jq fails"
fi
contains "missing jq error is actionable" "$(cat "$TMP/no-jq.out")" 'jq is missing'

echo "== health daemon dirty config and probe output =="
cat > "$CONF" <<'EOF'
Valid|2g|6|password12|fast.example|1080|||1|1|
NaNTime|2g|7|password12|nan.example|1080|||1|1|
Garbled|5g|8|password12|garbled.example|1080|||1|1|
BadIdx|2g|x|password12|fast.example|1080|||1|1|
LowIdx|2g|0|password12|fast.example|1080|||1|1|
HighIdx|2g|201|password12|fast.example|1080|||1|1|
BadHost|2g|9|password12|bad host|1080|||1|1|
BadPort|2g|10|password12|fast.example|99999|||1|1|
BadBand|6g|11|password12|fast.example|1080|||1|1|
BadFlag|2g|12|password12|fast.example|1080|||2|1|
TooFew|2g|13|password12|fast.example
TooMany|2g|14|password12|fast.example|1080|||1|1||surplus
EOF
: > "$CURL_CALLS"
if sh "$HEALTHD" --once; then ok "dirty config run still succeeds"; else no "dirty config run still succeeds"; fi
eq "only valid endpoint rows are published" "$(jq -r '.probes | keys | join(",")' "$HEALTH_FILE")" '6,7,8'
eq "NaN latency is normalized to failure" "$(jq -r '.probes["7"] | [.state,.latency_ms,.code] | join(":")' "$HEALTH_FILE")" 'fail:0:204'
eq "garbled curl output is normalized to failure" "$(jq -r '.probes["8"] | [.state,.latency_ms,.code] | join(":")' "$HEALTH_FILE")" 'fail:0:0'
eq "dirty rows never invoke curl" "$(wc -l < "$CURL_CALLS" | tr -d ' ')" '3'

echo ""
printf 'HEALTHD TOTAL: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
