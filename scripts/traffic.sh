#!/bin/sh
# traffic.sh — which hosts are eating the proxy bandwidth right now.
#
# sing-box knows the host behind every open connection and how many bytes have
# moved on it, but only through its stats API. clients.sh already reports rx/tx
# per device; this answers the other half of the question — WHAT that device is
# pulling — which is what you need before deciding to send something direct.
#
# Requires TRAFFIC_STATS=1 in config/settings.sh and an apply afterwards.
#
# Usage:
#   scripts/traffic.sh                 # top hosts by bytes, largest first
#   scripts/traffic.sh --top 5         # only the first 5
#   scripts/traffic.sh --idx 3         # only one SSID's connections (0 = LAN)
#   scripts/traffic.sh --json          # machine-readable, for the console
#   scripts/traffic.sh --suggest       # print routing-rules.conf lines
#
# The byte counts are per OPEN connection: sing-box forgets a connection when
# it closes, so this is a live picture, not a running total since boot.
set -eu

SB_ROOT="${SB_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
. "$SB_ROOT/scripts/lib.sh"

TOP=20
FORMAT=table
WANT_IDX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --top)     TOP="${2:-20}"; shift 2 ;;
    --idx)     WANT_IDX="${2:-}"; shift 2 ;;
    --json)    FORMAT=json; shift ;;
    --suggest) FORMAT=suggest; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$TOP" in ''|*[!0-9]*) die "--top takes a number" ;; esac
case "$WANT_IDX" in ''|*[0-9]) : ;; *) die "--idx takes a number" ;; esac

command -v jq   >/dev/null 2>&1 || die "jq is missing"
command -v curl >/dev/null 2>&1 || die "curl is missing"

traffic_stats_enabled \
  || die "TRAFFIC_STATS=0. Set it to 1 in config/settings.sh and run scripts/apply.sh."
secret="$(clash_api_secret 2>/dev/null || true)"
[ -n "$secret" ] || die "no stats API secret at ${CLASH_API_SECRET_FILE:-/etc/sbproxy/clash-secret}"

listen="${CLASH_API_LISTEN:-127.0.0.1:9090}"
raw="$(curl -sS -m 5 -H "Authorization: Bearer $secret" "http://$listen/connections" 2>/dev/null || true)"
printf '%s' "$raw" | jq -e 'has("connections")' >/dev/null 2>&1 \
  || die "no answer from sing-box at $listen. Is it running, and was apply.sh run after enabling TRAFFIC_STATS?"

# One row per host: bytes both ways, how many connections, and which SSID
# carried them. A connection with no sniffed host is reported by its
# destination IP, which is exactly the case an ip_cidr rule is for.
#
# The inbound tag is in-w<idx> or in-w<idx>-s<slot>, so the idx is the digits
# after the first "w" and before any "-s".
summary="$(printf '%s' "$raw" | jq -c --arg want "$WANT_IDX" '
  [ .connections[]
    | { host: (if (.metadata.host // "") == ""
               then (.metadata.destinationIP // "?") else .metadata.host end),
        idx: ([(.metadata.inboundTag // "") | scan("^in-w([0-9]+)")]
              | if length > 0 then .[0][0] else "?" end),
        bytes: ((.upload // 0) + (.download // 0)) }
    | select($want == "" or .idx == $want) ]
  | group_by(.host)
  | map({ host: .[0].host,
          idx: ([.[].idx] | unique | join(",")),
          conns: length,
          bytes: (map(.bytes) | add) })
  | sort_by(-.bytes)')"

human() { # bytes -> 1.2M
  awk -v b="$1" 'BEGIN {
    split("B K M G T", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
  }'
}

case "$FORMAT" in
  json)
    printf '%s' "$summary" | jq --argjson top "$TOP" '.[:$top]'
    ;;
  suggest)
    # A host pulling a lot through the proxy is usually a CDN or an update
    # server: nothing that needs the proxy's identity, and everything that
    # wastes its bandwidth. These are candidates to review, not a config to
    # paste blindly — check each one before sending it direct.
    echo "# Candidates for config/routing-rules.conf, biggest first."
    echo "# Review each: sending a host direct exposes the router's real IP to it."
    printf '%s' "$summary" | jq -r --argjson top "$TOP" '
      .[:$top][]
      | if (.host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))
        then "direct|ip_cidr|\(.host)/32"
        else "direct|domain_suffix|\(.host)" end'
    ;;
  *)
    n="$(printf '%s' "$summary" | jq 'length')"
    if [ "$n" = 0 ]; then
      echo "No open proxied connections right now."
      exit 0
    fi
    printf '%-45s %6s %6s %8s\n' "HOST" "IDX" "CONNS" "BYTES"
    printf '%s' "$summary" | jq -r --argjson top "$TOP" \
      '.[:$top][] | [.host, .idx, .conns, .bytes] | @tsv' \
    | while IFS="$(printf '\t')" read -r host idx conns bytes; do
        printf '%-45s %6s %6s %8s\n' "$host" "$idx" "$conns" "$(human "$bytes")"
      done
    total="$(printf '%s' "$raw" | jq '((.downloadTotal // 0) + (.uploadTotal // 0))')"
    printf '\n%s since sing-box started, across %s open connections.\n' \
      "$(human "$total")" "$(printf '%s' "$raw" | jq '.connections|length')"
    ;;
esac
