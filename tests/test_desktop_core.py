#!/usr/bin/env python3
"""Headless unit tests for the native Windows controller core.

These tests deliberately avoid creating a Tk window, so they run on Linux CI,
BusyBox-oriented GitLab CI, and Windows developer machines.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "console" / "desktop"
sys.path.insert(0, str(DESKTOP))
import main as app  # noqa: E402


class FakeResponse:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.body


def valid_record(**changes):
    values = {
        "name": "test1",
        "band": "2g",
        "idx": 1,
        "wifi_password": "password12",
        "host": "proxy.example",
        "port": 1080,
        "user": "alice",
        "socks_password": "secret123",
        "isolate": True,
        "webrtc": True,
        "mac_oui": "50:C7:BF",
    }
    values.update(changes)
    return app.WifiRecord(**values)


def client_row(**changes):
    values = {
        "ssid": "test1",
        "band": "2g",
        "online": True,
        "banned": False,
        "ip": "192.168.11.20",
        "host": "Phone",
        "mac": "AA:BB:CC:DD:EE:FF",
        "ifname": "phy0-ap0",
        "signal_dbm": -60,
        "rx_bytes": 10 * 1024 * 1024,
        "tx_bytes": 1,
        "connected_s": 300,
    }
    values.update(changes)
    return values


class TranslationTests(unittest.TestCase):
    def test_known_translation_and_vietnamese_identity(self):
        self.assertEqual(app.translate("Thiết bị", "en"), "Devices")
        self.assertEqual(app.translate("Thiết bị", "vi"), "Thiết bị")

    def test_unknown_translation_is_preserved(self):
        self.assertEqual(app.translate("custom text", "en"), "custom text")

    def test_dynamic_prefix_translation(self):
        message = "Dòng cấu hình cần 10 hoặc 11 cột: broken"
        self.assertEqual(
            app.translate(message, "en"),
            "Configuration row must have 10 or 11 columns: broken",
        )

    def test_format_values(self):
        self.assertEqual(app.translate("value={value}", "vi", value=7), "value=7")

    def test_source_text_reverses_translation(self):
        self.assertEqual(app.source_text("Devices"), "Thiết bị")
        self.assertEqual(app.source_text("unchanged"), "unchanged")

    def test_palettes_have_identical_complete_keys(self):
        self.assertEqual(set(app.DARK_PALETTE), set(app.LIGHT_PALETTE))
        for key in (
            "bg", "card", "text", "primary", "danger", "input",
            "tab_idle", "tab_hover", "tab_selected", "tab_selected_text",
            "table_border", "table_header_border", "table_row_even", "table_row_odd",
        ):
            self.assertIn(key, app.DARK_PALETTE)
        self.assertEqual(set(app.PALETTES), {"dark", "light"})


class VendorTests(unittest.TestCase):
    def test_known_vendor_label_is_case_insensitive(self):
        self.assertEqual(app.vendor_label("50:c7:bf"), "TP-Link · 50:C7:BF")

    def test_empty_vendor_uses_local_prefix(self):
        self.assertEqual(app.vendor_label(""), "Ngẫu nhiên / ẩn danh · 02:xx local")

    def test_custom_vendor_round_trip(self):
        label = app.vendor_label("12:34:56")
        self.assertEqual(app.vendor_oui(label), "12:34:56")

    def test_english_vendor_round_trip(self):
        label = app.translate(app.vendor_label(""), "en")
        self.assertEqual(app.vendor_oui(label), "")

    def test_vendor_oui_accepts_suffix(self):
        self.assertEqual(app.vendor_oui("Any provider · aa:bb:cc"), "AA:BB:CC")

    def test_vendor_oui_rejects_missing_or_partial_oui(self):
        for value in ("", "TP-Link", "AA:BB", "GG:00:11"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                app.vendor_oui(value)

    def test_vendor_choices_adds_unknown_current_once(self):
        choices = app.vendor_choices("12:34:56")
        self.assertEqual(choices.count("OUI tuỳ chỉnh · 12:34:56"), 1)
        self.assertEqual(len(choices), len(set(choices)))


class ConfigPersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config_dir = Path(self.temp.name) / "settings"
        self.config_file = self.config_dir / "connection.json"
        self.patches = (
            mock.patch.object(app, "CONFIG_DIR", self.config_dir),
            mock.patch.object(app, "CONFIG_FILE", self.config_file),
            mock.patch.object(app, "_dpapi_protect", side_effect=lambda value: "sealed:" + value),
            mock.patch.object(app, "_dpapi_unprotect", side_effect=lambda value: value.removeprefix("sealed:")),
        )
        for patcher in self.patches:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patches):
            patcher.stop()
        self.temp.cleanup()

    def test_missing_and_invalid_config_return_safe_defaults(self):
        self.assertEqual(app._read_config_payload(), {})
        self.config_dir.mkdir(parents=True)
        for payload in ("not json", "[]", "null"):
            self.config_file.write_text(payload, encoding="utf-8")
            self.assertEqual(app._read_config_payload(), {})

    def test_write_is_atomic_and_valid_json(self):
        app._write_config_payload({"language": "vi"})
        self.assertEqual(json.loads(self.config_file.read_text(encoding="utf-8")), {"language": "vi"})
        self.assertFalse(self.config_file.with_suffix(".tmp").exists())

    def test_save_connection_trims_values_and_defaults_preferences(self):
        app.save_connection(" http://router.local/ ", " token-value ")
        payload = app._read_config_payload()
        self.assertEqual(payload["base_url"], "http://router.local")
        self.assertEqual(payload["token_dpapi"], "sealed:token-value")
        self.assertEqual((payload["language"], payload["theme"]), ("en", "dark"))
        self.assertNotIn("\"token-value\"", self.config_file.read_text(encoding="utf-8"))

    def test_save_connection_preserves_preferences(self):
        app.save_preferences("vi", "light")
        app.save_connection("https://router/", "abc")
        self.assertEqual(app.load_preferences(), ("vi", "light"))
        self.assertEqual(app.load_connection(), ("https://router", "abc"))

    def test_invalid_preferences_fall_back(self):
        app._write_config_payload({"language": "xx", "theme": "neon"})
        self.assertEqual(app.load_preferences(), ("en", "dark"))

    def test_save_invalid_preferences_normalizes(self):
        app.save_preferences("xx", "neon")
        self.assertEqual(app.load_preferences(), ("en", "dark"))

    def test_load_connection_handles_decryption_failure(self):
        app._write_config_payload({"base_url": "http://bad", "token_dpapi": "broken"})
        with mock.patch.object(app, "_dpapi_unprotect", side_effect=ValueError("bad")):
            self.assertEqual(app.load_connection(), (app.DEFAULT_BASE, ""))

    def test_save_connection_falls_back_to_plain_token_without_dpapi(self):
        # Linux/macOS builds have no DPAPI; the token drops to token_plain and
        # the file relies on chmod 600 (POSIX only).
        with mock.patch.object(app, "_dpapi_protect", side_effect=RuntimeError("no DPAPI")):
            app.save_connection("http://router/", " tok ")
        payload = app._read_config_payload()
        self.assertNotIn("token_dpapi", payload)
        self.assertEqual(payload["token_plain"], "tok")
        self.assertEqual(app.load_connection(), ("http://router", "tok"))

    def test_save_connection_replaces_stale_token_keys(self):
        app._write_config_payload({"token_plain": "old", "token_dpapi": "stale"})
        app.save_connection("http://router/", "new")
        payload = app._read_config_payload()
        self.assertEqual(payload["token_dpapi"], "sealed:new")
        self.assertNotIn("token_plain", payload)

    def test_provision_without_token_does_nothing(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(app, "save_connection") as save:
            self.assertFalse(app.provision_from_environment())
            save.assert_not_called()

    def test_provision_saves_and_removes_token_from_environment(self):
        env = {"SBPROXY_BASE": "http://router/", "SBPROXY_TOKEN": " top-secret "}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertTrue(app.provision_from_environment())
            self.assertNotIn("SBPROXY_TOKEN", os.environ)
        self.assertEqual(app.load_connection(), ("http://router", "top-secret"))


class AgentClientRequestTests(unittest.TestCase):
    def setUp(self):
        self.client = app.AgentClient(" http://router.local/ ", " token ", timeout=31)

    def test_constructor_normalizes_connection(self):
        self.assertEqual(self.client.base_url, "http://router.local")
        self.assertEqual(self.client.token, "token")

    def test_get_request_headers_url_and_default_timeout(self):
        response = FakeResponse(b'{"ok":true,"value":1}')
        with mock.patch.object(app, "urlopen", return_value=response) as opened:
            payload = self.client._request("status")
        self.assertEqual(payload["value"], 1)
        request = opened.call_args.args[0]
        self.assertEqual(request.full_url, "http://router.local/cgi-bin/sbproxy?action=status")
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.headers["Authorization"], "Bearer token")
        self.assertEqual(request.headers["Accept"], "application/json")
        self.assertEqual(opened.call_args.kwargs["timeout"], 31)

    def test_text_body_and_text_response(self):
        with mock.patch.object(app, "urlopen", return_value=FakeResponse(b"a|b\xff")) as opened:
            result = self.client._request("save_conf", "POST", "xin chào", text=True, timeout=9)
        request = opened.call_args.args[0]
        self.assertEqual(request.data, "xin chào".encode("utf-8"))
        self.assertEqual(request.headers["Content-type"], "text/plain; charset=utf-8")
        self.assertIn("�", result)
        self.assertEqual(opened.call_args.kwargs["timeout"], 9)

    def test_json_body_is_encoded(self):
        with mock.patch.object(app, "urlopen", return_value=FakeResponse(b'{"ok":true}')) as opened:
            self.client._request("apply", "POST", {"value": "✓"})
        request = opened.call_args.args[0]
        self.assertEqual(json.loads(request.data.decode("utf-8")), {"value": "✓"})
        self.assertEqual(request.headers["Content-type"], "application/json")

    def test_http_error_prefers_json_error(self):
        error = HTTPError("http://router", 403, "Forbidden", {}, io.BytesIO(b'{"error":"denied"}'))
        with mock.patch.object(app, "urlopen", side_effect=error), self.assertRaisesRegex(app.AgentError, "HTTP 403: denied"):
            self.client.status()

    def test_http_error_falls_back_to_text(self):
        error = HTTPError("http://router", 500, "Error", {}, io.BytesIO(b"plain failure"))
        with mock.patch.object(app, "urlopen", side_effect=error), self.assertRaisesRegex(app.AgentError, "plain failure"):
            self.client.status()

    def test_transport_errors_are_wrapped_with_timeout(self):
        for error in (URLError("dns"), TimeoutError("late"), OSError("down")):
            with self.subTest(error=type(error).__name__), mock.patch.object(app, "urlopen", side_effect=error):
                with self.assertRaisesRegex(app.AgentError, r"31s"):
                    self.client._request("status")

    def test_malformed_json_is_rejected(self):
        with mock.patch.object(app, "urlopen", return_value=FakeResponse(b"not-json")), self.assertRaisesRegex(app.AgentError, "JSON"):
            self.client.status()

    def test_non_object_json_is_rejected(self):
        for body in (b"[]", b"null", b"true"):
            with self.subTest(body=body), mock.patch.object(app, "urlopen", return_value=FakeResponse(body)):
                with self.assertRaisesRegex(app.AgentError, "object"):
                    self.client.status()

    def test_agent_error_uses_error_then_log_then_default(self):
        cases = (
            (b'{"ok":false,"error":"bad"}', "bad"),
            (b'{"ok":false,"log":"failed"}', "failed"),
            (b'{"ok":false}', "Agent báo lỗi"),
        )
        for body, expected in cases:
            with self.subTest(body=body), mock.patch.object(app, "urlopen", return_value=FakeResponse(body)):
                with self.assertRaisesRegex(app.AgentError, expected):
                    self.client.status()

    def test_endpoint_wrappers_use_expected_contracts(self):
        record = valid_record()
        calls = (
            (lambda: self.client.status(), mock.call("status", timeout=15)),
            (lambda: self.client.get_conf(), mock.call("get_conf", text=True, timeout=20)),
            (lambda: self.client.dryrun_conf("cfg"), mock.call("dryrun_conf", "POST", "cfg", timeout=60)),
            (lambda: self.client.save_conf("cfg"), mock.call("save_conf", "POST", "cfg", timeout=45)),
            (lambda: self.client.apply(), mock.call("apply", "POST", {}, timeout=120)),
            (lambda: self.client.clients(), mock.call("clients", timeout=30)),
            (lambda: self.client.gateway(), mock.call("gateway", timeout=15)),
            (lambda: self.client.client_action("ban", 2, "aa:bb:cc:dd:ee:ff"), mock.call("ban", "POST", {"idx": 2, "mac": "aa:bb:cc:dd:ee:ff"}, timeout=45)),
            (lambda: self.client.rotate_mac(2), mock.call("rotate_mac", "POST", {"idx": 2}, timeout=120)),
            (lambda: self.client.rotate_mac(2, ""), mock.call("rotate_mac", "POST", {"idx": 2, "oui": ""}, timeout=120)),
            (lambda: self.client.backups(), mock.call("backups", timeout=30)),
            (lambda: self.client.backup("nightly"), mock.call("backup", "POST", {"label": "nightly"}, timeout=120)),
            (lambda: self.client.rollback("snap"), mock.call("rollback", "POST", {"name": "snap"}, timeout=180)),
        )
        for invoke, expected in calls:
            with self.subTest(expected=expected), mock.patch.object(self.client, "_request", return_value={}) as request:
                invoke()
                self.assertEqual(request.call_args, expected)
        with mock.patch.object(self.client, "_request", return_value={}) as request:
            self.client.set_sock(record)
            request.assert_called_once_with("set_sock", "POST", {
                "idx": 1, "host": "proxy.example", "port": 1080,
                "user": "alice", "pass": "secret123",
            }, timeout=60)


class WifiRecordTests(unittest.TestCase):
    def test_parse_10_and_11_column_rows(self):
        ten = "A|2g|1|password12|proxy|1080|||1|0"
        eleven = ten + "|aa:bb:cc\r\n"
        self.assertEqual(app.WifiRecord.from_row(ten).mac_oui, "")
        self.assertEqual(app.WifiRecord.from_row(eleven).mac_oui, "aa:bb:cc")

    def test_wrong_column_counts_rejected(self):
        for count in (0, 1, 9, 12):
            row = "|".join(["x"] * count)
            with self.subTest(count=count), self.assertRaises(ValueError):
                app.WifiRecord.from_row(row)

    def test_non_numeric_idx_and_port_rejected(self):
        for row in (
            "A|2g|x|password12|proxy|1080|||1|1",
            "A|2g|1|password12|proxy|x|||1|1",
        ):
            with self.subTest(row=row), self.assertRaises(ValueError):
                app.WifiRecord.from_row(row)

    def test_boolean_columns_must_be_zero_or_one(self):
        for isolate, webrtc in (("2", "1"), ("1", "yes"), ("", "0")):
            row = f"A|2g|1|password12|proxy|1080|||{isolate}|{webrtc}"
            with self.subTest(row=row), self.assertRaisesRegex(ValueError, "0 hoặc 1"):
                app.WifiRecord.from_row(row)

    def test_valid_boundaries(self):
        for name_length in (1, 32):
            for password_length in (8, 63):
                record = valid_record(name="x" * name_length, wifi_password="p" * password_length)
                record.validate()
        for idx in (1, 200):
            valid_record(idx=idx).validate()
        for port in (1, 65535):
            valid_record(port=port).validate()

    def test_invalid_boundaries(self):
        cases = (
            {"name": ""}, {"name": "x" * 33},
            {"band": "6g"}, {"idx": 0}, {"idx": 201}, {"idx": True}, {"idx": "1"},
            {"wifi_password": "p" * 7}, {"wifi_password": "p" * 64},
            {"host": ""}, {"host": "   "},
            {"port": 0}, {"port": 65536}, {"port": True}, {"port": "1080"},
            {"isolate": 1}, {"webrtc": 0},
            {"mac_oui": "AA:BB"}, {"mac_oui": "GG:00:11"}, {"mac_oui": None},
        )
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                valid_record(**changes).validate()

    def test_delimiters_and_line_breaks_rejected_in_every_text_field(self):
        for field in ("name", "wifi_password", "host", "user", "socks_password"):
            for bad in ("x|y", "x\ny", "x\ry"):
                with self.subTest(field=field, bad=repr(bad)), self.assertRaises(ValueError):
                    valid_record(**{field: bad}).validate()

    def test_non_string_text_field_rejected(self):
        with self.assertRaisesRegex(ValueError, "chuỗi"):
            valid_record(user=None).validate()

    def test_to_row_normalizes_flags_and_oui(self):
        row = valid_record(isolate=False, webrtc=True, mac_oui="aa:bb:cc").to_row()
        self.assertEqual(row.split("|")[8:], ["0", "1", "AA:BB:CC"])

    def test_parse_ignores_comments_blank_lines_and_sorts(self):
        content = """# header

