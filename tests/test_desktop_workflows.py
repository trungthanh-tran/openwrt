#!/usr/bin/env python3
"""Headless tests for native-app workflow and safety behavior."""

from __future__ import annotations

import csv
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))
import main as appmod  # noqa: E402


class FakeVar:
    def __init__(self, value=None):
        self.value = value

    def get(self):
        return self.value

    def set(self, value):
        self.value = value


class FakeButton:
    def __init__(self):
        self.options = {}

    def configure(self, **options):
        self.options.update(options)


class FakeLabel(FakeButton):
    pass


class FakeCombo(FakeButton):
    """A combobox that exists and remembers the values offered."""

    def winfo_exists(self):
        return True

    def bind(self, *_args, **_kwargs):
        pass


class FakeRoot:
    def __init__(self, immediate=False):
        self.immediate = immediate
        self.jobs = []
        self.cancelled = []
        self.clipboard = ""

    def after(self, delay, callback, *args):
        job = f"job-{len(self.jobs) + 1}"
        self.jobs.append((job, delay, callback, args))
        if self.immediate:
            callback(*args)
        return job

    def after_cancel(self, job):
        self.cancelled.append(job)

    def wait_window(self, _dialog):
        return None

    def clipboard_clear(self):
        self.clipboard = ""

    def clipboard_append(self, value):
        self.clipboard += value


class FakeTree:
    def __init__(self, selection=(), children=(), row_at_y=""):
        self.selected = tuple(selection)
        self.children = tuple(children)
        self.row_at_y = row_at_y
        self.focused = None

    def selection(self):
        return self.selected

    def selection_set(self, values):
        self.selected = tuple(values) if not isinstance(values, str) else (values,)

    def get_children(self):
        return self.children

    def identify_row(self, _y):
        return self.row_at_y

    def focus(self, value):
        self.focused = value


class FakeMenu:
    def __init__(self):
        self.entries = {}
        self.popup = None
        self.released = False

    def entryconfigure(self, entry, **options):
        self.entries[entry] = options

    def tk_popup(self, x, y):
        self.popup = (x, y)

    def grab_release(self):
        self.released = True


class FakeListbox:
    def __init__(self, names=(), selected=()):
        self.names = list(names)
        self.selected = tuple(selected)

    def curselection(self):
        return self.selected

    def get(self, index):
        return self.names[index]

    def delete(self, _start, _end=None):
        self.names = []

    def insert(self, _where, name):
        self.names.append(name)


class FakeAgent:
    def __init__(self):
        self.calls = []
        self.dryrun_result = {"ok": True, "log": "dry ok"}
        self.gateway_result = {"ok": True, "state": "ok", "interfaces": []}
        self.apply_result = {"ok": True, "log": "apply ok"}
        self.action_fail = set()

    def dryrun_conf(self, content):
        self.calls.append(("dryrun", content))
        return self.dryrun_result

    def save_conf(self, content):
        self.calls.append(("save", content))
        return {"ok": True}

    def apply(self):
        self.calls.append(("apply",))
        return self.apply_result

    def client_action(self, action, idx, mac):
        self.calls.append((action, idx, mac))
        if mac in self.action_fail:
            raise appmod.AgentError("failed")
        return {"ok": True, "log": f"{action}:{mac}"}

    def backup(self, label):
        self.calls.append(("backup", label))
        return {"ok": True, "log": "backup ok"}

    def rollback(self, name):
        self.calls.append(("rollback", name))
        return {"ok": True, "log": "rollback ok"}

    def set_gateway(self, interface):
        self.calls.append(("set_gateway", interface))
        return {"ok": True, "interface": interface, "automatic": interface == ""}

    def gateway(self):
        self.calls.append(("gateway",))
        return self.gateway_result


def record(idx=1, name="test1"):
    return appmod.WifiRecord(name, "2g", idx, "password12", "proxy", 1080)


def bare_app(language="en"):
    instance = object.__new__(appmod.NativeApp)
    instance.root = FakeRoot()
    instance.language = language
    instance.theme = "dark"
    instance.palette = appmod.DARK_PALETTE
    instance.t = lambda text, **values: appmod.translate(text, language, **values)
    instance.records = []
    instance.client = None
    instance.log_history = []
    instance.status_var = FakeVar()
    instance.agent_version = ""
    instance.agent_too_new = False
    instance.agent_outdated = False
    instance.upgrade_offered = False
    return instance


def synchronous_run_task(instance):
    def run_task(_label, function, success=None, **_options):
        result = function()
        if success:
            success(result)
        return result
    instance.run_task = run_task


