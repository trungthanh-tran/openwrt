#!/bin/sh
# tests/vm/datapath.sh — does a packet actually come out of the proxy it was
# pinned to?
#
# Every other suite in this repository stops one step short of that. They check
# the text the generators write; spike.sh checks that a kernel will load such
# text. Neither can tell you that the device at 192.168.11.50 leaves through
# slot 0 and the one at .51 leaves through slot 1 -- which is the entire point
# of the pool.
#
# So this builds the real thing and sends real bytes through it: the production
# generators, the production nftables file, the production sing-box config, the
# production policy routing out of etc/init.d/sbproxy, two clients in network
# namespaces on the SSID bridge, and one fake SOCKS5 server per slot that names
# itself down the connection. If the client reads back SLOT0, the packet went
# through slot 0. There is no way to fake that.
#
# NOT SAFE ON A LIVE ROUTER. It loads its own ruleset into `inet sbproxy` and
# its own policy rule, so it would replace what a running deployment is using.
# It refuses to start if that table already exists.
#
#   sh tests/vm/datapath.sh
# shellcheck disable=SC2034  # POOL_* and the file paths are read by the lib.sh generators.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/sbproxy-datapath}"
BRIDGE=br-w1
NS1=sbdp1
NS2=sbdp2
IP1=192.168.11.50
IP2=192.168.11.51
GW=192.168.11.1
TARGET=198.51.100.9        # TEST-NET-2: routable nowhere, so only the proxy can answer
MARK=1
MASK=255
TABLE=100
PRIORITY=10000

