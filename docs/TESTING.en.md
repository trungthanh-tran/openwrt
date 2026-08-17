# TESTING — Acceptance checks

**Language:** [Tiếng Việt](TESTING.md) | English

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
3. Run a DNS leak test. DNS through dnsmasq may still expose the real ISP in v0.2; record this as a known failure until per-SSID DNS routing is implemented.
4. Run a WebRTC leak test when `webrtc=1`.
5. Verify that two clients on the same isolated SSID cannot reach each other.
6. Verify that clients cannot reach router administration ports.
7. Verify that no public IPv6 route is available.

## SOCKS change check

Run `set-sock.sh`, verify Wi-Fi and DHCP remain associated, and confirm the public IP changes. Existing sessions may be interrupted because sing-box restarts.

Do not mark the deployment production-ready until every required check has a recorded result.