class ConnectionWorkflowTests(unittest.TestCase):
    def test_make_client_validates_scheme_and_token(self):
        instance = bare_app()
        instance.base_var = FakeVar(" router.local ")
        instance.token_var = FakeVar("token")
        with self.assertRaisesRegex(ValueError, "http"):
            instance._make_client()
        instance.base_var.set("http://router.local/")
        instance.token_var.set("   ")
        with self.assertRaisesRegex(ValueError, "token"):
            instance._make_client()
        instance.token_var.set(" secret ")
        client = instance._make_client()
        self.assertEqual((client.base_url, client.token), ("http://router.local", "secret"))

    def test_require_client(self):
        instance = bare_app()
        with self.assertRaises(appmod.AgentError):
            instance.require_client()
        instance.client = object()
        self.assertIs(instance.require_client(), instance.client)

    def test_capture_runtime_ssids_ignores_invalid_idx_and_last_duplicate_wins(self):
        instance = bare_app()
        instance.capture_runtime_ssids({"ssids": [
            {"idx": "1", "name": "old"}, {"idx": 1, "name": "new"},
            {"idx": "bad"}, {"idx": None},
        ]})
        self.assertEqual(instance.runtime_ssids, {1: {"idx": 1, "name": "new"}})

    def test_next_idx_uses_first_hole_and_enforces_limit(self):
        instance = bare_app()
        instance.records = [record(1), record(3)]
        self.assertEqual(instance.next_idx(), 2)
        instance.records = [record(idx) for idx in range(1, 201)]
        with self.assertRaisesRegex(appmod.AgentError, "200"):
            instance.next_idx()

    def test_selected_wifi_handles_no_selection_and_unknown_idx(self):
        instance = bare_app()
        instance.records = [record(1)]
        instance.wifi_tree = FakeTree()
        self.assertIsNone(instance.selected_wifi())
        instance.wifi_tree = FakeTree(("99",))
        self.assertIsNone(instance.selected_wifi())
        instance.wifi_tree = FakeTree(("1",))
        self.assertIs(instance.selected_wifi(), instance.records[0])

    def test_selected_wifi_tolerates_dirty_tree_id(self):
        instance = bare_app()
        instance.records = [record(1)]
        instance.wifi_tree = FakeTree(("not-an-idx",))
        self.assertIsNone(instance.selected_wifi())

    def test_wifi_context_menu_selects_clicked_row_before_popup(self):
        instance = bare_app()
        instance.records = [record(1), record(2)]
        instance.wifi_tree = FakeTree(("1",), row_at_y="2")
        instance.wifi_context_menu = FakeMenu()
        instance.update_wifi_editor = mock.Mock()
        event = SimpleNamespace(y=20, x_root=140, y_root=260)

        self.assertEqual(instance.show_wifi_context_menu(event), "break")
        self.assertEqual(instance.wifi_tree.selection(), ("2",))
        self.assertEqual(instance.wifi_tree.focused, "2")
        self.assertEqual(instance.wifi_context_menu.popup, (140, 260))
        self.assertTrue(instance.wifi_context_menu.released)
        instance.update_wifi_editor.assert_called_once_with()

    def test_wifi_context_menu_ignores_blank_table_area(self):
        instance = bare_app()
        instance.wifi_tree = FakeTree(("1",), row_at_y="")
        instance.wifi_context_menu = FakeMenu()
        instance.update_wifi_editor = mock.Mock()

        self.assertIsNone(instance.show_wifi_context_menu(SimpleNamespace(y=50, x_root=1, y_root=2)))
        self.assertEqual(instance.wifi_tree.selection(), ("1",))
        self.assertIsNone(instance.wifi_context_menu.popup)
        instance.update_wifi_editor.assert_not_called()

    def test_wifi_editor_updates_buttons_and_context_entries(self):
        instance = bare_app()
        instance.records = [record(1)]
        instance.wifi_edit_buttons = {"edit": FakeButton(), "delete": FakeButton()}
        instance.wifi_context_menu = FakeMenu()
        instance.wifi_context_entries = {"edit": 0, "sock": 1, "mac": 2, "delete": 4}
        instance.wifi_selection_var = FakeVar()
        instance.wifi_tree = FakeTree()

        instance.update_wifi_editor()
        self.assertTrue(all(button.options["state"] == "disabled" for button in instance.wifi_edit_buttons.values()))
        self.assertTrue(all(options["state"] == "disabled" for options in instance.wifi_context_menu.entries.values()))

        instance.wifi_tree.selection_set("1")
        instance.update_wifi_editor()
        self.assertTrue(all(button.options["state"] == "normal" for button in instance.wifi_edit_buttons.values()))
        self.assertTrue(all(options["state"] == "normal" for options in instance.wifi_context_menu.entries.values()))
        self.assertIn("test1", instance.wifi_selection_var.get())