B|5g|2|password12|proxy2|1080|||1|0|
   # indented comment
A|2g|1|password12|proxy1|1080|||1|1|
"""
        records = app.parse_conf(content)
        self.assertEqual([record.idx for record in records], [1, 2])

    def test_parse_rejects_duplicate_idx(self):
        content = "A|2g|1|password12|a|1|||1|1|\nB|5g|1|password12|b|2|||1|1|\n"
        with self.assertRaisesRegex(ValueError, "trùng"):
            app.parse_conf(content)

    def test_render_sorts_has_header_and_trailing_newline(self):
        rendered = app.render_conf([valid_record(idx=2, name="B"), valid_record(idx=1, name="A")])
        data = [line for line in rendered.splitlines() if not line.startswith("#")]
        self.assertEqual([line.split("|")[0] for line in data], ["A", "B"])
        self.assertTrue(rendered.endswith("\n"))

    def test_render_empty_has_only_header(self):
        rendered = app.render_conf([])
        self.assertIn("generated by", rendered)
        self.assertEqual([line for line in rendered.splitlines() if line and not line.startswith("#")], [])

    def test_render_rejects_duplicate_and_invalid_records(self):
        with self.assertRaisesRegex(ValueError, "trùng"):
            app.render_conf([valid_record(), valid_record(name="B")])
        with self.assertRaises(ValueError):
            app.render_conf([valid_record(port=0)])


class FormattingTests(unittest.TestCase):
    def test_human_bytes_boundaries(self):
        cases = {
            None: "0 B", 0: "0 B", 1023: "1023 B", 1024: "1.0 KB",
            1024 ** 2: "1.0 MB", 1024 ** 3: "1.0 GB", 1536: "1.5 KB",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(app.human_bytes(value), expected)

    def test_human_bytes_bad_negative_and_nonfinite_are_safe(self):
        for value in (-1, "bad", float("nan"), float("inf"), object()):
            with self.subTest(value=value):
                self.assertEqual(app.human_bytes(value), "0 B")

    def test_human_time_boundaries(self):
        cases = {None: "0m 0s", 59: "0m 59s", 60: "1m 0s", 3599: "59m 59s", 3600: "1h 0m", 3661: "1h 1m"}
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(app.human_time(value), expected)

    def test_human_time_invalid_is_zero(self):
        for value in (-1, "bad", object(), float("inf")):
            with self.subTest(value=value):
                self.assertEqual(app.human_time(value), "0m 0s")


class ClientFilterTests(unittest.TestCase):
    def test_empty_and_default_filters(self):
        self.assertEqual(app.filter_clients([]), [])
        rows = [client_row(), client_row(ssid="test2")]
        self.assertEqual(app.filter_clients(rows), rows)
        self.assertEqual(app.filter_clients(rows, ssid="All SSIDs"), rows)

    def test_ssid_and_query_are_exact_or_casefolded_as_expected(self):
        rows = [client_row(), client_row(ssid="test2", host="Tablet", mac="11:22:33:44:55:66", ifname="phy1-ap0")]
        self.assertEqual(app.filter_clients(rows, ssid="test1"), [rows[0]])
        self.assertEqual(app.filter_clients(rows, query="  phone "), [rows[0]])
        self.assertEqual(app.filter_clients(rows, query="AA:BB"), [rows[0]])
        self.assertEqual(app.filter_clients(rows, query="phy0"), [rows[0]])
        self.assertEqual(app.filter_clients(rows, query="missing"), [])

    def test_band_presence_and_access_in_both_languages(self):
        online = client_row()
        offline_blocked = client_row(band="5g", online=False, banned=True)
        rows = [online, offline_blocked]
        self.assertEqual(app.filter_clients(rows, band="2.4 GHz"), [online])
        self.assertEqual(app.filter_clients(rows, band="5 GHz"), [offline_blocked])
        self.assertEqual(app.filter_clients(rows, presence="Offline"), [offline_blocked])
        self.assertEqual(app.filter_clients(rows, state="Blocked"), [offline_blocked])
        self.assertEqual(app.filter_clients(rows, state="Đang cấm"), [offline_blocked])
        self.assertEqual(app.filter_clients(rows, state="Not blocked"), [online])

    def test_missing_online_defaults_to_online(self):
        row = client_row()
        row.pop("online")
        self.assertEqual(app.filter_clients([row], presence="Online"), [row])

    def test_signal_boundaries_and_unknown_values(self):
        filters = {
            "Excellent (≥ -60 dBm)": (-60, -59.9),
            "Good (-70 to -61 dBm)": (-70, -60.1),
            "Weak (-80 to -71 dBm)": (-80, -70.1),
            "Very weak (< -80 dBm)": (-80.1, -100),
        }
        for selected, accepted in filters.items():
            for value in accepted:
                row = client_row(signal_dbm=value)
                with self.subTest(selected=selected, value=value):
                    self.assertEqual(app.filter_clients([row], signal=selected), [row])
        rejected = (
            ("Excellent (≥ -60 dBm)", -60.1),
            ("Good (-70 to -61 dBm)", -60),
            ("Good (-70 to -61 dBm)", -70.1),
            ("Weak (-80 to -71 dBm)", -70),
            ("Weak (-80 to -71 dBm)", -80.1),
            ("Very weak (< -80 dBm)", -80),
        )
        for selected, value in rejected:
            with self.subTest(selected=selected, value=value):
                self.assertEqual(app.filter_clients([client_row(signal_dbm=value)], signal=selected), [])
        for value in (None, "bad", float("nan"), float("inf")):
            row = client_row(signal_dbm=value)
            with self.subTest(value=value):
                self.assertEqual(app.filter_clients([row], signal="Unknown"), [row])

    def test_traffic_filters_include_boundaries_and_tolerate_bad_data(self):
        zero = client_row(rx_bytes=0, tx_bytes=0)
        ten = client_row(rx_bytes=10 * 1024 * 1024, tx_bytes=0)
        hundred = client_row(rx_bytes=100 * 1024 * 1024, tx_bytes=0)
        bad = client_row(rx_bytes="bad", tx_bytes=-1)
        self.assertEqual(app.filter_clients([zero], traffic="No traffic"), [zero])
        self.assertEqual(app.filter_clients([ten], traffic="At least 10 MB"), [ten])
        self.assertEqual(app.filter_clients([hundred], traffic="At least 100 MB"), [hundred])
        self.assertEqual(app.filter_clients([bad], traffic="No traffic"), [bad])
        self.assertEqual(app.filter_clients([zero], traffic="Has traffic"), [])

    def test_duration_filters_boundaries_require_online(self):
        under = client_row(connected_s=299)
        five = client_row(connected_s=300)
        hour = client_row(connected_s=3600)
        over = client_row(connected_s=3601)
        offline = client_row(online=False, connected_s=10)
        self.assertEqual(app.filter_clients([under], duration="Under 5 minutes"), [under])
        self.assertEqual(app.filter_clients([five], duration="5–60 minutes"), [five])
        self.assertEqual(app.filter_clients([hour], duration="5–60 minutes"), [hour])
        self.assertEqual(app.filter_clients([over], duration="Over 1 hour"), [over])
        self.assertEqual(app.filter_clients([offline], duration="Under 5 minutes"), [])

    def test_all_filters_are_combined_with_and(self):
        wanted = client_row(banned=True, signal_dbm=-55, connected_s=4000, rx_bytes=101 * 1024 * 1024)
        other = client_row(ssid="test2", banned=True, signal_dbm=-55, connected_s=4000, rx_bytes=101 * 1024 * 1024)
        result = app.filter_clients(
            [wanted, other], ssid="test1", query="phone", state="Blocked",
            signal="Excellent (≥ -60 dBm)", band="2.4 GHz", presence="Online",
            traffic="At least 100 MB", duration="Over 1 hour",
        )
        self.assertEqual(result, [wanted])


class ClientSortTests(unittest.TestCase):
    def test_ip_sort_handles_ipv4_ipv6_invalid_and_missing(self):
        self.assertEqual(app.client_sort_key({"ip": "192.168.1.2"}, "ip"), int(app.ipaddress.ip_address("192.168.1.2")))
        self.assertGreater(app.client_sort_key({"ip": "::1"}, "ip"), 0)
        self.assertEqual(app.client_sort_key({"ip": "bad"}, "ip"), -1)
        self.assertEqual(app.client_sort_key({}, "ip"), 0)

    def test_numeric_sort_fields_tolerate_invalid_and_negative(self):
        for column, key in (("time", "connected_s"), ("rx", "rx_bytes"), ("tx", "tx_bytes")):
            self.assertEqual(app.client_sort_key({key: "bad"}, column), 0)
            self.assertEqual(app.client_sort_key({key: -1}, column), 0)
        self.assertEqual(app.client_sort_key({"signal_dbm": "bad"}, "signal"), -999.0)

    def test_status_and_text_sort_keys(self):
        self.assertEqual(app.client_sort_key({"online": True, "banned": False}, "status"), (False, False))
        self.assertEqual(app.client_sort_key({"online": False, "banned": True}, "status"), (True, True))
        self.assertEqual(app.client_sort_key({"host": "Phone"}, "host"), "phone")
        self.assertEqual(app.client_sort_key({}, "host"), "")


class WifiSortTests(unittest.TestCase):
    def test_numeric_and_natural_columns_do_not_sort_as_display_strings(self):
        two = valid_record(idx=2, host="proxy", port=9000)
        ten = valid_record(idx=10, host="proxy", port=1080)
        self.assertLess(app.wifi_sort_key(two, "idx"), app.wifi_sort_key(ten, "idx"))
        self.assertLess(app.wifi_sort_key(two, "subnet"), app.wifi_sort_key(ten, "subnet"))
        self.assertGreater(app.wifi_sort_key(two, "socks"), app.wifi_sort_key(ten, "socks"))

    def test_band_mac_flags_and_health_have_typed_sort_keys(self):
        two_g = valid_record(band="2g", isolate=False, webrtc=False, mac_oui="50:C7:BF")
        five_g = valid_record(band="5g", isolate=True, webrtc=True, mac_oui="20:E5:2A")
        self.assertLess(app.wifi_sort_key(two_g, "band"), app.wifi_sort_key(five_g, "band"))
        self.assertLess(app.wifi_sort_key(two_g, "isolate"), app.wifi_sort_key(five_g, "isolate"))
        self.assertLess(app.wifi_sort_key(two_g, "webrtc"), app.wifi_sort_key(five_g, "webrtc"))
        self.assertLess(
            app.wifi_sort_key(two_g, "mac", runtime={"macaddr": "02:00:00:00:00:01"}),
            app.wifi_sort_key(five_g, "mac", runtime={"macaddr": "02:00:00:00:00:02"}),
        )
        self.assertLess(
            app.wifi_sort_key(two_g, "health", {"state": "ok", "latency_ms": 900}),
            app.wifi_sort_key(five_g, "health", {"state": "slow", "latency_ms": 10}),
        )

    def test_every_column_tolerates_missing_and_dirty_auxiliary_data(self):
        record = valid_record()
        for column in ("idx", "name", "band", "subnet", "mac", "socks", "isolate", "webrtc", "health"):
            with self.subTest(column=column):
                app.wifi_sort_key(record, column, health=["bad"], runtime="bad")
                app.wifi_sort_key(object(), column, health={"state": {}, "latency_ms": []}, runtime={"macaddr": {}})


class EntryPointTests(unittest.TestCase):
    def setUp(self):
        # main() bootstraps the private app home; keep tests off the real one.
        self.patches = (
            mock.patch.object(app, "setup_logging", return_value=Path("log")),
            mock.patch.object(app, "install_exception_logging"),
            mock.patch.object(app, "migrate_legacy_config", return_value=False),
        )
        for patcher in self.patches:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patches):
            patcher.stop()

    def test_probe_without_token_and_with_agent_results(self):
        with mock.patch.object(app, "load_connection", return_value=("http://router", "")):
            self.assertFalse(app.probe_saved_connection())
        with mock.patch.object(app, "load_connection", return_value=("http://router", "token")), mock.patch.object(app.AgentClient, "status", return_value={"ok": True}):
            self.assertTrue(app.probe_saved_connection())
        with mock.patch.object(app, "load_connection", return_value=("http://router", "token")), mock.patch.object(app.AgentClient, "status", side_effect=OSError("down")):
            self.assertFalse(app.probe_saved_connection())

    def test_main_provision_exit_codes(self):
        for provisioned, expected in ((True, 0), (False, 2)):
            with self.subTest(provisioned=provisioned), mock.patch.object(app, "provision_from_environment", return_value=provisioned), mock.patch.object(sys, "argv", ["main.py", "--provision"]):
                self.assertEqual(app.main(), expected)

    def test_main_probe_exit_codes(self):
        for result, expected in ((True, 0), (False, 1)):
            with self.subTest(result=result), mock.patch.object(app, "provision_from_environment", return_value=False), mock.patch.object(app, "probe_saved_connection", return_value=result), mock.patch.object(sys, "argv", ["main.py", "--probe"]):
                self.assertEqual(app.main(), expected)


class AppHomeIsolationTests(unittest.TestCase):
    """Everything the EXE writes must stay inside one private folder."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_env_override_wins_over_every_other_location(self):
        target = self.root / "custom home"
        with mock.patch.dict(os.environ, {"SBPROXY_HOME": str(target)}, clear=False):
            self.assertEqual(app.resolve_app_home(), target)

    def test_portable_data_folder_beside_executable_is_used(self):
        exe_dir = self.root / "portable"
        (exe_dir / "data").mkdir(parents=True)
        env = {k: v for k, v in os.environ.items() if k != "SBPROXY_HOME"}
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(app, "frozen_dir", return_value=exe_dir):
            self.assertEqual(app.resolve_app_home(), exe_dir / "data")

    def test_per_user_location_is_the_fallback(self):
        exe_dir = self.root / "installed"
        exe_dir.mkdir()
        env = {"LOCALAPPDATA": str(self.root / "local"), "XDG_DATA_HOME": str(self.root / "share")}
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(app, "frozen_dir", return_value=exe_dir):
            home = app.resolve_app_home()
        expected_base = self.root / ("local" if os.name == "nt" else "share")
        self.assertEqual(home, expected_base / app.APP_DIR_NAME)

    def test_ensure_app_home_creates_the_whole_private_tree(self):
        home = self.root / "home"
        paths = {
            "APP_HOME": home, "CONFIG_DIR": home / "config", "LOG_DIR": home / "logs",
            "CACHE_DIR": home / "cache", "RUNTIME_DIR": home / "runtime",
        }
        with mock.patch.multiple(app, **paths):
            app.ensure_app_home()
            for path in paths.values():
                self.assertTrue(path.is_dir(), path)
            if os.name != "nt":
                self.assertEqual(home.stat().st_mode & 0o777, 0o700)

    def test_logging_writes_into_the_private_tree_and_rotates(self):
        home = self.root / "home"
        log_dir = home / "logs"
        with mock.patch.multiple(
            app, APP_HOME=home, CONFIG_DIR=home / "config", LOG_DIR=log_dir,
            CACHE_DIR=home / "cache", RUNTIME_DIR=home / "runtime",
            LOG_FILE=log_dir / "console.log", LOG_MAX_BYTES=2048, LOG_BACKUP_COUNT=2,
        ):
            path = app.setup_logging()
            self.assertEqual(path, log_dir / "console.log")
            for i in range(400):
                app.log.info("filler line %s with enough text to force rotation", i)
            for handler in list(app.log.handlers):
                handler.close()
                app.log.removeHandler(handler)
        written = sorted(p.name for p in log_dir.iterdir())
        self.assertIn("console.log", written)
        self.assertTrue(any(name.startswith("console.log.") for name in written), written)
        self.assertLessEqual(len(written), 3)  # live file + LOG_BACKUP_COUNT

    def test_migration_copies_legacy_config_once_and_never_overwrites(self):
        home = self.root / "home"
        legacy = self.root / "legacy" / "connection.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text('{"base_url": "http://old"}', encoding="utf-8")
        config = home / "config" / "connection.json"
        with mock.patch.multiple(
            app, APP_HOME=home, CONFIG_DIR=home / "config", CONFIG_FILE=config,
            LEGACY_CONFIG_FILES=(legacy,),
        ):
            self.assertTrue(app.migrate_legacy_config())
            self.assertEqual(json.loads(config.read_text(encoding="utf-8"))["base_url"], "http://old")
            config.write_text('{"base_url": "http://new"}', encoding="utf-8")
            self.assertFalse(app.migrate_legacy_config())
            self.assertEqual(json.loads(config.read_text(encoding="utf-8"))["base_url"], "http://new")

    def test_migration_tolerates_missing_legacy_locations(self):
        home = self.root / "home"
        with mock.patch.multiple(
            app, APP_HOME=home, CONFIG_DIR=home / "config",
            CONFIG_FILE=home / "config" / "connection.json",
            LEGACY_CONFIG_FILES=(self.root / "nope" / "connection.json",),
        ):
            self.assertFalse(app.migrate_legacy_config())


