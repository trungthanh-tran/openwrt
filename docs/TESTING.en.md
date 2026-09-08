# TESTING — Acceptance checks

**Language:** [Tiếng Việt](TESTING.md) | English

> The Vietnamese edition ([TESTING.md](TESTING.md)) is the fuller field reference: it keeps the long troubleshooting tables and command transcripts that are summarised here.

Run these checks after every apply and firmware upgrade.

## Router checks

```sh
wifi status
iw dev
ip -4 addr
nft list table inet sbproxy
ip -4 rule show
ip -4 route show table 100
sing-box check -c /etc/sing-box/config.json
logread -e sing-box
```

Confirm that all configured SSIDs exist, MAC addresses begin with `02:`, each bridge has the expected subnet, every TPROXY port is listening, and the policy-routing rule points to the configured table.

## Client checks for every SSID

1. Confirm DHCP assigns the expected `192.168.X.0/24` address.
2. Open `https://ipinfo.io/ip`; it must show the assigned SOCKS egress.
3. Run a DNS leak test. `nslookup example.com` must return a fake-IP in `198.18.0.0/15`; a real IP means the DNS hijack rules are not loaded — rerun `sh scripts/apply.sh` and `sh scripts/verify.sh`.
4. Run a WebRTC leak test. What counts as a pass depends on the SSID's `webrtc`
   mode: `1` must show no public IP at all (and P2P calls stop, by design), `2`
   must show the **proxy's** address rather than the router's and calls must
   still work, and `0` applies no rule so there is nothing to check. `webrtc=2`
   needs `SOCKS_UDP=1` and a proxy that relays UDP ASSOCIATE; without one it
   looks identical to `1` from the outside.
5. On an SSID whose proxy is SOCKS5, check that UDP reaches the Internet:
   open an HTTP/3 page or place a video call. `SOCKS_UDP=1` (the default)
   should carry it; QUIC that hangs before falling back to TCP usually means
   the upstream proxy refuses UDP ASSOCIATE, so set `SOCKS_UDP=0` and reapply.
   An SSID on an HTTP proxy always keeps the UDP 443 drop — HTTP proxies have
   no UDP transport.
6. Verify that two clients on the same isolated SSID cannot reach each other.
7. If `config/routing-rules.conf` is in use, confirm each action: a `direct`
   destination must show the router's real address, a `block` destination must
   fail to load, and anything else must still show the proxy. A narrow rule
   that seems to do nothing is usually below the broad rule it meant to
   override — first match wins.
8. Verify that clients cannot reach router administration ports.
9. Verify that no public IPv6 route is available.

## SOCKS change check

Run `set-sock.sh`, verify Wi-Fi and DHCP remain associated, and confirm the public IP changes. Existing sessions may be interrupted because sing-box restarts.

Do not mark the deployment production-ready until every required check has a recorded result.