class GatewayWorkflowTests(unittest.TestCase):
    def make_instance(self, language="en"):
        instance = bare_app(language)
        instance.gateway_state_var = FakeVar()
        instance.gateway_route_var = FakeVar()
        instance.gateway_link_var = FakeVar()
        instance.gateway_http_var = FakeVar()
        instance.gateway_state_label = FakeLabel()
        instance.gateway_payload = {}
        instance.gateway_iface_var = FakeVar("")
        instance.gateway_iface_combo = FakeCombo()
        instance.gateway_iface_choices = {}
        instance.gateway_syncing = False
        instance.client = FakeAgent()
        instance.append_log = mock.Mock()
        synchronous_run_task(instance)
        return instance

    def test_render_gateway_ok_with_expected_route(self):
        instance = self.make_instance()
        payload = {
            "state": "ok", "expected_interface": "wwan", "interface": "wwan",
            "device": "phy0-sta0", "gateway": "192.168.8.1", "source_ip": "192.168.8.2",
            "expected_active": True, "link_ok": True, "dns_checked": True,
            "dns_ok": True, "http_ok": True, "http_code": 204, "latency_ms": 31,
        }
        instance.render_gateway(payload)
        self.assertEqual(instance.gateway_state_var.get(), "● Gateway OK")
        self.assertIn("wwan/phy0-sta0", instance.gateway_route_var.get())
        self.assertEqual(instance.gateway_link_var.get(), "Link: OK · DNS: OK")
        self.assertEqual(instance.gateway_http_var.get(), "HTTP: 204 · 31 ms")
        self.assertEqual(instance.gateway_state_label.options["style"], "MetricGreen.TLabel")

    def test_render_gateway_ok_is_fully_localized_in_vietnamese(self):
        instance = self.make_instance("vi")
        payload = {
            "state": "ok", "expected_interface": "wwan", "interface": "wwan",
            "device": "phy0-sta0", "gateway": "192.168.8.1", "source_ip": "192.168.8.2",
            "expected_active": True, "link_ok": True, "dns_checked": True,
            "dns_ok": True, "http_ok": True, "http_code": 204, "latency_ms": 31,
        }
        instance.render_gateway(payload)
        self.assertEqual(instance.gateway_state_var.get(), "● Internet hoạt động")
        self.assertEqual(
            instance.gateway_route_var.get(),
            "Đường ra: wwan/phy0-sta0 · qua 192.168.8.1 · IP nguồn 192.168.8.2",
        )
        self.assertEqual(instance.gateway_link_var.get(), "Kết nối: Tốt · DNS: Tốt")
        self.assertEqual(instance.gateway_http_var.get(), "HTTP: 204 · 31 ms")
        combined = " ".join((
            instance.gateway_state_var.get(), instance.gateway_route_var.get(),
            instance.gateway_link_var.get(), instance.gateway_http_var.get(),
        ))
        for untranslated in ("Gateway", "Link:", " via ", " src "):
            self.assertNotIn(untranslated, combined)

    def test_render_gateway_unknown_defaults_and_unexpected_egress(self):
        instance = self.make_instance("vi")
        instance.render_gateway({"expected_active": False, "dns_checked": False})
        self.assertIn("ĐƯỜNG RA BẤT THƯỜNG", instance.gateway_route_var.get())
        self.assertIn("chưa kiểm tra", instance.gateway_link_var.get())
        self.assertIn("LỖI", instance.gateway_http_var.get())
        self.assertEqual(instance.gateway_state_label.options["style"], "MetricBlue.TLabel")

    def test_a_wired_wan_is_not_reported_as_a_problem(self):
        """The agent enforces no interface by default, so any uplink is fine."""
        for language, expected in (("en", "Egress: wan/eth1"), ("vi", "Đường ra: wan/eth1")):
            with self.subTest(language=language):
                instance = self.make_instance(language)
                instance.render_gateway({
                    "state": "ok", "expected_interface": "", "interface": "wan",
                    "device": "eth1", "gateway": "192.168.88.1", "source_ip": "192.168.88.74",
                    "expected_active": True, "egress_problem": "", "link_ok": True,
                    "dns_checked": True, "dns_ok": True, "http_ok": True,
                    "http_code": 204, "latency_ms": 260,
                })
                route = instance.gateway_route_var.get()
                self.assertIn(expected, route)
                self.assertNotIn("wwan", route)
                self.assertNotIn("NOT VIA", route)
                self.assertNotIn("KHÔNG QUA", route)

    def test_a_routing_loop_through_a_proxied_ssid_is_named(self):
        for language, expected in (("en", "EGRESS THROUGH A PROXIED SSID"),
                                   ("vi", "ĐI QUA SSID ĐƯỢC PROXY")):
            with self.subTest(language=language):
                instance = self.make_instance(language)
                instance.render_gateway({
                    "state": "degraded", "expected_interface": "", "interface": "w1",
                    "device": "br-w1", "expected_active": False,
                    "egress_problem": "proxied-bridge", "link_ok": True,
                    "dns_checked": True, "dns_ok": True, "http_ok": True,
                    "http_code": 204, "latency_ms": 30,
                })
                self.assertIn(expected, instance.gateway_route_var.get())

    GATEWAY_INTERFACES = [
        {"name": "lan", "device": "br-lan", "ipv4": "192.168.1.1", "up": True,
         "current": False, "default_route": False, "proxied": False},
        {"name": "wan", "device": "eth1", "ipv4": "192.168.88.74", "up": True,
         "current": True, "default_route": True, "proxied": False},
        {"name": "wwan", "device": "phy0-sta0", "ipv4": "", "up": False,
         "current": False, "default_route": False, "proxied": False},
        {"name": "w1", "device": "br-w1", "ipv4": "192.168.11.1", "up": True,
         "current": False, "default_route": False, "proxied": True},
    ]

    def gateway_payload(self, **changes):
        payload = {
            "state": "ok", "expected_interface": "", "interface": "wan",
            "device": "eth1", "gateway": "192.168.88.1", "source_ip": "192.168.88.74",
            "expected_active": True, "egress_problem": "", "link_ok": True,
            "dns_checked": True, "dns_ok": True, "http_ok": True,
            "http_code": 204, "latency_ms": 260,
            "interfaces": [dict(entry) for entry in self.GATEWAY_INTERFACES],
        }
        payload.update(changes)
        return payload

    def test_the_uplink_list_comes_from_the_router(self):
        """Nothing is hard-coded: the choices are what the router reported."""
        instance = self.make_instance("vi")
        instance.render_gateway(self.gateway_payload())
        values = instance.gateway_iface_combo.options["values"]
        self.assertEqual(len(values), 5)                      # automatic + four
        self.assertTrue(values[0].startswith("Tự động (wan)"))  # the live uplink
        self.assertIn("wan (eth1) · 192.168.88.74 · đang dùng", values)
        self.assertIn("lan (br-lan) · 192.168.1.1", values)
        self.assertIn("wwan (phy0-sta0) · không hoạt động", values)
        self.assertIn("w1 (br-w1) · 192.168.11.1 · SSID proxy", values)

    def test_automatic_is_selected_when_no_interface_is_pinned(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload())
        self.assertEqual(instance.gateway_iface_var.get(), "Automatic (wan)")
        self.assertEqual(instance.gateway_iface_choices[instance.gateway_iface_var.get()], "")

    def test_a_pinned_interface_is_preselected(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload(expected_interface="wwan"))
        selected = instance.gateway_iface_var.get()
        self.assertTrue(selected.startswith("wwan"))
        self.assertEqual(instance.gateway_iface_choices[selected], "wwan")

    def test_choosing_an_interface_saves_it_and_reloads_the_card(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload())
        # The router answers the follow-up read with the pin now in place.
        instance.client.gateway_result = self.gateway_payload(expected_interface="wwan")
        instance.gateway_iface_var.set("wwan (phy0-sta0) · down")
        instance._on_gateway_interface_changed()
        self.assertEqual(instance.client.calls, [("set_gateway", "wwan"), ("gateway",)])
        self.assertEqual(instance.gateway_iface_choices[instance.gateway_iface_var.get()], "wwan")

    def test_choosing_automatic_clears_the_pin(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload(expected_interface="wwan"))
        instance.gateway_iface_var.set("Automatic (wan)")
        instance._on_gateway_interface_changed()
        self.assertEqual(instance.client.calls[0], ("set_gateway", ""))

    def test_reselecting_the_same_interface_changes_nothing(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload(expected_interface="wwan"))
        instance._on_gateway_interface_changed()
        self.assertEqual(instance.client.calls, [])

    def test_rendering_the_card_never_triggers_a_save(self):
        instance = self.make_instance("en")
        instance.render_gateway(self.gateway_payload())
        instance.render_gateway(self.gateway_payload(expected_interface="wan"))
        self.assertEqual(instance.client.calls, [])

    def test_an_older_agent_without_the_list_still_renders(self):
        instance = self.make_instance("en")
        instance.render_gateway({"state": "ok", "interface": "wan", "device": "eth1"})
        self.assertEqual(instance.gateway_iface_combo.options["values"], ["Automatic"])

    def test_an_enforced_interface_is_still_named_when_it_is_bypassed(self):
        instance = self.make_instance("en")
        instance.render_gateway({
            "state": "degraded", "expected_interface": "wwan", "interface": "wan",
            "device": "eth1", "expected_active": False, "egress_problem": "not-expected",
            "link_ok": True, "dns_checked": True, "dns_ok": True,
            "http_ok": True, "http_code": 204, "latency_ms": 30,
        })
        self.assertIn("NOT VIA wwan", instance.gateway_route_var.get())

    def test_render_gateway_degraded_and_down_styles(self):
        instance = self.make_instance()
        for state, style in (("degraded", "MetricYellow.TLabel"), ("down", "MetricRed.TLabel")):
            with self.subTest(state=state):
                instance.render_gateway({"state": state})
                self.assertEqual(instance.gateway_state_label.options["style"], style)


