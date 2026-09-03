#!/bin/sh
# Probe one proxy from the router, right now, and say why it fails.
#
#   probe-proxy.sh <host> <port> [user] [pass] [socks5|http]
#
# Same request the health daemon makes (curl through the proxy to a 204
# endpoint), but verbose: the JSON carries curl's exit code, its error line,
# and the tail of the handshake transcript with the password blanked. This
# is what separates "the proxy refuses the router's IP" from "wrong password"
# from "curl on this firmware cannot speak SOCKS".
set -u
[ -f /etc/sbproxy/env ] && . /etc/sbproxy/env
PROBE_URL="${PROBE_URL:-https://www.gstatic.com/generate_204}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
# Where the router asks for its public address, so the operator knows which
# IP the proxy provider has to whitelist.
PUBLIC_IP_URL="${PUBLIC_IP_URL:-https://api.ipify.org}"

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"missing jq"}'; exit 1; }
out() { jq -n "$@"; }

# Replace every literal occurrence of $2 in $1 with ***. sed is the wrong tool
# here: the password is data, but sed reads it as a regex AND as part of the
# s||| command, so `|`, `[`, `&`, `;` in a real password broke the masking or
# leaked the cleartext (and could even smuggle sed commands).
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

host="${1:-}"; port="${2:-}"; user="${3:-}"; pass="${4:-}"; proxy_type="${5:-socks5}"
[ -n "$host" ] && [ -n "$port" ] || { out '{ok:false,error:"host and port are required"}'; exit 1; }
case "$host" in *[!A-Za-z0-9._:-]*) out '{ok:false,error:"invalid host"}'; exit 1;; esac
case "$port" in ''|*[!0-9]*) out '{ok:false,error:"invalid port"}'; exit 1;; esac
case "$proxy_type" in socks5|http) :;; *) out '{ok:false,error:"type must be socks5 or http"}'; exit 1;; esac
command -v curl >/dev/null 2>&1 || { out '{ok:false,state:"fail",error:"curl is not installed on the router"}'; exit 1; }

[ "$proxy_type" = "http" ] && scheme="http" || scheme="socks5h"
if [ -n "$user" ]; then px="$scheme://$user:$pass@$host:$port"; else px="$scheme://$host:$port"; fi

errf="${TMPDIR:-/tmp}/sbproxy-probe-proxy.$$"
res="$(curl -v -sS -o /dev/null -m "$PROBE_TIMEOUT" -x "$px" \
       -w '%{http_code} %{time_total}' "$PROBE_URL" 2>"$errf")"; rc=$?
transcript="$(tail -n 25 "$errf" 2>/dev/null | tr -d '\r')"; rm -f "$errf"
transcript="$(mask_secret "$transcript" "$pass")"
err="$(printf '%s\n' "$transcript" | grep -m1 '^curl:' || true)"
[ -n "$err" ] || err="$(printf '%s\n' "$transcript" | grep -m1 -i 'denied\|refused\|timed out\|auth' || true)"

code="$(printf '%s' "$res" | awk '{print $1}')"
t="$(printf '%s' "$res" | awk '{print $2}')"
ms=0
printf '%s' "$t" | grep -Eq '^[0-9]+([.][0-9]+)?$' && ms="$(awk -v t="$t" 'BEGIN{printf "%d", (t*1000)+0.5}')"
state=fail
case "$code" in 200|204|301|302) state=ok ;; esac
[ "$rc" -eq 0 ] || state=fail

# ---- Separate the causes a PC never sees ---------------------------------
# 1. Does this curl build speak SOCKS at all? (OpenWrt ships a slim curl on
#    some images.) If not, the health probe is meaningless and sing-box is
#    the only witness.
curl_socks=true
if [ "$scheme" != "http" ]; then
  case "$transcript" in
    *"Unsupported proxy scheme"*|*"not supported"*|*"Protocol \"socks"*) curl_socks=false ;;
  esac
  case "$rc" in 1|4) curl_socks=false ;; esac
