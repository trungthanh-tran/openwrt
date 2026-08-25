#!/bin/sh
# Integration tests for agent/cgi/sbproxy using a fully isolated fake router.
# shellcheck disable=SC2089,SC2090  # JSON is intentionally passed through exported variables to stubs.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/agent/cgi/sbproxy"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP agent integration tests: jq is required"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
SB_ROOT="$TMP/router"
CONF="$SB_ROOT/config/wifi-socks.conf"
TOKEN_FILE="$TMP/token"
HEALTH_FILE="$TMP/health.json"
BACKUP_DIR="$TMP/backups"
BIN="$TMP/bin"
CALLS="$TMP/calls.log"
mkdir -p "$SB_ROOT/config" "$SB_ROOT/scripts" "$BACKUP_DIR" "$BIN"
printf '%s\n' 'agent-test-token' > "$TOKEN_FILE"
: > "$CALLS"
cp "$ROOT/scripts/lib.sh" "$SB_ROOT/scripts/lib.sh"

cat > "$SB_ROOT/scripts/apply.sh" <<'SH'
#!/bin/sh
mode=apply; [ "${DRYRUN:-0}" = "1" ] && mode=dryrun
printf 'apply:%s:%s\n' "$mode" "$*" >> "$CALLS"
if [ "$mode" = dryrun ]; then
  echo "dryrun output"
  exit "${APPLY_DRYRUN_RC:-0}"
fi
echo "apply output"
exit "${APPLY_REAL_RC:-0}"
SH

cat > "$SB_ROOT/scripts/backup.sh" <<'SH'
#!/bin/sh
printf 'backup:%s\n' "${1:-}" >> "$CALLS"
echo "backup output"
exit "${BACKUP_RC:-0}"
SH

cat > "$SB_ROOT/scripts/set-sock.sh" <<'SH'
#!/bin/sh
printf 'set-sock:%s:%s:%s:%s:%s:%s\n' "$#" "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$CALLS"
echo "set-sock output"
exit "${SET_SOCK_RC:-0}"
SH

cat > "$SB_ROOT/scripts/rotate-mac.sh" <<'SH'
#!/bin/sh
printf 'rotate-mac:%s:%s:%s\n' "$#" "$1" "${2:-<omitted>}" >> "$CALLS"
echo "rotate output"
exit "${ROTATE_RC:-0}"
SH

cat > "$SB_ROOT/scripts/rollback.sh" <<'SH'
#!/bin/sh
printf 'rollback:%s\n' "${1:-}" >> "$CALLS"
echo "rollback output"
exit "${ROLLBACK_RC:-0}"
SH

cat > "$SB_ROOT/scripts/uninstall.sh" <<'SH'
#!/bin/sh
printf 'uninstall\n' >> "$CALLS"
echo "uninstall output"
exit "${UNINSTALL_RC:-0}"
SH

cat > "$SB_ROOT/scripts/gateway.sh" <<'SH'
#!/bin/sh
if [ -n "${GATEWAY_OUTPUT:-}" ]; then
  printf '%s\n' "$GATEWAY_OUTPUT"
else
  printf '%s\n' '{"ok":true,"state":"ok"}'
fi
exit "${GATEWAY_RC:-0}"
SH

cat > "$SB_ROOT/scripts/clients.sh" <<'SH'
#!/bin/sh
if [ -n "${CLIENTS_OUTPUT:-}" ]; then
  printf '%s\n' "$CLIENTS_OUTPUT"
else
  printf '%s\n' '{"ok":true,"clients":[]}'
fi
exit "${CLIENTS_RC:-0}"
SH

for action in kick ban unban; do
  cat > "$SB_ROOT/scripts/$action.sh" <<'SH'
#!/bin/sh
action="$(basename "$0" .sh)"
printf '%s:%s:%s\n' "$action" "$1" "$2" >> "$CALLS"
echo "$action output"
case "$action" in
  kick) exit "${KICK_RC:-0}" ;;
  ban) exit "${BAN_RC:-0}" ;;
  unban) exit "${UNBAN_RC:-0}" ;;
