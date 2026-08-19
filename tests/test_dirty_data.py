#!/usr/bin/env python3
"""Deterministic dirty-data tests for desktop trust boundaries."""

from __future__ import annotations

import json
from pathlib import Path
import random
import sys
from types import SimpleNamespace
import unittest
from unittest import mock


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


def record(**changes):
    values = {
        "name": "test1",
        "band": "2g",
        "idx": 1,
        "wifi_password": "password12",
        "host": "proxy.example",
        "port": 1080,
        "user": "alice",
        "socks_password": "secret",
        "isolate": True,
        "webrtc": True,
        "mac_oui": "",
    }
    values.update(changes)
    return app.WifiRecord(**values)


class DirtyConfigurationTests(unittest.TestCase):
    def test_c0_c1_and_del_controls_are_rejected_in_all_text_fields(self):
        controls = ("\x00", "\x01", "\t", "\x1f", "\x7f", "\x85")
        for field in ("name", "wifi_password", "host", "user", "socks_password"):
            for control in controls:
                with self.subTest(field=field, control=ord(control)), self.assertRaises(ValueError):
                    record(**{field: f"safe{control}value"}).validate()

    def test_unpaired_unicode_surrogates_are_rejected(self):
        for field in ("name", "wifi_password", "user", "socks_password"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Unicode"):
                record(**{field: "safe\ud800value"}).validate()

    def test_utf8_byte_limits_are_enforced_not_character_counts(self):
        record(name="é" * 16).validate()
        with self.assertRaises(ValueError):
            record(name="é" * 17).validate()
        record(wifi_password="é" * 4).validate()
        with self.assertRaises(ValueError):
            record(wifi_password="é" * 32).validate()

    def test_host_allowlist_and_length_limit(self):
        valid = ("proxy.example", "176.116.132.71", "2001:db8::1", "host_name")
        invalid = ("bad host", "https://proxy", "user@host", "例.example", "x" * 254)
        for host in valid:
            with self.subTest(host=host):
                record(host=host).validate()
        for host in invalid:
            with self.subTest(host=host), self.assertRaises(ValueError):
                record(host=host).validate()

    def test_socks_credentials_have_bounded_utf8_size(self):
        record(user="u" * 255, socks_password="p" * 255).validate()
        for field in ("user", "socks_password"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                record(**{field: "é" * 128}).validate()

    def test_every_text_field_rejects_non_string_json_shapes(self):
        dirty = (None, True, 1, 1.5, [], {}, b"bytes")
        for field in ("name", "wifi_password", "host", "user", "socks_password"):
            for value in dirty:
                with self.subTest(field=field, value=type(value).__name__), self.assertRaises(ValueError):
                    record(**{field: value}).validate()

    def test_one_dirty_row_rejects_the_whole_candidate(self):
        valid = "Good|2g|1|password12|proxy.example|1080|||1|1|"
        dirty_rows = (
            "Bad|2g|2|password12|bad host|1080|||1|1|",
            "Bad|2g|2|password12|proxy.example|1080|bad\tuser||1|1|",
            "Bad|2g|2|password12|proxy.example|1080|||1|1|extra",
            "Bad|2g|2|password12|proxy.example|1080|||true|1|",
        )
        for dirty in dirty_rows:
            with self.subTest(dirty=repr(dirty)), self.assertRaises(ValueError):
                app.parse_conf(f"{valid}\n{dirty}\n")


class DirtyAgentResponseTests(unittest.TestCase):
    def setUp(self):
        self.client = app.AgentClient("http://router", "token")

    def test_all_valid_json_non_objects_are_rejected(self):
        values = (None, True, False, 0, 1.5, "text", [], [object.__name__])
        for value in values:
            raw = json.dumps(value).encode("utf-8")
            with self.subTest(value=value), mock.patch.object(app, "urlopen", return_value=FakeResponse(raw)):
                with self.assertRaisesRegex(app.AgentError, "object"):
                    self.client.status()

    def test_invalid_utf8_inside_json_is_replaced_without_crashing(self):
        raw = b'{"ok":true,"message":"bad\xfftext"}'
        with mock.patch.object(app, "urlopen", return_value=FakeResponse(raw)):
            payload = self.client.status()
        self.assertIn("�", payload["message"])

    def test_nested_or_non_string_error_payload_is_safely_wrapped(self):
        for error in ({"nested": [1, 2]}, ["failure"], 123, True):
            raw = json.dumps({"ok": False, "error": error}).encode("utf-8")
            with self.subTest(error=error), mock.patch.object(app, "urlopen", return_value=FakeResponse(raw)):
                with self.assertRaises(app.AgentError):
                    self.client.status()


class DirtyTelemetryTests(unittest.TestCase):
    def test_normalizer_rejects_wrong_container_and_drops_dirty_rows(self):
        for value in (None, True, 1, "clients", {}, ()):
            with self.subTest(value=type(value).__name__):
                self.assertEqual(app.normalize_clients(value), [])
        first = {"mac": "aa"}
        second = {"mac": "bb"}
        self.assertEqual(app.normalize_clients([None, first, "bad", [], second]), [first, second])

    def test_health_and_backup_normalizers_enforce_nested_schema(self):
        for value in (None, [], {"health": []}, {"health": {"probes": []}}):
            with self.subTest(value=value):
                self.assertEqual(app.normalize_health_probes(value), {})
        probes = app.normalize_health_probes({
            "health": {"probes": {1: {"state": "ok"}, "2": None, "3": []}}
        })
        self.assertEqual(probes, {"1": {"state": "ok"}})

        for value in (None, "snapshot", {}, [None, 1, [], "../bad", "bad/name", "a" * 129]):
            with self.subTest(value=value):
                self.assertEqual(app.normalize_backup_names(value), [])
        self.assertEqual(app.normalize_backup_names(["safe_1", "20260819-good"]), ["safe_1", "20260819-good"])

    def test_runtime_ssids_skip_non_objects_bad_indexes_and_out_of_range(self):
        fake = SimpleNamespace(runtime_ssids={"stale": True})
        app.NativeApp.capture_runtime_ssids(fake, {
            "ssids": [None, [], {"idx": "x"}, {"idx": 0}, {"idx": 201}, {"idx": 1}, {"idx": "2"}]
        })
        self.assertEqual(set(fake.runtime_ssids), {1, 2})

    def test_client_summary_tolerates_dirty_rows_and_numeric_fields(self):
        class Sink:
            def __init__(self):
                self.value = None

            def set(self, value):
                self.value = value

        fake = SimpleNamespace(
            clients_data=[
                None,
                "bad",
                {"online": True, "signal_dbm": {}, "rx_bytes": [], "tx_bytes": float("inf")},
                {"online": True, "signal_dbm": -80, "rx_bytes": 100, "tx_bytes": -50, "banned": True},
            ],
            language="en",
            client_online_count_var=Sink(),
            client_weak_count_var=Sink(),
            client_blocked_count_var=Sink(),
            client_traffic_total_var=Sink(),
        )
        app.NativeApp.update_client_summary(fake)
        self.assertEqual(fake.client_online_count_var.value, "● 2 online")
        self.assertEqual(fake.client_weak_count_var.value, "● 1 weak signal")
        self.assertEqual(fake.client_blocked_count_var.value, "● 1 blocked")
        self.assertIn("100 B", fake.client_traffic_total_var.value)

    def test_filters_ignore_non_objects_and_tolerate_nested_wrong_types(self):
        valid = {"ssid": "test1", "host": "Phone", "online": True}
        nested = {
            "ssid": {"unexpected": "object"},
            "host": ["unexpected", "array"],
            "signal_dbm": {},
            "rx_bytes": [],
            "tx_bytes": float("inf"),
            "connected_s": float("nan"),
        }
        rows = [None, "text", [], valid, nested]
        result = app.filter_clients(rows)
        self.assertEqual(result, [valid, nested])
        self.assertEqual(app.filter_clients(rows, ssid="test1"), [valid])
        self.assertEqual(app.filter_clients(rows, query="phone"), [valid])

    def test_every_sort_column_handles_a_mixed_dirty_corpus(self):
        rows = [
            None,
            "text",
            [],
            {},
            {"ip": []},
            {"connected_s": 10**10000},
            {"rx_bytes": float("nan")},
            {"tx_bytes": {"bad": 1}},
            {"signal_dbm": float("inf")},
            {"online": [], "banned": {}},
            {"host": {"nested": [1]}},
        ]
        for column in ("ip", "time", "rx", "tx", "signal", "status", "host", "ssid", "mac"):
            with self.subTest(column=column):
                sorted(rows, key=lambda item: app.client_sort_key(item, column))

    def test_seeded_mixed_json_corpus_never_crashes_filters_or_formatters(self):
        rng = random.Random(20260819)
        atoms = [None, True, False, -1, 0, 1, 10**500, float("nan"), float("inf"), "", "bad", [], {}]
        keys = ("ssid", "band", "ip", "host", "mac", "ifname", "signal_dbm", "rx_bytes", "tx_bytes", "connected_s", "online", "banned")
        rows = [rng.choice(atoms) for _ in range(40)]
        rows.extend({key: rng.choice(atoms) for key in keys} for _ in range(160))
        app.filter_clients(rows, query="bad")
        app.filter_clients(rows, signal="Unknown", traffic="No traffic", duration="Under 5 minutes")
        for item in rows:
            app.human_bytes(item)
            app.human_time(item)
        for column in ("ip", "time", "rx", "tx", "signal", "status", "host"):
            sorted(rows, key=lambda item: app.client_sort_key(item, column))


if __name__ == "__main__":
    unittest.main(verbosity=2)
