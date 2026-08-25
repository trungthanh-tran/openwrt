#!/bin/sh
# tests/test_pool_agent.sh — the four proxy-pool actions of agent/cgi/sbproxy.
#
# A fully isolated fake router, in the style of tests/test_agent.sh. The scripts
# the CGI shells out to are stubs that record their arguments: what the pool
# logic itself does is already covered by tests/test_pool.sh, so what matters
# here is the contract — auth, method, request shape, and that the right command
# is invoked with the right arguments.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/agent/cgi/sbproxy"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP pool agent tests: jq is required"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
SB_ROOT="$TMP/router"
CONF="$SB_ROOT/config/wifi-socks.conf"
POOLS="$SB_ROOT/config/proxy-pools.conf"
ASSIGN_FILE="$TMP/assign"
TOKEN_FILE="$TMP/token"
CALLS="$TMP/calls.log"
mkdir -p "$SB_ROOT/config" "$SB_ROOT/scripts"
printf '%s\n' 'agent-test-token' > "$TOKEN_FILE"
: > "$CALLS"
cp "$ROOT/scripts/lib.sh" "$SB_ROOT/scripts/lib.sh"
cp "$ROOT/config/settings.sh" "$SB_ROOT/config/settings.sh"

cat > "$SB_ROOT/scripts/pool.sh" <<'SH'
#!/bin/sh
# Record the verb, the idx and the rows it was handed.
printf 'pool:%s:%s:%s\n' "${1:-}" "${2:-}" "$(tr '\n' ';' < "${3:-/dev/null}")" >> "$CALLS"
echo "pool output"
exit "${POOL_RC:-0}"
SH

cat > "$SB_ROOT/scripts/assign.sh" <<'SH'
#!/bin/sh
printf 'assign:%s:%s:%s\n' "${1:-}" "${2:-}" "${3:-}" >> "$CALLS"
echo "assign output"
exit "${ASSIGN_RC:-0}"
SH

cat > "$SB_ROOT/scripts/rebalance.sh" <<'SH'
#!/bin/sh
printf 'rebalance:%s\n' "$*" >> "$CALLS"
echo "rebalance output"
exit "${REBALANCE_RC:-0}"
SH
chmod +x "$SB_ROOT/scripts/"*.sh

cat > "$CONF" <<'EOF'
Alpha|2g|1|alpha-password|1.2.3.4|1080|||1|0|50:C7:BF|socks5
Bravo|5g|2|bravo-password|5.6.7.8|1080|||1|0||socks5
EOF

export SB_ROOT CONF POOLS ASSIGN_FILE TOKEN_FILE CALLS
export TMPDIR="$TMP"
export POOL_RC=0 ASSIGN_RC=0 REBALANCE_RC=0

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }
# `--` matters: a pattern like --pool-file is otherwise read by grep as one of
# its own options, and the assertion fails while the code is correct.
contains() { if printf '%s' "$2" | grep -Fq -- "$3"; then ok "$1"; else no "$1 — missing[$3]"; fi; }
not_contains() { if printf '%s' "$2" | grep -Fq -- "$3"; then no "$1 — unexpected[$3]"; else ok "$1"; fi; }