fi
# 2. Plain TCP to host:port, no SOCKS handshake. Refused/timeout here while
#    the router otherwise reaches the Internet means the provider blocks the
#    router's IP (or the port is wrong) — a whitelist problem, not a
#    credential problem.
#    A plain http:// request to the proxy port is used rather than telnet://,
#    which slim curl builds (OpenWrt included) do not carry. A SOCKS server
#    answers HTTP with garbage or hangs up: that still proves the port opens.
#    Only "connection refused", "timed out" and "cannot resolve" mean closed.
tcp_rc=99
curl -sS -o /dev/null -m 5 "http://$host:$port/" >/dev/null 2>&1; tcp_rc=$?
case "$tcp_rc" in 7|28|6) tcp_open=false ;; *) tcp_open=true ;; esac
# 3. Does the router reach the Internet without the proxy?
direct_rc=99
curl -sS -o /dev/null -m 5 "$PROBE_URL" >/dev/null 2>&1; direct_rc=$?
[ "$direct_rc" -eq 0 ] && direct_ok=true || direct_ok=false
# 4. The address the provider sees when the router connects.
public_ip="$(curl -sS -m 5 "$PUBLIC_IP_URL" 2>/dev/null | tr -d '\r\n' | cut -c1-64)"
case "$public_ip" in *[!0-9a-fA-F.:]*) public_ip="" ;; esac
# 5. What sing-box itself said about this proxy lately.
singbox_log=""
command -v logread >/dev/null 2>&1 && \
  singbox_log="$(logread -e sing-box 2>/dev/null | grep -F "$host" | tail -n 8 | tr -d '\r')"
singbox_log="$(mask_secret "$singbox_log" "$pass")"

# A one-line reading a person can act on.
hint=""
case "$rc" in
  0) [ "$state" = ok ] || hint="the proxy answered but the probe URL returned HTTP $code" ;;
  5|97) hint="the proxy refused or dropped the connection: wrong port, or the provider only allows whitelisted client IPs (the router's WAN IP is not the PC's)" ;;
  7) hint="cannot connect to $host:$port from the router: port closed, host unreachable, or the provider whitelists client IPs" ;;
  28) hint="timed out: the proxy did not answer within ${PROBE_TIMEOUT}s" ;;
  35|60) hint="TLS failed after the proxy connected: check the router clock/CA certificates" ;;
  6) hint="cannot resolve $host on the router: DNS on the WAN side is broken" ;;
  1|4) hint="this curl build cannot speak $scheme: install the full curl package" ;;
esac
case "$transcript" in
  *"authentication failed"*|*"Authentication failed"*|*"407 "*) hint="the proxy rejected the username/password" ;;
esac

# The verdict combines the five checks; it is what the operator acts on.
verdict=""
if [ "$state" = ok ]; then
  verdict="ok: the router reaches the Internet through this proxy"
elif [ "$curl_socks" = false ]; then
  verdict="curl-no-socks: this router's curl cannot speak SOCKS, so the health check is meaningless; judge by the sing-box log below"
elif [ "$direct_ok" = false ]; then
  verdict="wan-down: the router cannot reach $PROBE_URL even without the proxy; fix the WAN first"
elif [ "$tcp_open" = false ]; then
  verdict="blocked: $host:$port does not answer a plain TCP request from the router${public_ip:+ (public IP $public_ip)} although the WAN works — usually the provider whitelists client IPs or the port is wrong; add ${public_ip:-the router public IP} to the proxy allowed-IP list. (A timeout here can also be a SOCKS server waiting silently for a handshake — if the port is known-open, suspect the credentials or the proxy type instead.)"
else
  case "$transcript" in
    *"authentication failed"*|*"Authentication failed"*|*"407 "*)
      verdict="auth: TCP to the proxy is open but it rejected the username/password" ;;
    *)
      verdict="socks-refused: TCP to $host:$port is open but the SOCKS/HTTP handshake failed${public_ip:+ (public IP $public_ip)} — usually the provider allows the connection then refuses non-whitelisted IPs at the proxy layer, or the credentials are wrong" ;;
  esac
fi

out --arg state "$state" --argjson rc "$rc" --argjson ms "$ms" --argjson code "${code:-0}" \
    --arg error "$err" --arg hint "$hint" --arg transcript "$transcript" \
    --arg host "$host" --arg port "$port" --arg type "$proxy_type" \
    --argjson curl_socks "$curl_socks" --argjson tcp_open "$tcp_open" --argjson tcp_rc "$tcp_rc" \
    --argjson direct_ok "$direct_ok" --arg public_ip "$public_ip" \
    --arg singbox_log "$singbox_log" --arg verdict "$verdict" \
    '{ok:true, state:$state, curl_exit:$rc, latency_ms:$ms, code:$code,
      error:$error, hint:$hint, verdict:$verdict,
      checks:{curl_socks:$curl_socks, tcp_open:$tcp_open, tcp_curl_exit:$tcp_rc,
              direct_internet:$direct_ok, public_ip:$public_ip},
      singbox_log:$singbox_log, transcript:$transcript,
      host:$host, port:$port, type:$type}'
