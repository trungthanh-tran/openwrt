# INSTALL — Detailed installation

**Language:** [Tiếng Việt](INSTALL.md) | English

> The Vietnamese edition ([INSTALL.md](INSTALL.md)) is the fuller field reference: it keeps the long troubleshooting tables and command transcripts that are summarised here.

Connect over SSH to `root@192.168.8.1`, the GL-MT6000 GL.iNet default, or use its configured LAN address.

> **Shortcut:** the desktop console performs every step below over SSH from
> one screen — see the four-step [quick start](QUICKSTART.en.md). Use the
> manual steps when you want to see or adapt each command.

## 1. Copy and configure

Copy the repository to `/root/sbproxy`, then create the private configuration:

```sh
cd /root/sbproxy
cp config/wifi-socks.conf.example config/wifi-socks.conf
vi config/wifi-socks.conf
vi config/settings.sh
```

Set `RADIO_2G` and `RADIO_5G`. `WIFI_COUNTRY` is optional: a valid two-letter code is written to both radios, and an empty one leaves the country OpenWrt already has in place. Verify the actual BSSID limit with `iw list`.

## 2. Preflight and dependencies

The dependency setup also installs `coreutils-cksum`. It lets proxy-pool random
assignment seed directly from `/dev/urandom`; a built-in fallback remains for
minimal images whose package feed does not provide it.

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
