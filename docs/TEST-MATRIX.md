# sbproxy automated test matrix

This is the default English test reference. The suites are safe to run on a
workstation: Agent and OpenWrt behavior uses temporary files and command
stubs, and never contacts a real router.

## Run everything

```sh
make test
# or
sh tests/run-all.sh
```

Requirements: Python 3, POSIX `sh`, and `jq`. Tk GUI smoke tests run when a
display is available and skip cleanly on headless CI. Agent/health tests skip
locally when `jq` is absent, while both CI pipelines install it and require the
full suites to pass.

## Native desktop core

Suite: `tests/test_desktop_core.py`

| Area | Normal cases | Edge and failure cases |
|---|---|---|
| EN/VI translation | Known strings, reverse mapping, formatted strings | Unknown strings and dynamic error prefixes |
| Dark/Light palettes | Both palettes expose the same required tokens | Missing/inconsistent palette keys |
| Router MAC vendors | Known, local/random, and custom OUI round-trips | Lowercase input, partial/invalid/non-hex OUI |
| DPAPI config envelope | Save/load URL, protected token, preferences | Missing, malformed, non-object JSON; decrypt failure; invalid preference values |
| Environment provisioning | URL/token provisioning and token removal | Missing/blank token |
| Agent HTTP client | GET/POST, text/JSON body, auth header, endpoint timeout contracts | HTTP JSON/plain errors, DNS/timeout/OSError, malformed or non-object JSON, `ok:false` fallbacks |
| Wi-Fi records | 10/11 columns, parse/render, ordering, comments | Every min/max boundary; duplicate IDX; invalid flags/types/delimiters/OUI; blank SOCKS host |
| Human formatting | Bytes and connection durations at unit boundaries | Negative, malformed, `NaN`, and infinity |
| Device filters | SSID, query, band, presence, access, signal, traffic, duration in EN and VI | Every RSSI/traffic/time boundary; missing fields; malformed numeric telemetry; combined filters |
| Table sorting | Wi-Fi IDX/subnet, band, BSSID/provider, SOCKS port, flags and health; Devices IP, text, status and numeric columns | Repeated clicks reverse direction; invalid/missing IPv4/IPv6, malformed telemetry, health and runtime data |
| CLI entry points | `--provision` and `--probe` success | Missing token, failed probe, expected exit codes |

## Native desktop workflows

Suite: `tests/test_desktop_workflows.py`

| Area | Cases locked by tests |
|---|---|
| Connection | URL scheme/token validation, required connection, runtime SSID parsing |
| SSID selection | No selection, unknown selection, first free IDX, hard 200-SSID limit |
| Gateway card | `ok`, `degraded`, `down`, unknown, non-`wwan`, DNS not checked, HTTP failure |
| Auto refresh | Cancel/reschedule, valid interval, malformed interval fallback, disabled state |
| Device selection | Empty/single/multiple selection and enabled/disabled action buttons |
| Background task runner | Success/error marshalling, loading state, callback, translated status |
| Important mutations | Warning is default-deny and cancellation performs no mutation |
| Apply | Required dry-run → save → final Agent apply order; dry-run and apply failures stop safely |
| Device actions | Kick/ban/unban eligibility, bulk operation, partial failure, continued processing |
| Export/clipboard | Empty selection, UTF-8 BOM CSV, Unicode values, cancellation, filesystem failure |
| Backups | Empty/invalid/safe labels, selection state, confirmation, rollback reconnect delay |
| SSID deletion/addition | Confirmation and 200-SSID limit without opening an invalid dialog |

## Dirty and adversarial data

Suite: `tests/test_dirty_data.py`, plus dirty-input sections in
`tests/test_agent.sh`, `tests/test_healthd.sh`, and `tests/run.sh`.

| Trust boundary | Cases locked by tests |
|---|---|
| Desktop Wi-Fi config | Non-string JSON shapes; C0/C1/DEL controls; NUL/tab; unpaired Unicode surrogates; UTF-8 byte boundaries; unsafe/oversized hosts and credentials; mixed valid/invalid rows |
| Desktop Agent response | Every valid JSON scalar/array shape, malformed UTF-8, nested/non-string error payloads |
| Desktop telemetry | Wrong top-level container; mixed non-object rows; nested wrong field types; negative/huge numbers; `NaN`/infinity; deterministic 200-row dirty corpus across filters, formatters, and every sort column |
| Agent request body | Invalid/oversized `Content-Length`, actual body over 256 KiB, raw NUL (using `od` or the BusyBox `hexdump` fallback), malformed JSON, valid non-object JSON, wrong field types, fractional/boolean indexes, controls, and oversized strings |
| Agent mutation safety | Invalid requests return 4xx before invoking apply, SOCKS, MAC, backup, rollback, kick, ban, unban, or uninstall scripts |
| Agent script output | Malformed JSON, valid JSON with the wrong gateway/client schema, non-object client rows, script failure, and corrupt health JSON |
| Health daemon | Corrupt config rows are skipped without a probe; malformed and `NaN` curl telemetry becomes a bounded failure record |

