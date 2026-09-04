#!/bin/sh
# tests/test_clients.sh — scripts/clients.sh against a stubbed router.
# `ubus`, `iw` and `uci` are stubs driven by environment variables, so the three
# kinds of entry (associated now, blocked, seen before) can be produced on a
# workstation and the JSON checked field by field.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "== clients =="; printf '  skip (jq is not installed)\n'
  echo "CLIENTS TOTAL: pass=0 fail=0 skip=1"; exit 0
fi

SB="$TMP/sbproxy"; mkdir -p "$SB/scripts" "$SB/config"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/clients.sh" "$SB/scripts/"
cp "$ROOT/config/settings.sh" "$SB/config/settings.sh"
printf 'alpha|2g|1|password12|p.example|1080|u|pw|1|1||socks5\n' > "$SB/config/wifi-socks.conf"

# Two SSIDs exist in wireless; only w1 has a station dump unless STATIONS says so.
cat > "$BIN/ubus" <<'SH'
#!/bin/sh
echo '{"radio0":{"interfaces":[{"section":"w1","ifname":"phy0-ap0"}]}}'
SH
cat > "$BIN/uci" <<'SH'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$2" in
  wireless.w1.ssid) echo alpha ;;
  *) exit 1 ;;
esac
SH
# STATIONS: space-separated MACs currently associated.
cat > "$BIN/iw" <<'SH'
#!/bin/sh
for m in ${STATIONS:-}; do
  printf 'Station %s (on phy0-ap0)\n\trx bytes:\t1000\n\ttx bytes:\t2000\n\tsignal:\t-55 dBm\n\tconnected time:\t120 seconds\n' "$m"
done
SH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

LEASES="$TMP/dhcp.leases"
printf '9999999999 aa:bb:cc:00:00:01 192.168.11.10 phone *\n' > "$LEASES"
BANS="$TMP/bans"; : > "$BANS"
SEEN="$TMP/seen"; STORE="$TMP/seen.store"
ASSIGN="$TMP/assign"; : > "$ASSIGN"
POOLS="$SB/config/proxy-pools.conf"; : > "$POOLS"

# lib.sh sources settings.sh, which assigns the state-file paths outright, so
# an environment variable would be overwritten. Point the fake router at the
# fixture files the way an operator would: through its own settings.sh.
write_settings() { # [SEEN_MAX]
  cat "$ROOT/config/settings.sh" > "$SB/config/settings.sh"
  cat >> "$SB/config/settings.sh" <<EOF
BANS_FILE="$BANS"
ASSIGN_FILE="$ASSIGN"
SEEN_FILE="$SEEN"
SEEN_STORE="$STORE"
SEEN_MAX=${1:-400}
EOF
}
write_settings

run() { # run <STATIONS...>
  ( cd "$SB" && STATIONS="$1" LEASES="$LEASES" sh scripts/clients.sh 2>/dev/null )
}
field() { printf '%s' "$1" | jq -r "$2"; }
of_mac() { printf '%s' "$1" | jq -r --arg m "$2" ".clients[] | select(.mac == \$m) | $3"; }

echo "== clients: an associated station =="
out="$(run 'aa:bb:cc:00:00:01')"
eq "answer is ok"                 "$(field "$out" .ok)" "true"
eq "one client is listed"         "$(field "$out" '.clients | length')" "1"
eq "the station is online"        "$(of_mac "$out" aa:bb:cc:00:00:01 .online)" "true"
eq "status says online"           "$(of_mac "$out" aa:bb:cc:00:00:01 .status)" "online"
eq "the lease supplies the IP"    "$(of_mac "$out" aa:bb:cc:00:00:01 .ip)" "192.168.11.10"
eq "and the hostname"             "$(of_mac "$out" aa:bb:cc:00:00:01 .host)" "phone"
eq "connected time is carried"    "$(of_mac "$out" aa:bb:cc:00:00:01 .connected_s)" "120"
eq "rx bytes are carried"         "$(of_mac "$out" aa:bb:cc:00:00:01 .rx_bytes)" "1000"
eq "signal is carried"            "$(of_mac "$out" aa:bb:cc:00:00:01 .signal_dbm)" "-55"
eq "the SSID name is resolved"    "$(of_mac "$out" aa:bb:cc:00:00:01 .ssid)" "alpha"
eq "an online device has no inactive time" "$(of_mac "$out" aa:bb:cc:00:00:01 .inactive_s)" "null"
eq "first_seen is recorded"       "$(of_mac "$out" aa:bb:cc:00:00:01 '.first_seen | type')" "number"