class SchedulingAndSelectionTests(unittest.TestCase):
    def test_schedule_refresh_cancels_old_and_uses_interval(self):
        instance = bare_app()
        instance.root = FakeRoot()
        instance.client_refresh_job = "old"
        instance.client_auto_var = FakeVar(True)
        instance.client_interval_var = FakeVar("30s")
        instance.client = object()
        instance.schedule_client_refresh()
        self.assertEqual(instance.root.cancelled, ["old"])
        self.assertEqual(instance.root.jobs[0][1], 30000)
        self.assertEqual(instance.client_refresh_job, "job-1")

    def test_schedule_refresh_invalid_interval_falls_back_and_disabled_skips(self):
        instance = bare_app()
        instance.root = FakeRoot()
        instance.client_refresh_job = None
        instance.client_auto_var = FakeVar(True)
        instance.client_interval_var = FakeVar("bad")
        instance.client = object()
        instance.schedule_client_refresh()
        self.assertEqual(instance.root.jobs[0][1], 15000)
        instance.root = FakeRoot()
        instance.client_refresh_job = None
        instance.client_auto_var.set(False)
        instance.schedule_client_refresh()
        self.assertEqual(instance.root.jobs, [])

    def test_selected_client_items_ignores_stale_tree_ids(self):
        instance = bare_app()
        row = {"mac": "aa"}
        instance.client_rows = {"one": row}
        instance.client_tree = FakeTree(("one", "missing"))
        self.assertEqual(instance.selected_client_items(), [row])

    def test_update_client_editor_states_for_empty_single_and_mixed(self):
        instance = bare_app()
        instance.client_selection_var = FakeVar()
        instance.client_edit_buttons = {key: FakeButton() for key in ("details", "copy", "kick", "ban", "unban")}
        instance.selected_client_items = lambda: []
        instance.update_client_editor()
        self.assertTrue(all(button.options["state"] == "disabled" for button in instance.client_edit_buttons.values()))

        online = {"host": "Phone", "ssid": "test1", "online": True, "banned": False}
        instance.selected_client_items = lambda: [online]
        instance.update_client_editor()
        self.assertEqual(instance.client_edit_buttons["details"].options["state"], "normal")
        self.assertEqual(instance.client_edit_buttons["kick"].options["state"], "normal")
        self.assertEqual(instance.client_edit_buttons["unban"].options["state"], "disabled")

        blocked = {"host": "Old", "ssid": "test1", "online": False, "banned": True}
        instance.selected_client_items = lambda: [online, blocked]
        instance.update_client_editor()
        self.assertEqual(instance.client_edit_buttons["details"].options["state"], "disabled")
        self.assertEqual(instance.client_edit_buttons["ban"].options["state"], "normal")
        self.assertEqual(instance.client_edit_buttons["unban"].options["state"], "normal")

    def test_select_all_clients(self):
        instance = bare_app()
        instance.client_tree = FakeTree(children=("a", "b"))
        instance.update_client_editor = mock.Mock()
        self.assertEqual(instance.select_all_clients(), "break")
        self.assertEqual(instance.client_tree.selection(), ("a", "b"))
        instance.update_client_editor.assert_called_once()