n_ok=0; n_bad=0
ok() { n_ok=$((n_ok + 1)); printf '  ok    %s\n' "$1"; }
no() { n_bad=$((n_bad + 1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — want[$3] got[$2]"; fi; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "datapath.sh needs $1"; exit 1; }
}
[ "$(id -u)" = 0 ] || { echo "datapath.sh must run as root"; exit 1; }
for c in nft ip sing-box python3; do need "$c"; done

if nft list table inet sbproxy >/dev/null 2>&1; then
  echo "datapath.sh: inet sbproxy already exists -- refusing to replace a live"
  echo "ruleset. Stop sbproxy first if this really is a test machine."
  exit 1
fi

cleanup() {
  [ -n "${BRNF_WAS:-}" ] && echo "$BRNF_WAS" > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null
  [ -n "${SB_PID:-}" ] && kill "$SB_PID" 2>/dev/null
  [ -n "${P0_PID:-}" ] && kill "$P0_PID" 2>/dev/null
  [ -n "${P1_PID:-}" ] && kill "$P1_PID" 2>/dev/null
  [ -n "${P2_PID:-}" ] && kill "$P2_PID" 2>/dev/null
  for ns in "$NS1" "$NS2"; do ip netns del "$ns" 2>/dev/null; done
  ip link del veth-a 2>/dev/null
  ip link del veth-b 2>/dev/null
  nft delete table inet sbproxy 2>/dev/null
  ip -4 rule del priority "$PRIORITY" 2>/dev/null
  ip -4 route flush table "$TABLE" 2>/dev/null
  ip link del "$BRIDGE" 2>/dev/null
}
trap cleanup EXIT INT TERM

rm -rf "$WORK"; mkdir -p "$WORK/config"

# --- a fixture whose proxies are the fake SOCKS servers below ---------------
cat > "$WORK/config/wifi-socks.conf" <<EOF
Datapath|2g|1|password123|127.0.0.1|11079|u1|p1|0|0
EOF
cat > "$WORK/config/proxy-pools.conf" <<EOF
1|socks5|127.0.0.1|11080|u1|p1|slot-zero
1|socks5|127.0.0.1|11081|u1|p1|slot-one
EOF
chmod 600 "$WORK/config"/*.conf

# --- one fake SOCKS5 server per slot ----------------------------------------
# It speaks just enough SOCKS5 to satisfy sing-box -- greeting, username or no
# authentication, CONNECT -- then writes its own name instead of connecting
# anywhere. The name is the evidence: it can only reach the client through the
# slot that dialled this server.
cat > "$WORK/socks.py" <<'PY'
import socket, struct, sys, threading

NAME = sys.argv[1]
PORT = int(sys.argv[2])


def handle(c):
    try:
        head = c.recv(2)
        if len(head) < 2:
            return
        nmethods = head[1]
        methods = c.recv(nmethods)
        if 2 in methods:
            c.sendall(b"\x05\x02")
            ver = c.recv(1)
            ulen = c.recv(1)[0]
            c.recv(ulen)
            plen = c.recv(1)[0]
            c.recv(plen)
            c.sendall(b"\x01\x00")
        else:
            c.sendall(b"\x05\x00")
        req = c.recv(4)
        if len(req) < 4:
            return
        atyp = req[3]
        if atyp == 1:
            c.recv(4)
        elif atyp == 3:
            c.recv(c.recv(1)[0])
        else:
            c.recv(16)
        c.recv(2)
        c.sendall(b"\x05\x00\x00\x01" + struct.pack("!IH", 0, 0))
        c.sendall(NAME.encode() + b"\n")
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(16)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

python3 "$WORK/socks.py" SLOT0   11080 > "$WORK/s0.log" 2>&1 & P0_PID=$!
python3 "$WORK/socks.py" SLOT1   11081 > "$WORK/s1.log" 2>&1 & P1_PID=$!
python3 "$WORK/socks.py" DEFAULT 11079 > "$WORK/s2.log" 2>&1 & P2_PID=$!
sleep 1

# --- the bridge the SSID would have -----------------------------------------
ip link show "$BRIDGE" >/dev/null 2>&1 || {
  ip link add name "$BRIDGE" type bridge
  ip addr add "$GW/24" dev "$BRIDGE"
  ip link set "$BRIDGE" up
}

# --- generate with the production code, exactly as apply.sh does ------------
SB_ROOT="$ROOT"; export SB_ROOT
CONF="$WORK/config/wifi-socks.conf"; export CONF
POOLS="$WORK/config/proxy-pools.conf"; export POOLS
ALLOW_UNSUPPORTED_BOARD=1; export ALLOW_UNSUPPORTED_BOARD

# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"
# These go after the source, not before: settings.sh assigns ASSIGN_FILE
# unconditionally and would overwrite an exported value.
ASSIGN_FILE="$WORK/assign"
LEASES="$WORK/leases"
printf '%s\n' "1|aa:bb:cc:dd:ee:50|0|manual" "1|aa:bb:cc:dd:ee:51|1|manual" > "$ASSIGN_FILE"
printf '%s\n' "1700000000 aa:bb:cc:dd:ee:50 $IP1 c50 *" \
              "1700000000 aa:bb:cc:dd:ee:51 $IP2 c51 *" > "$LEASES"
NFT_FILE="$WORK/sbproxy.nft"
SINGBOX_CONF="$WORK/config.json"
POOL_DIVERT=off        # WSL kernels have no nft_socket; the pin path is what is under test
build_nft >/dev/null 2>&1
build_singbox >/dev/null 2>&1

echo "== the generated artifacts =="
if nft -c -f "$NFT_FILE" >/dev/null 2>&1; then ok "the ruleset parses"; else no "the ruleset parses"; fi
if sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then ok "the sing-box config is valid"; else no "the sing-box config is valid"; fi

echo
echo "== bringing the real thing up =="
if nft -f "$NFT_FILE" 2>/dev/null; then ok "the ruleset loads"; else no "the ruleset loads"; fi
# The policy routing from etc/init.d/sbproxy, which is what delivers a marked
# packet to the local TPROXY socket instead of forwarding it.
ip -4 rule del priority "$PRIORITY" 2>/dev/null || true
ip -4 rule add priority "$PRIORITY" fwmark "$MARK/$MASK" table "$TABLE"
ip -4 route replace local default dev lo table "$TABLE"

# A router forwards; TPROXY delivery of a routed packet needs it here too.
sysctl -wq net.ipv4.ip_forward=1 2>/dev/null || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
BRNF_WAS="$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo)"
[ -n "$BRNF_WAS" ] && echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
sing-box run -c "$SINGBOX_CONF" > "$WORK/singbox.log" 2>&1 & SB_PID=$!
sleep 3
if kill -0 "$SB_PID" 2>/dev/null; then ok "sing-box stays up on the generated config"; else no "sing-box stays up on the generated config — $(head -3 "$WORK/singbox.log")"; fi

# --- two clients on the bridge ----------------------------------------------
mkns() { # ns veth ip
  ip netns add "$1"
  ip link add "$2" type veth peer name "$2p"
  ip link set "$2p" master "$BRIDGE"
  ip link set "$2p" up
  ip link set "$2" netns "$1"
  ip netns exec "$1" ip addr add "$3/24" dev "$2"
  ip netns exec "$1" ip link set "$2" up
  ip netns exec "$1" ip link set lo up
  ip netns exec "$1" ip route add default via "$GW"
}
mkns "$NS1" veth-a "$IP1"
mkns "$NS2" veth-b "$IP2"

# What the client reads back is the name of the SOCKS server that served it.
whoami_via() { # ns
  ip netns exec "$1" python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(6)
try:
    s.connect(('$TARGET', 80))
    sys.stdout.write(s.recv(32).decode(errors='replace').strip())
except Exception as e:
    sys.stdout.write('ERR:%s' % e)
" 2>/dev/null
}

echo
echo "== the question this whole repository exists to answer =="
eq "the device pinned to slot 0 leaves through slot 0" "$(whoami_via "$NS1")" "SLOT0"
eq "the device pinned to slot 1 leaves through slot 1" "$(whoami_via "$NS2")" "SLOT1"

echo
echo "== moving a device, with no reload of anything =="
assign_live_update 1 aa:bb:cc:dd:ee:50 1
eq "assign_live_update moves it to the other proxy" "$(whoami_via "$NS1")" "SLOT1"
eq "the device that did not move is unaffected"     "$(whoami_via "$NS2")" "SLOT1"

# The same call again, on a device that already has an element: `add element`
# alone would fail with EEXIST here, which is why assign_live_update deletes
# first. Moving it back proves the second move works as well as the first.
assign_live_update 1 aa:bb:cc:dd:ee:50 0
eq "and moves it back, so a re-pin is not a one-off" "$(whoami_via "$NS1")" "SLOT0"

nft delete element inet sbproxy w1map "{ $IP1 }" 2>/dev/null
eq "unpinning falls back to the SSID's own proxy" "$(whoami_via "$NS1")" "DEFAULT"

echo
echo "DATAPATH TOTAL: pass=$n_ok fail=$n_bad"
[ "$n_bad" -eq 0 ]
