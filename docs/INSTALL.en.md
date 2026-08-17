# INSTALL — Detailed installation

**Language:** [Tiếng Việt](INSTALL.md) | English

## 1. Copy and configure

Copy the repository to `/root/sbproxy`, then create the private configuration:

```sh
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
vi config/wifi-socks.conf
vi config/settings.sh
```

Set `RADIO_2G`, `RADIO_5G`, and the required two-letter `WIFI_COUNTRY`. Verify the actual BSSID limit with `iw list`.

## 2. Preflight and dependencies

```sh
sh scripts/preflight.sh
sh scripts/install-deps.sh
```

The installer selects `opkg` on OpenWrt 24.10 or `apk` on OpenWrt 25.12. GL.iNet OEM firmware is detected but remains experimental.

## 3. Preview and apply

```sh
DRYRUN=1 sh scripts/apply.sh | less
sh scripts/apply.sh
```

Dry-run generates and validates staged UCI, sing-box, and nftables artifacts without changing UCI or `/etc`.

## 4. Later changes

```sh
sh scripts/set-sock.sh IDX HOST PORT [USER] [PASS]
```

Editing the SSID list requires a full `apply.sh`. Removed managed indexes are cleaned automatically. See [testing](TESTING.en.md) and [rollback](ROLLBACK.en.md) before production use.