class TaskRunnerTests(unittest.TestCase):
    class ImmediateThread:
        def __init__(self, target, daemon):
            self.target = target
            self.daemon = daemon

        def start(self):
            self.target()

    def make_instance(self):
        instance = bare_app()
        instance.root = FakeRoot(immediate=True)
        instance.show_loading = mock.Mock()
        instance.hide_loading = mock.Mock()
        instance._task_error = mock.Mock()
        instance._task_success = mock.Mock()
        return instance

    def test_run_task_success_and_loading(self):
        instance = self.make_instance()
        callback = mock.Mock()
        with mock.patch.object(appmod.threading, "Thread", self.ImmediateThread):
            instance.run_task("Đang làm mới…", lambda: 42, callback, show_loading=True, timeout_hint=8)
        self.assertEqual(instance.status_var.get(), "Refreshing…")
        instance.show_loading.assert_called_once_with("Refreshing…", 8)
        instance._task_success.assert_called_once_with(42, callback)

    def test_run_task_error_is_marshaled_to_ui(self):
        instance = self.make_instance()
        error = RuntimeError("boom")
        with mock.patch.object(appmod.threading, "Thread", self.ImmediateThread):
            instance.run_task("work", mock.Mock(side_effect=error))
        instance._task_error.assert_called_once_with(error)

    def test_task_success_hides_loading_and_calls_callback(self):
        instance = bare_app()
        instance.hide_loading = mock.Mock()
        callback = mock.Mock()
        instance._task_success("result", callback)
        instance.hide_loading.assert_called_once()
        callback.assert_called_once_with("result")
        self.assertEqual(instance.status_var.get(), "Completed")

    def test_confirm_important_defaults_to_no(self):
        instance = bare_app()
        with mock.patch.object(appmod.messagebox, "askyesno", return_value=False) as ask:
            self.assertFalse(instance.confirm_important("Delete", "Do it", "Disconnect"))
        self.assertEqual(ask.call_args.kwargs["default"], appmod.messagebox.NO)
        self.assertEqual(ask.call_args.kwargs["icon"], appmod.messagebox.WARNING)
        self.assertIn("IMPORTANT ACTION", ask.call_args.args[1])