body_of() { printf '%s\n' "$1" | awk '{sub(/\r$/, "")} body {print} /^$/ {body=1}'; }
json_value() { body_of "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'; }
reset_calls() { : > "$CALLS"; }
run_agent() {
  printf '%s' "${4:-}" | REQUEST_METHOD="$1" QUERY_STRING="$2" \
    HTTP_AUTHORIZATION="${3:-}" HTTP_X_SB_TOKEN="" CONTENT_LENGTH="" sh "$AGENT"
}
auth_run() { run_agent "$1" "$2" 'Bearer agent-test-token' "${3:-}"; }

echo "== pool actions: auth and method =="
for a in get_pool save_pool assign_proxy rebalance; do
  out="$(run_agent GET "action=$a&idx=1")"
  contains "$a needs a token" "$out" 'Status: 401 Unauthorized'
done
out="$(auth_run POST 'action=get_pool&idx=1' '{}')"
contains "get_pool is GET only" "$out" 'Status: 405 Method Not Allowed'
for a in save_pool assign_proxy rebalance; do
  out="$(auth_run GET "action=$a&idx=1")"
  contains "$a is POST only" "$out" 'Status: 405 Method Not Allowed'
done

echo "== get_pool =="
printf '%s\n' \
  '1|socks5|9.9.9.9|1080|pu|pw|VN-01' \
  '1|http|10.0.0.7|8080|||US-02' \
  '2|socks5|8.8.8.8|1080|||OTHER' > "$POOLS"
printf '%s\n' '1|aa:bb:cc:dd:ee:01|1|manual' > "$ASSIGN_FILE"

out="$(auth_run GET 'action=get_pool&idx=1')"
contains "get_pool succeeds" "$out" 'Status: 200 OK'
eq "slots come back in file order" "$(json_value "$out" '[.proxies[].slot] | join(",")')" '0,1'
eq "the first slot carries every field" \
  "$(json_value "$out" '.proxies[0] | [.type,.host,.port,.user,.label] | join("|")')" \
  'socks5|9.9.9.9|1080|pu|VN-01'
eq "port comes back as a number, not a string" \
  "$(json_value "$out" '.proxies[0].port | type')" 'number'
eq "an http slot keeps its type" "$(json_value "$out" '.proxies[1].type')" 'http'
eq "only this SSID's proxies are returned" "$(json_value "$out" '.proxies | length')" '2'
eq "current pins come along" \
  "$(json_value "$out" '.assignments[0] | [.mac,.slot,.source] | join("|")')" \
  'aa:bb:cc:dd:ee:01|1|manual'

out="$(auth_run GET 'action=get_pool&idx=7')"
eq "an SSID with no pool returns an empty list" "$(json_value "$out" '.proxies | length')" '0'
out="$(auth_run GET 'action=get_pool')"
contains "a missing idx is refused" "$out" 'Status: 400 Bad Request'
out="$(auth_run GET 'action=get_pool&idx=0')"
contains "idx zero is refused" "$out" 'Status: 400 Bad Request'
out="$(auth_run GET 'action=get_pool&idx=abc')"
contains "a non-numeric idx is refused" "$out" 'Status: 400 Bad Request'

echo "== save_pool =="
reset_calls
BODY='{"idx":1,"proxies":[{"type":"socks5","host":"1.1.1.1","port":1080,"user":"u","pass":"p","label":"A"},{"type":"http","host":"2.2.2.2","port":8080}]}'
out="$(auth_run POST 'action=save_pool' "$BODY")"
contains "save_pool succeeds" "$out" 'Status: 200 OK'
eq "it reports the exit code" "$(json_value "$out" '.rc')" '0'
contains "it hands the rows to pool.sh replace" "$(cat "$CALLS")" \
  'pool:replace:1:socks5|1.1.1.1|1080|u|p|A;http|2.2.2.2|8080|||;'

POOL_RC=3 out="$(POOL_RC=3 auth_run POST 'action=save_pool' "$BODY")"
eq "a failing replace is reported, not hidden" "$(json_value "$out" '.ok')" 'false'
eq "and its exit code comes back" "$(json_value "$out" '.rc')" '3'

reset_calls
out="$(auth_run POST 'action=save_pool' '{"idx":1,"proxies":[]}')"
contains "an empty list is allowed: it clears the pool" "$out" 'Status: 200 OK'
eq "and pool.sh is still called" "$(grep -c '^pool:replace:1:' "$CALLS")" '1'

for body in \
  '{"proxies":[]}' \
  '{"idx":1}' \
  '{"idx":0,"proxies":[]}' \
  '{"idx":1,"proxies":"nope"}' \
  '{"idx":1,"proxies":[{"host":"1.1.1.1","port":1080}]}' \
  '{"idx":1,"proxies":[{"type":"ftp","host":"1.1.1.1","port":1080}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"","port":1080}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"1.1.1.1","port":0}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"1.1.1.1","port":70000}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"1.1.1.1","port":"1080"}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"a b","port":1080}]}' \
  '{"idx":1,"proxies":[{"type":"socks5","host":"1.1.1.1","port":1080,"user":"a|b"}]}' \
; do
  reset_calls
  out="$(auth_run POST 'action=save_pool' "$body")"
  contains "save_pool refuses $body" "$out" 'Status: 400 Bad Request'
  eq "  and touches nothing" "$(wc -c < "$CALLS" | tr -d ' ')" '0'
done

echo "== assign_proxy =="
reset_calls
out="$(auth_run POST 'action=assign_proxy' \
  '{"idx":1,"assignments":[{"mac":"AA:BB:CC:DD:EE:01","slot":0},{"mac":"aa:bb:cc:dd:ee:02","slot":1}]}')"
contains "assign_proxy succeeds" "$out" 'Status: 200 OK'
eq "one assign.sh call per device" "$(grep -c '^assign:' "$CALLS")" '2'
contains "the MAC is normalised to lowercase" "$(cat "$CALLS")" 'assign:1:aa:bb:cc:dd:ee:01:0'
eq "each result is reported" "$(json_value "$out" '.results | length')" '2'
not_contains "no reload is triggered" "$(cat "$CALLS")" 'apply'

reset_calls
out="$(auth_run POST 'action=assign_proxy' '{"idx":1,"assignments":[{"mac":"aa:bb:cc:dd:ee:01","slot":"none"}]}')"
contains "slot none unpins" "$out" 'Status: 200 OK'
contains "and is passed through" "$(cat "$CALLS")" 'assign:1:aa:bb:cc:dd:ee:01:none'

for body in \
  '{"idx":1}' \
  '{"assignments":[]}' \
  '{"idx":1,"assignments":[]}' \
  '{"idx":1,"assignments":"nope"}' \
  '{"idx":1,"assignments":[{"slot":0}]}' \
  '{"idx":1,"assignments":[{"mac":"not-a-mac","slot":0}]}' \
  '{"idx":1,"assignments":[{"mac":"aa:bb:cc:dd:ee:01","slot":-1}]}' \
  '{"idx":1,"assignments":[{"mac":"aa:bb:cc:dd:ee:01","slot":"0"}]}' \
; do
  reset_calls
  out="$(auth_run POST 'action=assign_proxy' "$body")"
  contains "assign_proxy refuses $body" "$out" 'Status: 400 Bad Request'
  eq "  and touches nothing" "$(wc -c < "$CALLS" | tr -d ' ')" '0'
done

echo "== rebalance =="
reset_calls
out="$(auth_run POST 'action=rebalance' \
  '{"idx":1,"macs":["AA:BB:CC:DD:EE:01","aa:bb:cc:dd:ee:02"]}')"
contains "rebalance succeeds" "$out" 'Status: 200 OK'
contains "it passes the devices as a comma list" "$(cat "$CALLS")" \
  'rebalance:1 --macs aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02'

reset_calls
out="$(auth_run POST 'action=rebalance' \
  '{"idx":1,"macs":["aa:bb:cc:dd:ee:01"],"proxies":[{"type":"socks5","host":"3.3.3.3","port":1080}]}')"
contains "a pasted list replaces the pool in the same call" "$(cat "$CALLS")" '--pool-file'
eq "and it is one call, not two" "$(grep -c '^rebalance:' "$CALLS")" '1'
eq "no separate pool.sh call is made" "$(grep -c '^pool:' "$CALLS")" '0'

reset_calls
out="$(auth_run POST 'action=rebalance' '{"idx":1,"macs":["aa:bb:cc:dd:ee:01"],"seed":42}')"
contains "an explicit seed is honoured, so a preview can be committed" \
  "$(cat "$CALLS")" 'rebalance:1 --macs aa:bb:cc:dd:ee:01 --seed 42'

for body in \
  '{"idx":1}' \
  '{"macs":["aa:bb:cc:dd:ee:01"]}' \
  '{"idx":1,"macs":[]}' \
  '{"idx":1,"macs":"nope"}' \
  '{"idx":1,"macs":["not-a-mac"]}' \
  '{"idx":1,"macs":["aa:bb:cc:dd:ee:01"],"seed":"x"}' \
  '{"idx":1,"macs":["aa:bb:cc:dd:ee:01"],"proxies":[{"type":"socks5","host":"3.3.3.3","port":0}]}' \
; do
  reset_calls
  out="$(auth_run POST 'action=rebalance' "$body")"
  contains "rebalance refuses $body" "$out" 'Status: 400 Bad Request'
  eq "  and touches nothing" "$(wc -c < "$CALLS" | tr -d ' ')" '0'
done

echo "== secrets =="
printf '%s\n' '1|socks5|9.9.9.9|1080|pu|super-secret|VN-01' > "$POOLS"
out="$(auth_run GET 'action=get_pool&idx=1')"
contains "get_pool returns the password, as get_conf already does" "$out" 'super-secret'
out="$(auth_run GET 'action=status')"
not_contains "status still never leaks a pool password" "$out" 'super-secret'

echo
echo "POOL AGENT TOTAL: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