class RedactionTests(unittest.TestCase):
    """Logs are shipped to support, so credentials must never reach them."""

    def test_secrets_are_masked_in_every_common_shape(self):
        for dirty in (
            "token=abc123", "token: abc123", 'token "abc123"',
            "Authorization: Bearer abc123", "password=hunter2", "pass 'hunter2'",
            "wifi_key=super-secret", "PASSWD=hunter2",
        ):
            self.assertNotIn("abc123", app.redact(dirty), dirty)
            self.assertNotIn("hunter2", app.redact(dirty), dirty)
            self.assertNotIn("super-secret", app.redact(dirty), dirty)
            self.assertIn("***", app.redact(dirty), dirty)

    def test_non_secret_text_and_non_strings_survive(self):
        self.assertEqual(app.redact("apply finished rc=0"), "apply finished rc=0")
        self.assertEqual(app.redact(7), "7")
        self.assertEqual(app.redact(None), "None")


class VersionTests(unittest.TestCase):
    def test_app_version_matches_repo_version_file(self):
        repo_version = (Path(__file__).resolve().parents[1] / "VERSION").read_text(
            encoding="utf-8").strip()
        self.assertEqual(app.APP_VERSION, repo_version)

    def test_clean_agent_version_accepts_only_semver_strings(self):
        self.assertEqual(app.clean_agent_version({"version": "0.4.0"}), "0.4.0")
        self.assertEqual(app.clean_agent_version({"version": "12.34.56"}), "12.34.56")
        for dirty in (
            None, [], "text", 7, {"version": None}, {"version": 7}, {"version": []},
            {"version": ""}, {"version": "0.4"}, {"version": "0.4.0-rc1"},
            {"version": "0.4.0\n"}, {"version": "v0.4.0"}, {"version": "0.4.0;rm"},
        ):
            self.assertEqual(app.clean_agent_version(dirty), "", repr(dirty))


if __name__ == "__main__":
    unittest.main(verbosity=2)