class ApplyWorkflowTests(unittest.TestCase):
    def make_instance(self):
        instance = bare_app()
        instance.client = FakeAgent()
        instance.records = [record()]
        instance.confirm_important = mock.Mock(return_value=True)
        instance.update_loading = mock.Mock()
        instance.append_log = mock.Mock()
        instance.render_wifi = mock.Mock()
        instance.refresh_all = mock.Mock()
        synchronous_run_task(instance)
        return instance

    def test_apply_requires_confirmation(self):
        instance = self.make_instance()
        instance.confirm_important.return_value = False
        instance.save_apply()
        self.assertEqual(instance.client.calls, [])

    def test_apply_dryrun_save_apply_order(self):
        instance = self.make_instance()
        instance.save_apply()
        self.assertEqual([call[0] for call in instance.client.calls], ["dryrun", "save", "apply"])
        self.assertEqual(instance.update_loading.call_count, 3)
        self.assertIn("Apply succeeded", instance.status_var.get())
        self.assertEqual(instance.root.jobs[0][1], 5000)

    def test_failed_dryrun_stops_before_save(self):
        instance = self.make_instance()
        instance.client.dryrun_result = {"ok": False, "log": "invalid candidate"}
        with self.assertRaisesRegex(appmod.AgentError, "invalid candidate"):
            instance.save_apply()
        self.assertEqual([call[0] for call in instance.client.calls], ["dryrun"])

    def test_failed_apply_raises_after_save(self):
        instance = self.make_instance()
        instance.client.apply_result = {"ok": False, "log": "router rejected"}
        with self.assertRaisesRegex(appmod.AgentError, "router rejected"):
            instance.save_apply()
        self.assertEqual([call[0] for call in instance.client.calls], ["dryrun", "save", "apply"])


class ClientActionWorkflowTests(unittest.TestCase):
    def make_instance(self, items, language="en"):
        instance = bare_app(language)
        instance.client = FakeAgent()
        instance.selected_client_items = lambda: list(items)
        instance.confirm_important = mock.Mock(return_value=True)
        instance.append_log = mock.Mock()
        instance.refresh_clients = mock.Mock()
        synchronous_run_task(instance)
        return instance

    def test_no_selection_and_ineligible_selection_do_not_call_agent(self):
        with mock.patch.object(appmod.messagebox, "showinfo") as info:
            instance = self.make_instance([])
            instance.client_action("ban")
            info.assert_called_once()
        cases = (
            ("kick", [{"online": False, "banned": False}]),
            ("ban", [{"online": True, "banned": True}]),
            ("unban", [{"online": True, "banned": False}]),
        )
        for action, items in cases:
            with self.subTest(action=action), mock.patch.object(appmod.messagebox, "showinfo"):
                instance = self.make_instance(items)
                instance.client_action(action)
                self.assertEqual(instance.client.calls, [])

    def test_confirmation_cancel_stops_action(self):
        item = {"idx": 1, "mac": "aa", "online": True, "banned": False}
        instance = self.make_instance([item])
        instance.confirm_important.return_value = False
        instance.client_action("ban")
        self.assertEqual(instance.client.calls, [])

    def test_bulk_action_filters_items_and_continues_after_partial_failure(self):
        eligible = {"idx": 1, "mac": "aa", "online": True, "banned": False}
        failing = {"idx": 1, "mac": "bb", "online": True, "banned": False}
        already = {"idx": 1, "mac": "cc", "online": True, "banned": True}
        instance = self.make_instance([eligible, failing, already])
        instance.client.action_fail.add("bb")
        with mock.patch.object(appmod.messagebox, "showwarning") as warning:
            instance.client_action("ban")
        self.assertEqual(instance.client.calls, [("ban", 1, "aa"), ("ban", 1, "bb")])
        warning.assert_called_once()
        self.assertTrue(any("ERROR" in call.args[0] for call in instance.append_log.call_args_list))
        instance.refresh_clients.assert_called_once()

    def test_kick_only_targets_online_and_unban_only_blocked(self):
        online = {"idx": 1, "mac": "aa", "online": True, "banned": False}
        offline = {"idx": 1, "mac": "bb", "online": False, "banned": True}
        instance = self.make_instance([online, offline])
        instance.client_action("kick")
        self.assertEqual(instance.client.calls, [("kick", 1, "aa")])
        instance = self.make_instance([online, offline])
        instance.client_action("unban")
        self.assertEqual(instance.client.calls, [("unban", 1, "bb")])