echo "== clients: the seen store remembers it =="
eq "the tmpfs store has the device" "$(grep -c '^1|aa:bb:cc:00:00:01|' "$SEEN")" "1"
eq "a first sighting is flushed to flash" "$(grep -c '^1|aa:bb:cc:00:00:01|' "$STORE")" "1"
store_before="$(cat "$STORE")"
out="$(run 'aa:bb:cc:00:00:01')"
eq "a repeat sighting does not rewrite flash" "$(cat "$STORE")" "$store_before"

echo "== clients: a device that left is history, not a disappearance =="
out="$(run '')"
eq "it is still listed"           "$(field "$out" '.clients | length')" "1"
eq "but no longer online"         "$(of_mac "$out" aa:bb:cc:00:00:01 .online)" "false"
eq "status says offline"          "$(of_mac "$out" aa:bb:cc:00:00:01 .status)" "offline"
eq "it is not blocked"            "$(of_mac "$out" aa:bb:cc:00:00:01 .banned)" "false"
eq "inactive time is reported"    "$(of_mac "$out" aa:bb:cc:00:00:01 '.inactive_s | type')" "number"
eq "the SSID is still named"      "$(of_mac "$out" aa:bb:cc:00:00:01 .ssid)" "alpha"
eq "the last lease still supplies the IP" "$(of_mac "$out" aa:bb:cc:00:00:01 .ip)" "192.168.11.10"

echo "== clients: history survives a reboot through the flash copy =="
rm -f "$SEEN"          # tmpfs is wiped on reboot; the flash copy is not
out="$(run '')"
eq "the device is restored from flash" "$(of_mac "$out" aa:bb:cc:00:00:01 .status)" "offline"

echo "== clients: a blocked device reads as blocked, once =="
printf '1|aa:bb:cc:00:00:01\n' > "$BANS"
out="$(run '')"
eq "still exactly one entry"      "$(field "$out" '.clients | length')" "1"
eq "status says blocked"          "$(of_mac "$out" aa:bb:cc:00:00:01 .status)" "blocked"
eq "banned is true"               "$(of_mac "$out" aa:bb:cc:00:00:01 .banned)" "true"
out="$(run 'aa:bb:cc:00:00:01')"
eq "a blocked device that is still associated stays online" "$(of_mac "$out" aa:bb:cc:00:00:01 .status)" "online"
eq "and is still flagged banned"  "$(of_mac "$out" aa:bb:cc:00:00:01 .banned)" "true"
: > "$BANS"

echo "== clients: several devices, sorted online first =="
printf '9999999999 aa:bb:cc:00:00:02 192.168.11.11 laptop *\n' >> "$LEASES"
out="$(run 'aa:bb:cc:00:00:02')"
eq "both devices are listed"      "$(field "$out" '.clients | length')" "2"
eq "the associated one comes first" "$(field "$out" '.clients[0].mac')" "aa:bb:cc:00:00:02"
eq "the departed one follows"     "$(field "$out" '.clients[1].status')" "offline"

echo "== clients: pool pins are reported without credentials =="
printf '1|socks5|proxy.example|1080|puser|ppass|label-a\n' > "$POOLS"
printf '1|aa:bb:cc:00:00:02|0|manual\n' > "$ASSIGN"
out="$(run 'aa:bb:cc:00:00:02')"
eq "the pool size is reported"    "$(of_mac "$out" aa:bb:cc:00:00:02 .pool_size)" "1"
eq "the pinned slot is reported"  "$(of_mac "$out" aa:bb:cc:00:00:02 .slot)" "0"
eq "the proxy host is reported"   "$(of_mac "$out" aa:bb:cc:00:00:02 .proxy_host)" "proxy.example:1080"
eq "the pin state is pinned"      "$(of_mac "$out" aa:bb:cc:00:00:02 .proxy_state)" "pinned"
eq "no proxy password travels"    "$(printf '%s' "$out" | grep -c ppass)" "0"
eq "no proxy username travels"    "$(printf '%s' "$out" | grep -c puser)" "0"

echo "== clients: the store is capped =="
: > "$SEEN"; : > "$STORE"
i=1; macs=""
while [ "$i" -le 6 ]; do macs="$macs aa:bb:cc:00:01:0$i"; i=$((i + 1)); done
write_settings 3
run "$macs" >/dev/null
eq "the seen store honours SEEN_MAX" "$(grep -c . "$SEEN")" "3"

echo
echo "CLIENTS TOTAL: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