esac
SH
done
chmod +x "$SB_ROOT"/scripts/*.sh

cat > "$BIN/uci" <<'SH'
#!/bin/sh
case "$*" in
  *wireless.w1.macaddr*) echo '50:c7:bf:11:22:33' ;;
  *wireless.w2.macaddr*) echo 'ac:9e:17:44:55:66' ;;
esac
exit 0
SH
cat > "$BIN/pgrep" <<'SH'
#!/bin/sh
[ "${SINGBOX_RUNNING:-0}" = "1" ]
SH
chmod +x "$BIN/uci" "$BIN/pgrep"

export SB_ROOT CONF TOKEN_FILE HEALTH_FILE BACKUP_DIR CALLS
export TMPDIR="$TMP"
export PATH="$BIN:$PATH"
export APPLY_DRYRUN_RC=0 APPLY_REAL_RC=0 BACKUP_RC=0 SET_SOCK_RC=0 ROTATE_RC=0
export ROLLBACK_RC=0 UNINSTALL_RC=0 GATEWAY_RC=0 CLIENTS_RC=0
export KICK_RC=0 BAN_RC=0 UNBAN_RC=0 SINGBOX_RUNNING=0
export GATEWAY_OUTPUT='{"ok":true,"state":"ok"}' CLIENTS_OUTPUT='{"ok":true,"clients":[]}'

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
contains() {
  if printf '%s' "$2" | grep -Fq "$3"; then ok "$1"; else no "$1 — missing [$3]"; fi
}
not_contains() {
  if printf '%s' "$2" | grep -Fq "$3"; then no "$1 — unexpected [$3]"; else ok "$1"; fi
}
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi
}

body_of() {
  printf '%s\n' "$1" | awk '{sub(/\r$/, "")} body {print} /^$/ {body=1}'
}
json_value() {
  body_of "$1" | jq -r "$2" 2>/dev/null | tr -d '\r'
}
reset_calls() { : > "$CALLS"; }
run_agent() {
  method="$1" query="$2" authorization="${3:-}" body="${4:-}" legacy="${5:-}" declared_length="${6:-}"
  printf '%s' "$body" | REQUEST_METHOD="$method" QUERY_STRING="$query" \
    HTTP_AUTHORIZATION="$authorization" HTTP_X_SB_TOKEN="$legacy" \
    CONTENT_LENGTH="$declared_length" sh "$AGENT"
}
auth_run() { run_agent "$1" "$2" 'Bearer agent-test-token' "${3:-}"; }

echo "== agent auth, CORS, and dispatch =="
out="$(run_agent OPTIONS 'action=status')"
contains "OPTIONS works without auth" "$out" 'Status: 204 No Content'
contains "CORS allows Authorization" "$out" 'Access-Control-Allow-Headers: Authorization, X-SB-Token, Content-Type'

mv "$TOKEN_FILE" "$TOKEN_FILE.off"
out="$(run_agent GET 'action=status')"
contains "missing server token is 500" "$out" 'Status: 500 Internal Server Error'
mv "$TOKEN_FILE.off" "$TOKEN_FILE"

out="$(run_agent GET 'action=status')"
contains "missing auth is 401" "$out" 'Status: 401 Unauthorized'
out="$(run_agent GET 'action=status' 'Bearer wrong')"
contains "wrong bearer is 401" "$out" 'Status: 401 Unauthorized'
out="$(run_agent GET 'action=status' '' '' 'agent-test-token')"
contains "legacy token remains supported" "$out" 'Status: 200 OK'
out="$(auth_run GET 'x=1&action=does_not_exist&y=2')"
contains "invalid action is 400" "$out" 'Status: 400 Bad Request'

echo "== agent status and read-only endpoints =="
cat > "$CONF" <<'EOF'
# secret fields must never be returned by status
Bravo|5g|2|bravo-password|proxy2.example|2080|bob|bob-secret|0|1|AC:9E:17
Alpha|2g|1|alpha-password|proxy1.example|1080|||1|0|50:C7:BF
EOF
printf '%s\n' '{"probes":{"1":{"state":"ok"}}}' > "$HEALTH_FILE"
out="$(auth_run GET 'action=status')"
contains "status succeeds" "$out" 'Status: 200 OK'
eq "status sorts SSIDs" "$(json_value "$out" '.ssids | map(.idx) | join(",")')" '1,2'
eq "status reports runtime MAC" "$(json_value "$out" '.ssids[0].macaddr')" '50:c7:bf:11:22:33'
eq "status reports auth presence only" "$(json_value "$out" '.ssids[1].hasAuth')" 'true'
not_contains "status hides Wi-Fi passwords" "$out" 'alpha-password'
not_contains "status hides SOCKS passwords" "$out" 'bob-secret'
eq "status includes health" "$(json_value "$out" '.health.probes["1"].state')" 'ok'
eq "status defaults running false" "$(json_value "$out" '.meta.singbox_running')" 'false'
SINGBOX_CONF="$TMP/sing-box.json"; export SINGBOX_CONF
touch "$SINGBOX_CONF"
export SINGBOX_RUNNING=1
out="$(auth_run GET 'action=status')"
eq "status detects applied config" "$(json_value "$out" '.meta.applied')" 'true'
eq "status detects running sing-box" "$(json_value "$out" '.meta.singbox_running')" 'true'
rm -f "$SINGBOX_CONF"
export SINGBOX_RUNNING=0

mv "$CONF" "$CONF.saved"
out="$(auth_run GET 'action=status')"
eq "status missing config returns empty SSID list" "$(json_value "$out" '.ssids | length')" '0'
mv "$CONF.saved" "$CONF"

cat > "$CONF.dirty" <<'EOF'
Valid|2g|1|valid-password|proxy.example|1080|alice|hidden-secret|1|1|
BadIdx|2g|not-a-number|password12|proxy.example|1080|||1|1|
TooHigh|2g|201|password12|proxy.example|1080|||1|1|
Extra|2g|2|password12|proxy.example|1080|||1|1||surplus
EOF
mv "$CONF" "$CONF.clean"
mv "$CONF.dirty" "$CONF"
out="$(auth_run GET 'action=status')"
eq "status skips corrupt config rows" "$(json_value "$out" '.ssids | map(.idx) | join(",")')" '1'
not_contains "status never leaks secrets from mixed config" "$out" 'hidden-secret'
mv "$CONF" "$CONF.dirty"
mv "$CONF.clean" "$CONF"
rm -f "$CONF.dirty"

for dirty_health in '[' '[]' 'null' '"text"' '{"probes":[]}' '{"probes":{"1":null}}'; do
  printf '%s\n' "$dirty_health" > "$HEALTH_FILE"
  out="$(auth_run GET 'action=status')"
  eq "status replaces dirty health payload" "$(json_value "$out" '.health | type + ":" + (length|tostring)')" 'object:0'
  out="$(auth_run GET 'action=health_now')"
  eq "health_now replaces dirty health payload" "$(json_value "$out" '.health | type + ":" + (length|tostring)')" 'object:0'
done

out="$(auth_run GET 'action=get_conf')"
contains "get_conf is text" "$out" 'Content-Type: text/plain'
contains "get_conf returns source" "$out" 'Alpha|2g|1|'

rm -f "$HEALTH_FILE"
out="$(auth_run GET 'action=health_now')"
eq "health_now defaults to empty object" "$(json_value "$out" '.health | length')" '0'

echo "== agent method and JSON validation =="
reset_calls
for action in save_conf dryrun_conf apply set_sock rotate_mac rollback uninstall backup kick ban unban; do
  out="$(auth_run GET "action=$action")"
  contains "$action rejects GET" "$out" 'Status: 405 Method Not Allowed'
done
for action in set_sock rotate_mac rollback backup kick ban unban; do
  out="$(auth_run POST "action=$action" 'not-json')"
  contains "$action rejects malformed JSON" "$out" 'Status: 400 Bad Request'
done
for action in set_sock rotate_mac rollback backup kick ban unban; do
  for body in '[]' 'null' 'true' '1' '"text"'; do
    out="$(auth_run POST "action=$action" "$body")"
    contains "$action rejects non-object JSON" "$out" 'Status: 400 Bad Request'
  done
done
for action in apply uninstall; do
  out="$(auth_run POST "action=$action" '[]')"
  contains "$action rejects dirty non-object body" "$out" 'Status: 400 Bad Request'
done

out="$(run_agent POST 'action=set_sock' 'Bearer agent-test-token' '{}' '' 'not-a-number')"
contains "invalid Content-Length is rejected" "$out" 'Status: 400 Bad Request'
out="$(run_agent POST 'action=set_sock' 'Bearer agent-test-token' '{}' '' '262145')"
contains "oversized declared body is rejected before dispatch" "$out" 'Status: 413 Payload Too Large'
out="$(MAX_BODY_BYTES=8 auth_run POST 'action=set_sock' '{"idx":1}')"
contains "oversized actual body is rejected" "$out" 'Status: 413 Payload Too Large'
out="$(printf '{"idx":1,"host":"bad\000host","port":1080}' | \
  REQUEST_METHOD=POST QUERY_STRING='action=set_sock' \
  HTTP_AUTHORIZATION='Bearer agent-test-token' HTTP_X_SB_TOKEN='' CONTENT_LENGTH='' sh "$AGENT")"
contains "raw NUL byte is rejected" "$out" 'Status: 400 Bad Request'
if find "$TMP" -maxdepth 1 -name 'sbproxy-cgi-body.*' | grep -q .; then
  no "request body temp files are cleaned"
else
  ok "request body temp files are cleaned"
fi
eq "dirty generic requests invoke no mutation scripts" "$(wc -l < "$CALLS" | tr -d ' ')" '0'

echo "== agent save and dry-run =="
out="$(auth_run POST 'action=save_conf' '')"
contains "save rejects empty body" "$out" 'Status: 400 Bad Request'
for candidate in 'plain text' 'A|2g|1|too|few' 'A|2g|1|password12|host|1080|||1|1|OUI|extra'; do
  out="$(auth_run POST 'action=save_conf' "$candidate")"
  contains "save rejects wrong column count" "$out" 'Status: 400 Bad Request'
done
for candidate in 'A|2g|0|password12|host|1080|||1|1|' 'A|2g|1|short|host|1080|||1|1|' 'A|2g|1|password12||1080|||1|1|' 'A|2g|1|password12|host|1080|||2|1|' 'A|2g|1|password12|host|1080|||1|1|GG:00:11'; do
  out="$(auth_run POST 'action=save_conf' "$candidate")"
  contains "save rejects semantically invalid config" "$out" 'Status: 400 Bad Request'
done
tab="$(printf '\t')"
for candidate in \
  'A|2g|1|password12|bad host|1080|||1|1|' \
  'A|2g|1|password12|https://proxy|1080|||1|1|' \
  "A|2g|1|password12|host|1080|bad${tab}user||1|1|"; do
  out="$(auth_run POST 'action=save_conf' "$candidate")"
  contains "save rejects dirty text fields" "$out" 'Status: 400 Bad Request'
done
long_host="$(awk 'BEGIN { for (i=0; i<254; i++) printf "h" }')"
long_credential="$(awk 'BEGIN { for (i=0; i<256; i++) printf "u" }')"
for candidate in \
  "A|2g|1|password12|$long_host|1080|||1|1|" \
  "A|2g|1|password12|host|1080|$long_credential||1|1|"; do
  out="$(auth_run POST 'action=save_conf' "$candidate")"
  contains "save rejects oversized config fields" "$out" 'Status: 400 Bad Request'
done
duplicate='A|2g|1|password12|host|1080|||1|1|
B|5g|1|password12|host2|2080|||1|1|'
out="$(auth_run POST 'action=save_conf' "$duplicate")"
contains "save rejects duplicate IDX" "$out" 'Status: 400 Bad Request'

old="$(cat "$CONF")"
export BACKUP_RC=1
valid='Saved|2g|3|password12|proxy3|1080|||1|1|'
out="$(auth_run POST 'action=save_conf' "$valid")"
contains "save aborts when backup fails" "$out" 'Status: 500 Internal Server Error'
eq "failed backup preserves config" "$(cat "$CONF")" "$old"
export BACKUP_RC=0
reset_calls
out="$(auth_run POST 'action=save_conf' "$valid")"
eq "save reports success" "$(json_value "$out" '.saved')" 'true'
eq "save writes exact candidate" "$(cat "$CONF")" "$valid"
contains "save creates pre-apply backup" "$(cat "$CALLS")" 'backup:pre-apply'

out="$(auth_run POST 'action=dryrun_conf' '')"
contains "dryrun rejects empty body" "$out" 'Status: 400 Bad Request'
reset_calls
export APPLY_DRYRUN_RC=0
out="$(auth_run POST 'action=dryrun_conf' "$valid")"
eq "dryrun success" "$(json_value "$out" '.ok')" 'true'
eq "dryrun phase" "$(json_value "$out" '.phase')" 'dryrun'
contains "dryrun uses no-backup" "$(cat "$CALLS")" 'apply:dryrun:--no-backup'
eq "dryrun does not replace desired config" "$(cat "$CONF")" "$valid"
export APPLY_DRYRUN_RC=7
out="$(auth_run POST 'action=dryrun_conf' "$valid")"
eq "dryrun failure is structured" "$(json_value "$out" '.ok,.rc,.phase' | paste -sd ':')" 'false:7:dryrun'
export APPLY_DRYRUN_RC=0

echo "== agent apply safety gate =="
reset_calls
export APPLY_DRYRUN_RC=9
out="$(auth_run POST 'action=apply' '{}')"
eq "apply stops on dryrun failure" "$(json_value "$out" '.phase')" 'dryrun'
eq "failed gate invokes apply script once" "$(wc -l < "$CALLS" | tr -d ' ')" '1'
not_contains "failed gate never invokes real apply" "$(cat "$CALLS")" 'apply:apply:'

reset_calls
export APPLY_DRYRUN_RC=0 APPLY_REAL_RC=0
out="$(auth_run POST 'action=apply' '{}')"
eq "apply succeeds after gate" "$(json_value "$out" '.ok,.phase' | paste -sd ':')" 'true:apply'
eq "successful apply invokes dryrun and real apply" "$(wc -l < "$CALLS" | tr -d ' ')" '2'
export APPLY_REAL_RC=5
out="$(auth_run POST 'action=apply' '{}')"
eq "real apply failure is structured" "$(json_value "$out" '.ok,.rc,.phase' | paste -sd ':')" 'false:5:apply'
export APPLY_REAL_RC=0

echo "== agent SOCKS and MAC mutation validation =="
reset_calls
for body in '{}' \
  '{"idx":0,"host":"proxy","port":1}' '{"idx":201,"host":"proxy","port":1}' \
  '{"idx":1.5,"host":"proxy","port":1}' '{"idx":"1","host":"proxy","port":1}' \
  '{"idx":true,"host":"proxy","port":1}' '{"idx":[],"host":"proxy","port":1}' \
  '{"idx":1,"host":"bad host","port":1}' '{"idx":1,"host":{},"port":1}' \
  '{"idx":1,"host":"proxy","port":0}' '{"idx":1,"host":"proxy","port":65536}' \
  '{"idx":1,"host":"proxy","port":"1080"}' '{"idx":1,"host":"proxy","port":1.5}' \
  '{"idx":1,"host":"proxy","port":1080,"user":"bad|user"}' \
  '{"idx":1,"host":"proxy","port":1080,"user":[]}' \
  '{"idx":1,"host":"proxy","port":1080,"pass":null}' \
  '{"idx":1,"host":"proxy","port":1080,"user":"bad\tuser"}'; do
  out="$(auth_run POST 'action=set_sock' "$body")"
  contains "set_sock rejects invalid fields" "$out" 'Status: 400 Bad Request'
done
long_host="$(awk 'BEGIN { for (i=0; i<254; i++) printf "h" }')"
long_credential="$(awk 'BEGIN { for (i=0; i<256; i++) printf "u" }')"
for body in \
  "$(jq -cn --arg host "$long_host" '{idx:1,host:$host,port:1080}')" \
  "$(jq -cn --arg user "$long_credential" '{idx:1,host:"proxy",port:1080,user:$user}')"; do
  out="$(auth_run POST 'action=set_sock' "$body")"
  contains "set_sock rejects oversized strings" "$out" 'Status: 400 Bad Request'
done
eq "invalid SOCKS payloads invoke no script" "$(wc -l < "$CALLS" | tr -d ' ')" '0'
out="$(auth_run POST 'action=set_sock' '{"idx":1,"host":"proxy.example","port":1080,"user":"alice smith","pass":"safe pass"}')"
eq "set_sock success" "$(json_value "$out" '.ok')" 'true'
contains "set_sock preserves quoted arguments" "$(cat "$CALLS")" 'set-sock:5:1:proxy.example:1080:alice smith:safe pass'
export SET_SOCK_RC=4
out="$(auth_run POST 'action=set_sock' '{"idx":1,"host":"proxy","port":1080}')"
eq "set_sock script failure propagates" "$(json_value "$out" '.ok,.rc' | paste -sd ':')" 'false:4'
export SET_SOCK_RC=0

reset_calls
for body in '{}' '{"idx":"x"}' '{"idx":true}' '{"idx":[]}' '{"idx":1.5}' '{"idx":0}' '{"idx":201}' '{"idx":1,"oui":[]}' '{"idx":1,"oui":null}' '{"idx":1,"oui":"AA:BB"}' '{"idx":1,"oui":"GG:00:11"}'; do
  out="$(auth_run POST 'action=rotate_mac' "$body")"
  contains "rotate_mac rejects invalid fields" "$out" 'Status: 400 Bad Request'
done
eq "invalid rotate payloads invoke no script" "$(wc -l < "$CALLS" | tr -d ' ')" '0'
out="$(auth_run POST 'action=rotate_mac' '{"idx":1}')"
eq "rotate without OUI succeeds" "$(json_value "$out" '.ok')" 'true'
contains "omitted OUI passes one argument" "$(cat "$CALLS")" 'rotate-mac:1:1:<omitted>'
reset_calls
out="$(auth_run POST 'action=rotate_mac' '{"idx":1,"oui":""}')"
contains "explicit empty OUI passes two arguments" "$(cat "$CALLS")" 'rotate-mac:2:1:'
eq "rotate returns runtime MAC" "$(json_value "$out" '.mac')" '50:c7:bf:11:22:33'

echo "== agent snapshots and downloads =="
reset_calls
for body in '{"label":""}' '{"label":null}' '{"label":[]}' '{"label":1}' '{"label":"../bad"}' '{"label":"bad/name"}' '{"label":"bad name"}'; do
  out="$(auth_run POST 'action=backup' "$body")"
  contains "backup rejects unsafe label" "$out" 'Status: 400 Bad Request'
done
long_label="$(awk 'BEGIN { for (i=0; i<129; i++) printf "a" }')"
out="$(auth_run POST 'action=backup' "$(jq -cn --arg label "$long_label" '{label:$label}')")"
contains "backup rejects oversized label" "$out" 'Status: 400 Bad Request'
eq "invalid backup payloads invoke no script" "$(wc -l < "$CALLS" | tr -d ' ')" '0'
out="$(auth_run POST 'action=backup' '{}')"
eq "backup defaults label" "$(json_value "$out" '.ok')" 'true'
contains "backup default is ui" "$(cat "$CALLS")" 'backup:ui'
out="$(auth_run POST 'action=backup' '{"label":"nightly_1"}')"
eq "backup accepts safe label" "$(json_value "$out" '.ok')" 'true'

reset_calls
for body in '{"name":null}' '{"name":[]}' '{"name":1}' '{"name":"../bad"}' '{"name":"bad/name"}' '{"name":"bad name"}'; do
  out="$(auth_run POST 'action=rollback' "$body")"
  contains "rollback rejects unsafe name" "$out" 'Status: 400 Bad Request'
done
eq "invalid rollback payloads invoke no script" "$(wc -l < "$CALLS" | tr -d ' ')" '0'
out="$(auth_run POST 'action=rollback' '{}')"
eq "rollback allows latest" "$(json_value "$out" '.ok')" 'true'
contains "rollback latest passes empty name" "$(cat "$CALLS")" 'rollback:'
out="$(auth_run POST 'action=rollback' '{"name":"20260819-good"}')"
eq "rollback accepts safe name" "$(json_value "$out" '.ok')" 'true'

mkdir -p "$BACKUP_DIR/20260818-old" "$BACKUP_DIR/20260819-new" "$BACKUP_DIR/latest"
out="$(auth_run GET 'action=backups')"
eq "backups excludes latest" "$(json_value "$out" '.backups | index("latest")')" 'null'
eq "backups returns snapshots" "$(json_value "$out" '.backups | length')" '2'

out="$(auth_run GET 'action=download_backup&name=../bad')"
contains "download rejects traversal" "$out" 'Status: 400 Bad Request'
out="$(auth_run GET 'action=download_backup&name=missing')"
contains "download reports missing snapshot" "$out" 'Status: 404 Not Found'
printf 'fallback-data' > "$BACKUP_DIR/20260818-old/etc-config.tar.gz"
out="$(auth_run GET 'action=download_backup&name=20260818-old')"
contains "download fallback archive succeeds" "$out" 'Content-Type: application/gzip'
contains "download fallback archive body" "$out" 'fallback-data'
printf 'preferred-data' > "$BACKUP_DIR/20260818-old/sysupgrade-backup.tar.gz"
out="$(auth_run GET 'action=download_backup&name=20260818-old')"
contains "download prefers sysupgrade archive" "$out" 'preferred-data'
not_contains "download does not use fallback when sysupgrade exists" "$out" 'fallback-data'

echo "== agent gateway, clients, uninstall, and client actions =="
export GATEWAY_OUTPUT='not-json'
out="$(auth_run GET 'action=gateway')"
contains "gateway rejects invalid JSON" "$out" 'Status: 500 Internal Server Error'
for payload in 'null' '[]' 'true' '1' '"text"'; do
  export GATEWAY_OUTPUT="$payload"
  out="$(auth_run GET 'action=gateway')"
  contains "gateway rejects valid JSON with wrong schema" "$out" 'Status: 500 Internal Server Error'
done
export GATEWAY_OUTPUT='{"ok":true,"state":"degraded"}'
out="$(auth_run GET 'action=gateway')"
eq "gateway returns script payload" "$(json_value "$out" '.state')" 'degraded'
export GATEWAY_RC=1
out="$(auth_run GET 'action=gateway')"
contains "gateway script failure is 500" "$out" 'Status: 500 Internal Server Error'
export GATEWAY_RC=0

export CLIENTS_OUTPUT='not-json'
out="$(auth_run GET 'action=clients')"
contains "clients rejects invalid JSON" "$out" 'Status: 500 Internal Server Error'
for payload in 'null' '[]' '{}' '{"clients":null}' '{"clients":{}}' '{"clients":[null]}' '{"clients":["bad"]}'; do
  export CLIENTS_OUTPUT="$payload"
  out="$(auth_run GET 'action=clients')"
  contains "clients rejects valid JSON with wrong schema" "$out" 'Status: 500 Internal Server Error'
done
export CLIENTS_OUTPUT='{"ok":true,"clients":[]}' CLIENTS_RC=1
out="$(auth_run GET 'action=clients')"
contains "clients script failure is 500" "$out" 'Status: 500 Internal Server Error'
export CLIENTS_RC=0
export CLIENTS_OUTPUT='{"ok":true,"clients":[{"mac":"aa"}]}'
out="$(auth_run GET 'action=clients')"
eq "clients returns script payload" "$(json_value "$out" '.clients | length')" '1'

for action in kick ban unban; do
  reset_calls
  for body in '{}' '{"idx":"1","mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":true,"mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":[],"mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":1.5,"mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":0,"mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":201,"mac":"aa:bb:cc:dd:ee:ff"}' '{"idx":1,"mac":null}' '{"idx":1,"mac":[]}' '{"idx":1,"mac":"bad"}'; do
    out="$(auth_run POST "action=$action" "$body")"
    contains "$action rejects invalid target" "$out" 'Status: 400 Bad Request'
  done
  eq "$action invalid payloads invoke no script" "$(wc -l < "$CALLS" | tr -d ' ')" '0'
  out="$(auth_run POST "action=$action" '{"idx":1,"mac":"AA:BB:CC:DD:EE:FF"}')"
  eq "$action succeeds" "$(json_value "$out" '.ok')" 'true'
  contains "$action invokes matching script" "$(cat "$CALLS")" "$action:1:AA:BB:CC:DD:EE:FF"
done

reset_calls
out="$(auth_run POST 'action=uninstall' '{}')"
eq "uninstall succeeds" "$(json_value "$out" '.ok')" 'true'
contains "uninstall invokes script" "$(cat "$CALLS")" 'uninstall'

echo "== agent self-update =="
out="$(auth_run GET 'action=status')"
eq "status reports unknown version without VERSION file" "$(json_value "$out" '.meta.version')" 'unknown'

# Dedicated fake root so an applied update never clobbers the shared stubs.
SB2="$TMP/router2"
AGENT_ENV="$TMP/sbproxy.env"
mkdir -p "$SB2/config" "$SB2/scripts" "$TMP/deploy"
printf '%s\n' '0.4.0' > "$SB2/VERSION"
printf '%s\n' 'Alpha|2g|1|alpha-password|proxy1.example|1080|||1|0|50:C7:BF' > "$SB2/config/wifi-socks.conf"
printf '%s\n' 'ROUTER_SETTING=1' > "$SB2/config/settings.sh"
cp "$ROOT/scripts/self-update.sh" "$SB2/scripts/self-update.sh"
cat > "$SB2/scripts/backup.sh" <<'SH'
#!/bin/sh
printf 'backup2:%s\n' "${1:-}" >> "$CALLS"
exit "${BACKUP_RC:-0}"
SH
chmod +x "$SB2"/scripts/*.sh

make_pkg() { # version dest-file
  pkgsrc="$TMP/pkgsrc"
  rm -rf "$pkgsrc"
  mkdir -p "$pkgsrc/scripts" "$pkgsrc/agent/cgi" "$pkgsrc/agent/init.d" "$pkgsrc/console/web" "$pkgsrc/config"
  printf '%s\n' "$1" > "$pkgsrc/VERSION"
  printf '#!/bin/sh\necho new-apply\n' > "$pkgsrc/scripts/apply.sh"
  printf '#!/bin/sh\n' > "$pkgsrc/scripts/lib.sh"
  printf '#!/bin/sh\necho new-cgi\n' > "$pkgsrc/agent/cgi/sbproxy"
  printf '#!/bin/sh\n' > "$pkgsrc/agent/sbproxy-healthd"
  printf '#!/bin/sh\n' > "$pkgsrc/agent/init.d/sbproxy-healthd"
  printf '<html>new-ui</html>\n' > "$pkgsrc/console/web/control-panel.html"
  printf 'PACKAGED|conf|must|not|survive\n' > "$pkgsrc/config/wifi-socks.conf"
  tar czf "$2" -C "$pkgsrc" VERSION scripts agent console config
}

run_agent_pkg() { # query package-file
  REQUEST_METHOD=POST QUERY_STRING="$1" HTTP_AUTHORIZATION='Bearer agent-test-token' \
    SB_ROOT="$SB2" CONF="$SB2/config/wifi-socks.conf" \
    CGI_DEST="$TMP/deploy/sbproxy" UI_DEST="$TMP/deploy/index.html" \
    HEALTHD_DEST="$TMP/deploy/sbproxy-healthd" HEALTHD_INIT_DEST="$TMP/deploy/init-healthd" \
    ENV_FILE="$AGENT_ENV" SB_NO_SERVICE=1 sh "$AGENT" < "$2"
}

out="$(run_agent GET 'action=update' 'Bearer agent-test-token')"
contains "update requires POST" "$out" 'Status: 405 Method Not Allowed'
: > "$TMP/empty.bin"
out="$(run_agent_pkg 'action=update' "$TMP/empty.bin")"
contains "update rejects empty body" "$out" 'Status: 400 Bad Request'
printf 'not a package' > "$TMP/garbage.bin"
out="$(run_agent_pkg 'action=update' "$TMP/garbage.bin")"
eq "update rejects non-package body" "$(json_value "$out" '.ok')" 'false'
contains "update names the package problem" "$out" 'is not a .tar.gz or .zip file'

reset_calls
make_pkg 0.5.0 "$TMP/pkg-0.5.0.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.5.0.tar.gz")"
eq "update applies newer package" "$(json_value "$out" '.ok')" 'true'
eq "update reports source version" "$(json_value "$out" '.from')" '0.4.0'
eq "update reports target version" "$(json_value "$out" '.to')" '0.5.0'
eq "update rewrites VERSION" "$(tr -d ' \r\n' < "$SB2/VERSION")" '0.5.0'
contains "update backs up before overwrite" "$(cat "$CALLS")" 'backup2:pre-update'
contains "update replaces code" "$(cat "$SB2/scripts/apply.sh")" 'new-apply'
contains "update preserves live wifi config" "$(cat "$SB2/config/wifi-socks.conf")" 'Alpha|2g|1|'
not_contains "update never installs packaged config" "$(cat "$SB2/config/wifi-socks.conf")" 'PACKAGED'
contains "update preserves live settings" "$(cat "$SB2/config/settings.sh")" 'ROUTER_SETTING=1'
contains "update deploys refreshed CGI" "$(cat "$TMP/deploy/sbproxy")" 'new-cgi'
contains "update deploys refreshed web UI" "$(cat "$TMP/deploy/index.html")" 'new-ui'

make_pkg 0.3.0 "$TMP/pkg-0.3.0.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.3.0.tar.gz")"
eq "update refuses downgrade" "$(json_value "$out" '.ok')" 'false'
contains "downgrade refusal names versions" "$out" 'is older than'
eq "refused downgrade leaves VERSION alone" "$(tr -d ' \r\n' < "$SB2/VERSION")" '0.5.0'
out="$(run_agent_pkg 'action=update&force=1' "$TMP/pkg-0.3.0.tar.gz")"
eq "forced downgrade succeeds" "$(json_value "$out" '.ok')" 'true'
eq "forced downgrade rewrites VERSION" "$(json_value "$out" '.to')" '0.3.0'

out="$(REQUEST_METHOD=GET QUERY_STRING='action=status' HTTP_AUTHORIZATION='Bearer agent-test-token' \
  SB_ROOT="$SB2" CONF="$SB2/config/wifi-socks.conf" sh "$AGENT")"
eq "status reports installed version" "$(json_value "$out" '.meta.version')" '0.3.0'

# The agent sources /etc/sbproxy/env before every script, so a value left there
# outlives the scripts. An update is the only chance to retire one.
# The legacy pin is judged by what the router actually does, because it cannot
# be told apart from a deliberate choice.
fake_gateway() { # logical-interface
  cat > "$SB2/scripts/gateway.sh" <<SH
#!/bin/sh
echo '{"ok":true,"interface":"$1"}'
SH
  chmod +x "$SB2/scripts/gateway.sh"
}

fake_gateway wan
printf '%s\n' 'SB_ROOT=/root/sbproxy' 'GATEWAY_EXPECTED_INTERFACE=wwan' 'INTERVAL=15' > "$AGENT_ENV"
make_pkg 0.6.0 "$TMP/pkg-0.6.0.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.6.0.tar.gz")"
eq "update succeeds with an env file present" "$(json_value "$out" '.ok')" 'true'
not_contains "a wrong pin stops taking effect" "$(grep -v '^#' "$AGENT_ENV")" 'GATEWAY_EXPECTED_INTERFACE=wwan'
contains "the value is kept, commented out" "$(cat "$AGENT_ENV")" '#GATEWAY_EXPECTED_INTERFACE=wwan'
contains "the reason is written next to it" "$(cat "$AGENT_ENV")" 'Uncomment to enforce it again'
contains "unrelated env settings survive" "$(cat "$AGENT_ENV")" 'INTERVAL=15'
contains "the install path survives" "$(cat "$AGENT_ENV")" 'SB_ROOT=/root/sbproxy'

fake_gateway wwan
printf '%s\n' 'GATEWAY_EXPECTED_INTERFACE=wwan' 'INTERVAL=15' > "$AGENT_ENV"
make_pkg 0.6.1 "$TMP/pkg-0.6.1.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.6.1.tar.gz")"
eq "update succeeds on a wwan router" "$(json_value "$out" '.ok')" 'true'
contains "a pin matching the real uplink is kept active" "$(grep -v '^#' "$AGENT_ENV")" 'GATEWAY_EXPECTED_INTERFACE=wwan'
not_contains "the kept pin is not commented out" "$(cat "$AGENT_ENV")" '#GATEWAY_EXPECTED_INTERFACE'

fake_gateway wan

printf '%s\n' 'GATEWAY_EXPECTED_INTERFACE=wan' > "$AGENT_ENV"
make_pkg 0.7.0 "$TMP/pkg-0.7.0.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.7.0.tar.gz")"
eq "update succeeds again" "$(json_value "$out" '.ok')" 'true'
contains "an operator's own pin is never touched" "$(cat "$AGENT_ENV")" 'GATEWAY_EXPECTED_INTERFACE=wan'

rm -f "$AGENT_ENV"
make_pkg 0.8.0 "$TMP/pkg-0.8.0.tar.gz"
out="$(run_agent_pkg 'action=update' "$TMP/pkg-0.8.0.tar.gz")"
eq "update succeeds without any env file" "$(json_value "$out" '.ok')" 'true'

echo ""
printf 'AGENT TOTAL: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