class DataExportAndBackupTests(unittest.TestCase):
    def test_copy_selected_clients_and_empty_selection(self):
        instance = bare_app()
        instance.selected_client_items = lambda: [{"ip": "1.2.3.4", "mac": "aa", "host": "phone"}]
        instance.copy_selected_clients()
        self.assertEqual(instance.root.clipboard, "1.2.3.4\taa\tphone")
        self.assertIn("Copied", instance.status_var.get())
        instance.selected_client_items = lambda: []
        with mock.patch.object(appmod.messagebox, "showinfo") as info:
            instance.copy_selected_clients()
            info.assert_called_once()

    def test_export_csv_cancel_and_success_with_utf8_bom(self):
        instance = bare_app()
        instance.visible_clients = [{
            "ssid": "Tết", "band": "2g", "online": True, "banned": False,
            "ip": "1.2.3.4", "host": "điện thoại", "mac": "aa",
            "connected_s": 1, "rx_bytes": 2, "tx_bytes": 3, "signal_dbm": -40,
        }]
        with mock.patch.object(appmod.filedialog, "asksaveasfilename", return_value=""):
            instance.export_clients_csv()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clients.csv"
            with mock.patch.object(appmod.filedialog, "asksaveasfilename", return_value=str(path)):
                instance.export_clients_csv()
            raw = path.read_bytes()
            self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))
            with path.open(encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.reader(handle))
            self.assertEqual(rows[0][0], "ssid")
            self.assertEqual(rows[1][0], "Tết")

    def test_export_csv_io_error_is_reported(self):
        instance = bare_app()
        instance.visible_clients = []
        with mock.patch.object(appmod.filedialog, "asksaveasfilename", return_value="Z:/missing/path/file.csv"), mock.patch.object(appmod.messagebox, "showerror") as error:
            instance.export_clients_csv()
            error.assert_called_once()

    def test_backup_editor_selection_states(self):
        instance = bare_app()
        instance.backup_selection_var = FakeVar()
        instance.rollback_button = FakeButton()
        instance.backup_list = FakeListbox(["snap"], (0,))
        instance.update_backup_editor()
        self.assertEqual(instance.backup_selection_var.get(), "Selected: snap")
        self.assertEqual(instance.rollback_button.options["state"], "normal")
        instance.backup_list.selected = ()
        instance.update_backup_editor()
        self.assertEqual(instance.rollback_button.options["state"], "disabled")

    def test_create_backup_cancel_invalid_and_success(self):
        instance = bare_app()
        instance.client = FakeAgent()
        instance.append_log = mock.Mock()
        instance.refresh_backups = mock.Mock()
        synchronous_run_task(instance)
        with mock.patch.object(appmod.simpledialog, "askstring", return_value=None):
            instance.create_backup()
        self.assertEqual(instance.client.calls, [])
        with mock.patch.object(appmod.simpledialog, "askstring", return_value="../bad"), mock.patch.object(appmod.messagebox, "showerror") as error:
            instance.create_backup()
            error.assert_called_once()
        with mock.patch.object(appmod.simpledialog, "askstring", return_value="nightly-1"):
            instance.create_backup()
        self.assertEqual(instance.client.calls, [("backup", "nightly-1")])
        instance.refresh_backups.assert_called_once()

    def test_rollback_requires_selection_confirmation_and_schedules_reconnect(self):
        instance = bare_app()
        instance.client = FakeAgent()
        instance.backup_list = FakeListbox()
        instance.confirm_important = mock.Mock(return_value=True)
        instance.append_log = mock.Mock()
        instance.connect = mock.Mock()
        synchronous_run_task(instance)
        with mock.patch.object(appmod.messagebox, "showinfo") as info:
            instance.rollback()
            info.assert_called_once()
        instance.backup_list = FakeListbox(["snap"], (0,))
        instance.confirm_important.return_value = False
        instance.rollback()
        self.assertEqual(instance.client.calls, [])
        instance.confirm_important.return_value = True
        instance.rollback()
        self.assertEqual(instance.client.calls, [("rollback", "snap")])
        self.assertEqual(instance.root.jobs[0][1], 7000)


class WifiMutationTests(unittest.TestCase):
    def test_delete_wifi_requires_selection_and_confirmation(self):
        instance = bare_app()
        target = record()
        instance.records = [target]
        instance.selected_wifi = lambda: target
        instance.confirm_important = mock.Mock(return_value=False)
        instance.render_wifi = mock.Mock()
        instance.delete_wifi()
        self.assertEqual(instance.records, [target])
        instance.confirm_important.return_value = True
        instance.delete_wifi()
        self.assertEqual(instance.records, [])
        instance.render_wifi.assert_called_once()

    def test_add_wifi_at_limit_reports_error_without_dialog(self):
        instance = bare_app()
        instance.records = [record(idx) for idx in range(1, 201)]
        instance._task_error = mock.Mock()
        with mock.patch.object(appmod, "WifiDialog") as dialog:
            instance.add_wifi()
        instance._task_error.assert_called_once()
        dialog.assert_not_called()


