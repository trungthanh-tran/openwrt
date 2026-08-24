# Debugging guide (workstation and router)

**Language:** [Tiếng Việt](DEBUGGING.md) | English

> The Vietnamese edition ([DEBUGGING.md](DEBUGGING.md)) is the fuller field reference: it keeps the long symptom table and command transcripts that are summarised here.

For people changing the code: set up an environment, isolate a failure on the
workstation and on a real router, then report it with the right evidence.

## Environment

Linux or WSL is closest to OpenWrt. Install `git`, POSIX `sh`, `jq`,
`shellcheck`, `make`, and `hexdump` (usually in `bsdextrautils`); the desktop
suites need Python 3 with Tkinter. No router is required — `uci`, `ubus`, and
`iw` are stubbed in the tests.

```sh
sh tests/run-all.sh     # or: make test
make check              # shellcheck + every suite, what CI runs
```

Tk tests skip without a display and `jq`-dependent groups skip without `jq`, so
install `jq` before concluding that the sing-box generator or `clients.sh` is
broken. GitHub CI runs on Ubuntu; GitLab CI runs Alpine/BusyBox ash, which is
closest to the router shell. Do not use Git Bash mixed with Windows utilities as
the baseline — `sed`/`sort` differences and a missing `hexdump` produce false
failures.

## Code map

| Area | File |
|---|---|
| Core logic, sing-box/nftables generators | `scripts/lib.sh` |
| Applying configuration (supports `DRYRUN=1`) | `scripts/apply.sh` |
| Device listing (hostapd/ubus, `iw`, `/tmp/dhcp.leases`) | `scripts/clients.sh` |
| Read-only status report | `scripts/doctor.sh` |
| Read-only evidence collection | `scripts/diagnose.sh` |
| LAN API | `agent/cgi/sbproxy`, `agent/sbproxy-healthd` |
| Web console (self-hosted at `/www/sbproxy/index.html`) | `console/web/control-panel.html` |
| Native desktop console (Tkinter, no WebView) | `console/desktop/main.py` |
| Tests | `tests/` — see [TEST-MATRIX.md](TEST-MATRIX.md) |

The two consoles share the Agent API but not their UI code: changing one does
not change the other.

## Isolating a failure

On the workstation: record the commit, OS, and tool versions, run
`sh tests/run-all.sh` for the first failing assertion, then `make lint`. If only
GitLab CI fails, look for bashisms or BusyBox ash differences — the router shell
is POSIX/BusyBox, with no arrays and no `[[ ... ]]`.

On the router, from the checkout that is deployed:

```sh
sh scripts/verify.sh
sh scripts/doctor.sh
sh scripts/diagnose.sh > /tmp/sbproxy-diagnose.txt 2>&1
```

`doctor.sh` exits non-zero on `[FAIL]`; `[WARN]` is not necessarily fatal.
`diagnose.sh` restarts nothing. Common first checks: sing-box `>= 1.12` and
`sing-box check -c /etc/sing-box/config.json`; a `dport 53` rule in chain
`inet sbproxy prerouting` plus `fakeip` in the config when DNS leaks; the
`w<idx>` inbound/outbound pair, `ip rule` mark `0x1`, and route table 100 when
traffic misses its SOCKS; `ubus list | grep hostapd` when the device list is
empty; `/etc/sbproxy.bans` when a ban does not survive apply.

After changing router logic, rerun the tests on the workstation, then on the
router run `DRYRUN=1 sh scripts/apply.sh`, `sh scripts/apply.sh`,
`sh scripts/verify.sh`, and `sh scripts/doctor.sh`. `apply.sh` changes router
state, so keep a backup and a rollback path. Client-side checks live in
[TESTING.en.md](TESTING.en.md).

## Reporting

Never share `config/wifi-socks.conf`, tokens, `/etc/sbproxy.bans`, backups, or
SOCKS/Wi-Fi passwords. Mask public IPs, hostnames, SSIDs, MACs, and credentials
first; the desktop console's `logs/console.log` and `logs/audit.log` already redact secrets.

Include: the commit, workstation environment, router model and OpenWrt/sing-box
versions, expected versus actual behavior, the exact commands, the first failing
assertion, `doctor.sh` WARN/FAIL lines, the relevant part of `diagnose.sh`, and
`git status --short`. Do not infer router faults from unit tests alone: TPROXY,
hostapd ubus, BSSID limits, and radio behavior can only be confirmed on real
hardware.