## Native Tk GUI

Suite: `tests/test_desktop_gui.py`

- Renders English × Dark, English × Light, Vietnamese × Dark, and Vietnamese
  × Light.
- Verifies live language/theme handlers persist their selections.
- Opens Wi-Fi edit, Random MAC, blocklist, and loading dialogs in both
  languages.
- Automatically skips only when no graphical display is available.

## Agent CGI

Suite: `tests/test_agent.sh`

| Endpoint/area | Cases locked by tests |
|---|---|
| CORS/auth | Unauthenticated OPTIONS, missing server token, missing/wrong Bearer, valid Bearer and legacy token |
| Dispatch | Invalid action and wrong HTTP methods for every mutating endpoint |
| `status` | Sorted SSIDs, runtime MAC, health/meta, auth-presence flag, no Wi-Fi/SOCKS password leakage |
| `get_conf`, `health_now` | Content type/source body and absent-health fallback |
| `save_conf` | Empty body, exact 10/11-column validation, backup failure preserves old config, successful write |
| `dryrun_conf` | Empty body, success/failure structure, temp candidate does not replace desired config |
| `apply` | Mandatory dry-run gate, real apply never runs after gate failure, real failure propagation |
| `set_sock` | Malformed/non-object JSON; wrong/fractional types; missing/out-of-range IDX/port; invalid/control/oversized host or credentials; quoted credentials; script failure |
| `rotate_mac` | Malformed/out-of-range IDX, malformed OUI, omitted versus explicit-empty OUI, runtime MAC response |
| `backup`, `backups` | Default/safe labels, path traversal/unsafe labels, listing and `latest` exclusion |
| `rollback` | Latest/safe snapshot, unsafe/path-traversal name rejection |
| `download_backup` | Traversal, missing archive, fallback archive, preferred sysupgrade archive |
| `gateway`, `clients` | Valid payload, malformed payload, valid JSON with wrong schema, non-object client rows, script failure |
| `kick`, `ban`, `unban` | Malformed JSON/IDX/MAC, matching dispatch, success/failure envelope |
| `uninstall` | Method guard and dispatch |

The Agent test creates a complete fake router tree under `mktemp`, including
stub scripts and UCI state. No endpoint reaches `/root`, `/etc/config`, Wi-Fi,
or the network.

## Agent health daemon

Suite: `tests/test_healthd.sh`

- Tests SOCKS5h URLs with and without authentication.
- Covers HTTP 200/204/301/302, unexpected status, curl transport failure,
  latency rounding, exact slow threshold, and above-threshold state.
- Verifies valid atomic JSON, all probe IDs, timestamp, and temp-file cleanup.
- Verifies missing config and missing `jq` fail without publishing output.
- Skips malformed config rows and normalizes malformed/`NaN` probe output to a
  safe failure object without calling curl for rejected rows.

## OpenWrt scripts and generated configuration

Suite: `tests/run.sh`

- Configuration validation and boundary behavior.
- MAC generation/OUI persistence and rotate-MAC behavior.
- UCI generation, stale cleanup, gateway-scoped admin firewall rules.
- Mandatory Agent dry-run and guarded apply path.
- nftables DNS/TCP/UDP TPROXY, QUIC/WebRTC policy, RFC1918 and SOCKS bypass.
- sing-box fake-IP, reverse mapping, SOCKS network/auth outputs.
- Client inventory integration and offline blocklist entries.
- PC update package manifests and Agent installer security/deployment checks.

## Real-router acceptance tests

Automation cannot faithfully emulate radio firmware, MediaTek drivers,
TPROXY in the kernel, upstream SOCKS providers, or actual `wwan`. After the
workstation suites pass, run the hardware acceptance scenarios in
[TESTING.en.md](TESTING.en.md), especially:

- DNS fake-IP plus hostname reverse mapping from each managed SSID.
- HTTP and HTTPS through each assigned SOCKS5 endpoint.
- QUIC fallback, WebRTC blocking, client isolation, kick/ban/unban.
- Gateway route, DNS, and HTTP probe through `wwan`.
- Recovery after failed apply, rollback, radio reload, and reboot.