class AgentCompatibilityTests(unittest.TestCase):
    """The console and the agent it drives must be the same version."""

    def compat_app(self, agent_version):
        instance = bare_app()
        instance.agent_version = agent_version
        instance.setup_hint_var = FakeVar()
        instance.append_log = mock.Mock()
        instance.update_setup_banner = mock.Mock()
        instance.upgrade_agent = mock.Mock()
        return instance

    def test_a_matching_agent_needs_no_action(self):
        instance = self.compat_app(appmod.APP_VERSION)
        with mock.patch.object(appmod.messagebox, "askyesno") as ask, \
             mock.patch.object(appmod.messagebox, "showerror") as error:
            instance.evaluate_agent_compatibility()
        self.assertFalse(instance.agent_outdated)
        self.assertFalse(instance.agent_too_new)
        ask.assert_not_called()
        error.assert_not_called()
        instance.upgrade_agent.assert_not_called()

    def test_an_unreadable_agent_version_is_not_treated_as_a_mismatch(self):
        instance = self.compat_app("")
        with mock.patch.object(appmod.messagebox, "askyesno") as ask:
            instance.evaluate_agent_compatibility()
        self.assertFalse(instance.agent_outdated)
        self.assertFalse(instance.agent_too_new)
        ask.assert_not_called()

    def test_an_older_agent_is_offered_an_upgrade_once(self):
        instance = self.compat_app("0.3.0")
        with mock.patch.object(appmod.messagebox, "askyesno", return_value=True) as ask:
            instance.evaluate_agent_compatibility()
        self.assertTrue(instance.agent_outdated)
        ask.assert_called_once()
        instance.upgrade_agent.assert_called_once()
        # A second connect must not nag again unless the user asks for it.
        with mock.patch.object(appmod.messagebox, "askyesno") as ask_again:
            instance.evaluate_agent_compatibility()
        ask_again.assert_not_called()

    def test_declining_the_upgrade_leaves_the_banner_asking(self):
        instance = self.compat_app("0.3.0")
        with mock.patch.object(appmod.messagebox, "askyesno", return_value=False):
            instance.evaluate_agent_compatibility()
        instance.upgrade_agent.assert_not_called()
        self.assertTrue(instance.agent_outdated)
        self.assertIn("0.3.0", instance.setup_hint_var.get())

    def test_a_newer_agent_blocks_every_mutation(self):
        instance = self.compat_app("9.9.9")
        with mock.patch.object(appmod.messagebox, "showerror") as error:
            instance.evaluate_agent_compatibility()
        self.assertTrue(instance.agent_too_new)
        error.assert_called_once()
        instance.upgrade_agent.assert_not_called()

        instance.require_client = mock.Mock()
        instance.confirm_important = mock.Mock(return_value=True)
        instance.selected_wifi = mock.Mock(return_value=record())
        instance.render_wifi = mock.Mock()
        instance.records = [record()]
        with mock.patch.object(appmod.messagebox, "showerror") as blocked:
            instance.save_apply()
            instance.delete_wifi()
            instance.create_backup()
        self.assertEqual(blocked.call_count, 3)
        instance.require_client.assert_not_called()
        self.assertEqual(instance.records, [record()])

    def test_upgrade_uploads_the_console_package_and_reconnects(self):
        instance = self.compat_app("0.3.0")
        # compat_app() stubs upgrade_agent; this test drives the real one.
        instance.upgrade_agent = appmod.NativeApp.upgrade_agent.__get__(instance)
        agent = mock.Mock()
        agent.update.return_value = {"ok": True, "from": "0.3.0", "to": appmod.APP_VERSION}
        instance.require_client = lambda: agent
        instance.connect = mock.Mock()
        synchronous_run_task(instance)
        package = Path(tempfile.mkdtemp()) / f"sbproxy-update-{appmod.APP_VERSION}.tar.gz"
        package.write_bytes(b"tarball")
        with mock.patch.object(appmod, "build_update_package", return_value=package), \
             mock.patch.object(appmod.messagebox, "showinfo"):
            instance.upgrade_agent()
        agent.update.assert_called_once_with(b"tarball")
        instance.connect.assert_called_once()
        self.assertFalse(instance.agent_outdated)

    def test_upgrade_refuses_to_push_an_older_console(self):
        instance = self.compat_app("9.9.9")
        instance.upgrade_agent = appmod.NativeApp.upgrade_agent.__get__(instance)
        agent = mock.Mock()
        instance.require_client = lambda: agent
        with mock.patch.object(appmod.messagebox, "showinfo") as info:
            instance.upgrade_agent()
        info.assert_called_once()
        agent.update.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
