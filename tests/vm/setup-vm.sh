#!/bin/sh
# tests/vm/setup-vm.sh — make a radioless OpenWrt VM look enough like the router
# that the pool code can be exercised against a real kernel.
#
#   sh tests/vm/setup-vm.sh          # install shims and bridges
#   sh tests/vm/setup-vm.sh --undo   # take them away again
#
# WHY SHIMS AND NOT A CODE CHANGE
#
# A VM has no Wi-Fi radios, so `ubus call network.wireless status` returns
# nothing and `iw dev … station dump` has nothing to dump. Rather than teach the
# production scripts about a test mode, this installs two small programs earlier
# on PATH that answer those two questions from files and forward everything else
# to the real binaries. scripts/lib.sh stays exactly as it ships.
#
# WHAT THE VM THEREFORE CANNOT TELL YOU
#
# Anything downstream of a real radio: how many BSSIDs a card will carry, what
# happens when a device roams, throughput, and the RAM figures D10 needs. Those
# still require the GL-MT6000. What it does tell you is whether the nftables and
# sing-box the generator writes actually load and work, which is where the
# design risk is.
set -eu

SHIM_DIR=/usr/local/bin
STATE_DIR=/etc/sbproxy-vm
SSIDS="${SSIDS:-2}"
NET_BASE="${NET_BASE:-10}"

if [ "${1:-}" = "--undo" ]; then
  rm -f "$SHIM_DIR/ubus" "$SHIM_DIR/iw"
  i=1
  while [ "$i" -le 32 ]; do
    ip link show "br-w$i" >/dev/null 2>&1 && ip link delete "br-w$i" || true
    i=$((i + 1))
  done
  rm -rf "$STATE_DIR"
  echo "Removed the shims and the br-w* bridges."
  exit 0
fi

[ "$(id -u)" = "0" ] || { echo "setup-vm.sh must run as root"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "install jq first: opkg install jq"; exit 1; }

mkdir -p "$SHIM_DIR" "$STATE_DIR/stations"

# --- the bridges the ruleset dispatches on ---------------------------------
# br-w<idx> with 192.168.<NET_BASE + idx>.1/24, the same arithmetic net_octet()
# uses, so idx_of_ip and the generated rules agree with what is really there.
i=1
while [ "$i" -le "$SSIDS" ]; do
  octet=$((NET_BASE + i))
  if ! ip link show "br-w$i" >/dev/null 2>&1; then
    ip link add name "br-w$i" type bridge
    ip addr add "192.168.$octet.1/24" dev "br-w$i"
    ip link set "br-w$i" up
  fi
  : > "$STATE_DIR/stations/br-w$i"
  i=$((i + 1))
done

# --- what the wireless stack would have said -------------------------------
{
  printf '{"radio0":{"interfaces":['
  i=1
  while [ "$i" -le "$SSIDS" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"section":"w%s","ifname":"br-w%s"}' "$i" "$i"
    i=$((i + 1))
  done
  printf ']}}\n'
} > "$STATE_DIR/wireless.json"

cat > "$SHIM_DIR/ubus" <<'SHIM'
#!/bin/sh
# Answer the one wireless query from a file; forward everything else untouched.
if [ "${1:-}" = "call" ] && [ "${2:-}" = "network.wireless" ] && [ "${3:-}" = "status" ]; then
  cat /etc/sbproxy-vm/wireless.json
  exit 0
fi
exec /bin/ubus "$@"
SHIM

cat > "$SHIM_DIR/iw" <<'SHIM'
#!/bin/sh
# `iw dev <ifname> station dump` reads /etc/sbproxy-vm/stations/<ifname>, so a
# device can be made to "join" by appending to that file. Everything else goes
# to the real iw if there is one.
if [ "${1:-}" = "dev" ] && [ "${3:-}" = "station" ] && [ "${4:-}" = "dump" ]; then
  cat "/etc/sbproxy-vm/stations/${2:-}" 2>/dev/null
  exit 0
fi
[ -x /usr/sbin/iw ] && exec /usr/sbin/iw "$@"
exit 0
SHIM

chmod +x "$SHIM_DIR/ubus" "$SHIM_DIR/iw"

# The shims only work if they come first. OpenWrt's default PATH puts
# /usr/local/bin ahead of /usr/sbin, but say so rather than assume it.
case ":$PATH:" in
  *":$SHIM_DIR:"*) : ;;
  *) echo "WARNING: $SHIM_DIR is not on PATH; add it before /usr/sbin or the shims will not be used." ;;
esac

cat <<EOF
Ready. $SSIDS bridge(s) up, wireless and station data stubbed.

To make a device join br-w1:
  printf 'Station aa:bb:cc:dd:ee:01 (on br-w1)\\n\\tsignal:  \\t-40 dBm\\n' \\
    >> $STATE_DIR/stations/br-w1

To give it a lease the DHCP hook will see:
  echo '99999 aa:bb:cc:dd:ee:01 192.168.$((NET_BASE + 1)).50 vm-client *' >> /tmp/dhcp.leases

Then, from the repository root on this machine:
  ALLOW_UNSUPPORTED_BOARD=1 sh scripts/preflight.sh
  ALLOW_UNSUPPORTED_BOARD=1 sh scripts/apply.sh
  sh tests/vm/spike.sh

Undo everything with: sh tests/vm/setup-vm.sh --undo
EOF
