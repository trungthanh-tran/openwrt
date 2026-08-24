#!/usr/bin/env python3
"""Headless tests for the post-flash provisioning sequence.

Nothing here touches a router: every ssh/scp/tar call goes through an injected
fake runner, and the agent probe is stubbed.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))
import main as appmod  # noqa: E402


class FakeRunner:
    """Record every argv and answer with scripted results."""

    def __init__(self, results=None):
        self.calls = []
        self.results = results or {}

    def __call__(self, argv, timeout=600):
        self.calls.append(list(argv))
        for needle, result in self.results.items():
            if any(needle in part for part in argv):
                return result
        return (0, "", "")

    def remote_commands(self):
        return [argv[-1] for argv in self.calls if argv and argv[0] == "ssh"]


def make_settings(tmp: Path, **changes) -> appmod.ProvisionSettings:
    source = tmp / "repo"
    (source / "scripts").mkdir(parents=True, exist_ok=True)
    (source / "agent").mkdir(parents=True, exist_ok=True)
    (source / "VERSION").write_text(f"{appmod.APP_VERSION}\n", encoding="utf-8")
    values = {"host": "192.168.8.1", "payload": str(source)}
    values.update(changes)
    return appmod.ProvisionSettings(**values)


class ProvisionSettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_ssh_command_is_batch_without_a_password(self):
        command = make_settings(self.tmp).ssh_command("uname -a")
        self.assertEqual(command[:3], ["ssh", "-p", "22"])
        self.assertIn("BatchMode=yes", command)
        self.assertEqual(command[-2:], ["root@192.168.8.1", "uname -a"])

    def test_password_swaps_batch_mode_for_an_askpass_prompt(self):
        command = make_settings(self.tmp, password="secret").ssh_command("true")
        self.assertNotIn("BatchMode=yes", command)
        self.assertIn("NumberOfPasswordPrompts=1", command)

    def test_scp_forces_the_legacy_protocol_for_openwrt(self):
        command = make_settings(self.tmp, port=2222).scp_command("local.tar.gz", "/tmp/x.tar.gz")
        self.assertEqual(command[:4], ["scp", "-O", "-P", "2222"])
        self.assertEqual(command[-1], "root@192.168.8.1:/tmp/x.tar.gz")

    def test_validate_rejects_bad_input(self):
        for changes, message in (
            ({"host": ""}, "địa chỉ router"),
            ({"port": 0}, "Port SSH"),
            ({"remote_dir": "sbproxy"}, "tuyệt đối"),
            ({"payload": str(self.tmp / "missing")}, "Không thấy mã nguồn"),
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError) as caught:
                    make_settings(self.tmp, **changes).validate()
                self.assertIn(message, str(caught.exception))

    def test_settings_payload_never_carries_the_password(self):
        payload = make_settings(self.tmp, password="secret").to_payload()
        self.assertNotIn("password", payload)
        self.assertNotIn("secret", json.dumps(payload))


class ProvisionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.settings = make_settings(self.tmp, config_path=str(self.tmp / "wifi-socks.conf"))
        Path(self.settings.config_path).write_text("w1|2g|1|pw|1.2.3.4|1080|||1|1\n", encoding="utf-8")
        self.events = []
        self.saved = []

    def build(self, runner, prober=None, version_reader=None):
        return appmod.ProvisionRunner(
            self.settings,
            emit=lambda index, state, detail: self.events.append((index, state, detail)),
            runner=runner,
            prober=prober or (lambda *_args, **_kwargs: "ok"),
            version_reader=version_reader or (lambda *_args, **_kwargs: appmod.APP_VERSION),
        )

    def run_full(self, runner, prober=None, version_reader=None):
        provisioner = self.build(runner, prober, version_reader)
        with mock.patch.object(appmod, "save_connection", lambda base, token: self.saved.append((base, token))):
            return provisioner.run(), provisioner

    def test_every_step_runs_in_order_and_the_token_is_stored(self):
        runner = FakeRunner({"/etc/sbproxy/token": (0, "0123456789abcdef0123\n", "")})
        ok, provisioner = self.run_full(runner)
        self.assertTrue(ok)
        self.assertEqual(provisioner.token, "0123456789abcdef0123")
        self.assertEqual(self.saved, [("http://192.168.8.1", "0123456789abcdef0123")])
        remote = " ; ".join(runner.remote_commands())
        for expected in ("tar xzf", "scripts/install-deps.sh", "scripts/preflight.sh",
                         "DRYRUN=1 sh scripts/apply.sh", "sh agent/install-agent.sh",
                         "cat /etc/sbproxy/token"):
            self.assertIn(expected, remote)
        self.assertLess(remote.index("scripts/install-deps.sh"), remote.index("sh agent/install-agent.sh"))
        self.assertLess(remote.index("sh agent/install-agent.sh"), remote.index("cat /etc/sbproxy/token"))
        states = [state for _index, state, _detail in self.events if state != appmod.STEP_RUNNING]
        self.assertEqual(len(states), len(provisioner.steps))
        self.assertNotIn(appmod.STEP_FAILED, states)

    def test_config_push_uploads_both_files_when_selected(self):
        self.settings.settings_path = str(self.tmp / "settings.sh")
        Path(self.settings.settings_path).write_text("RADIO_2G=radio0\n", encoding="utf-8")
        runner = FakeRunner({"/etc/sbproxy/token": (0, "0123456789abcdef0123", "")})
        ok, _provisioner = self.run_full(runner)
        self.assertTrue(ok)
        uploads = [argv[-1] for argv in runner.calls if argv and argv[0] == "scp"]
        self.assertIn("root@192.168.8.1:/root/sbproxy/config/wifi-socks.conf", uploads)
        self.assertIn("root@192.168.8.1:/root/sbproxy/config/settings.sh", uploads)

    def test_steps_without_work_report_skipped(self):
        self.settings.config_path = ""
        self.settings.run_apply = False
        runner = FakeRunner({"/etc/sbproxy/token": (0, "0123456789abcdef0123", "")})
        ok, provisioner = self.run_full(runner)
        self.assertTrue(ok)
        labels = [label for label, _function in provisioner.steps]
        skipped = {labels[index] for index, state, _detail in self.events if state == appmod.STEP_SKIPPED}
        self.assertEqual(skipped, {"Đẩy cấu hình wifi-socks.conf", "Chạy apply.sh khởi tạo"})
        self.assertNotIn("sh scripts/apply.sh", " ".join(runner.remote_commands()).replace("DRYRUN=1 sh scripts/apply.sh", ""))

    def installed_router(self, **extra):
        """A router already carrying code, deps, config, agent, and token.

        `same=1` is what the deployed-agent comparison prints when the
        installed CGI/healthd/UI are byte-identical to the pushed code.
        """
        results = {"code=$(": (0, "code=1\nconf=1\ndeps=1\nagent=1\ntoken=1\nrunning=1\n", ""),
                   "same=1;": (0, "same=1", ""),
                   "/etc/sbproxy/token": (0, "0123456789abcdef0123", "")}
        results.update(extra)
        return FakeRunner(results)

    def test_an_already_installed_router_is_not_reinstalled(self):
        runner = self.installed_router()
        ok, provisioner = self.run_full(runner)
        self.assertTrue(ok)
        self.assertTrue(provisioner.inventory["agent"])
        remote = " ; ".join(runner.remote_commands())
        self.assertNotIn("install-deps.sh", remote)
        self.assertNotIn("sh agent/install-agent.sh", remote)
        self.assertEqual([argv for argv in runner.calls if argv and argv[0] == "scp"][1:], [])
        # The token is still read and stored, so the tool opens on it.
        self.assertIn("cat /etc/sbproxy/token", remote)
        self.assertEqual(self.saved, [("http://192.168.8.1", "0123456789abcdef0123")])
        labels = [label for label, _function in provisioner.steps]
        skipped = {labels[index] for index, state, _detail in self.events if state == appmod.STEP_SKIPPED}
        self.assertEqual(
            skipped,
            {"Cài gói phụ thuộc", "Đẩy cấu hình wifi-socks.conf", "Cài / cập nhật agent"},
        )

    def test_explicit_flags_overwrite_what_the_router_already_has(self):
        self.settings.overwrite_config = True
        self.settings.reinstall_agent = True
        runner = self.installed_router()
        ok, _provisioner = self.run_full(runner)
        self.assertTrue(ok)
        remote = " ; ".join(runner.remote_commands())
        self.assertIn("sh agent/install-agent.sh", remote)
        uploads = [argv[-1] for argv in runner.calls if argv and argv[0] == "scp"]
        self.assertIn("root@192.168.8.1:/root/sbproxy/config/wifi-socks.conf", uploads)

    def test_an_agent_older_than_the_pushed_code_is_reinstalled(self):
        # Same inventory, but the deployed CGI/healthd/UI differ from the push.
        runner = self.installed_router(**{"same=1;": (0, "same=0", "")})
        ok, _provisioner = self.run_full(runner)
        self.assertTrue(ok)
        self.assertIn("sh agent/install-agent.sh", " ".join(runner.remote_commands()))

    def test_verification_fails_when_the_agent_reports_another_version(self):
        runner = self.installed_router()
        ok, provisioner = self.run_full(runner, version_reader=lambda *_a, **_k: "0.3.0")
        self.assertFalse(ok)
        index, _state, detail = self.events[-1]
        self.assertEqual(provisioner.steps[index][0], "Kiểm tra agent API")
        self.assertIn("0.3.0", detail)

    def test_the_pushed_version_comes_from_the_package_name(self):
        package = self.tmp / "sbproxy-update-0.9.1.tar.gz"
        package.write_bytes(b"payload")
        self.settings.payload = str(package)
        runner = self.installed_router()
        ok, provisioner = self.run_full(runner, version_reader=lambda *_a, **_k: "0.9.1")
        self.assertTrue(ok)
        self.assertEqual(provisioner.pushed_version, "0.9.1")

    def test_a_newer_router_refuses_an_older_package(self):
        package = self.tmp / "sbproxy-update-0.4.0.tar.gz"
        package.write_bytes(b"payload")
        self.settings.payload = str(package)
        runner = self.installed_router(
            **{"code=$(": (0, "code=1\nconf=1\ndeps=1\nagent=1\ntoken=1\nversion=0.9.0\n", "")}
        )
        ok, provisioner = self.run_full(runner)
        self.assertFalse(ok)
        self.assertEqual(provisioner.router_version, "0.9.0")
        index, _state, detail = self.events[-1]
        self.assertEqual(provisioner.steps[index][0], "Đẩy mã nguồn lên router")
        self.assertIn("0.9.0 > 0.4.0", detail)
        # Nothing was written: the refusal happens before the upload.
        self.assertEqual([argv for argv in runner.calls if argv and argv[0] == "scp"], [])

    def test_an_equal_or_newer_package_is_accepted(self):
        package = self.tmp / "sbproxy-update-0.9.0.tar.gz"
        package.write_bytes(b"payload")
        self.settings.payload = str(package)
        runner = self.installed_router(
            **{"code=$(": (0, "code=1\nconf=1\ndeps=1\nagent=1\ntoken=1\nversion=0.9.0\n", "")}
        )
        ok, _provisioner = self.run_full(runner, version_reader=lambda *_a, **_k: "0.9.0")
        self.assertTrue(ok)

    def test_a_missing_agent_is_installed_even_with_a_stale_token(self):
        runner = self.installed_router(**{"code=$(": (0, "code=1\nconf=1\ndeps=1\nagent=0\ntoken=1\n", "")})
        ok, _provisioner = self.run_full(runner)
        self.assertTrue(ok)
        self.assertIn("sh agent/install-agent.sh", " ".join(runner.remote_commands()))

    def test_a_failed_step_stops_the_sequence(self):
        runner = FakeRunner({"install-deps.sh": (1, "", "opkg: cannot install")})
        ok, provisioner = self.run_full(runner)
        self.assertFalse(ok)
        failed = [(index, detail) for index, state, detail in self.events if state == appmod.STEP_FAILED]
        self.assertEqual(len(failed), 1)
        index, detail = failed[0]
        self.assertEqual(provisioner.steps[index][0], "Cài gói phụ thuộc")
        self.assertIn("opkg: cannot install", detail)
        self.assertEqual(self.saved, [])
        self.assertNotIn("sh agent/install-agent.sh", " ".join(runner.remote_commands()))

    def test_a_missing_local_tool_is_reported_as_a_step_failure(self):
        def runner(argv, timeout=600):
            raise FileNotFoundError(argv[0])
        ok, _provisioner = self.run_full(runner)
        self.assertFalse(ok)
        self.assertIn("Thiếu công cụ ssh", self.events[-1][2])

    def test_a_timeout_is_reported_as_a_step_failure(self):
        def runner(argv, timeout=600):
            raise subprocess.TimeoutExpired(argv, timeout)
        ok, _provisioner = self.run_full(runner)
        self.assertFalse(ok)
        self.assertIn("quá thời gian chờ", self.events[-1][2])

    def test_an_unhealthy_agent_fails_the_last_step(self):
        runner = FakeRunner({"/etc/sbproxy/token": (0, "0123456789abcdef0123", "")})
        ok, provisioner = self.run_full(runner, prober=lambda *_args, **_kwargs: "unauthorized")
        self.assertFalse(ok)
        index, _state, detail = self.events[-1]
        self.assertEqual(provisioner.steps[index][0], "Kiểm tra agent API")
        self.assertIn("Agent chưa trả lời đúng", detail)

    def test_cancel_stops_before_the_next_step(self):
        provisioner = self.build(FakeRunner())
        provisioner.cancel()
        self.assertFalse(provisioner.run())
        self.assertEqual(self.events, [(0, appmod.STEP_FAILED, "Đã dừng theo yêu cầu")])

    def test_a_source_folder_without_scripts_is_rejected(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        self.settings.payload = str(bare)
        ok, _provisioner = self.run_full(FakeRunner())
        self.assertFalse(ok)
        self.assertIn("Thư mục mã nguồn không hợp lệ", self.events[-1][2])

    def test_a_prebuilt_package_is_uploaded_as_is(self):
        package = self.tmp / f"sbproxy-update-{appmod.APP_VERSION}.tar.gz"
        package.write_bytes(b"payload")
        self.settings.payload = str(package)
        runner = FakeRunner({"/etc/sbproxy/token": (0, "0123456789abcdef0123", "")})
        ok, _provisioner = self.run_full(runner)
        self.assertTrue(ok)
        self.assertFalse([argv for argv in runner.calls if argv and argv[0] == "tar"])
        self.assertIn([argv for argv in runner.calls if argv[0] == "scp"][0][-2], str(package))


class RouterInventoryTests(unittest.TestCase):
    def test_the_probe_command_only_reads(self):
        command = appmod.router_inventory_command("/root/sbproxy")
        self.assertIn("/root/sbproxy/config/wifi-socks.conf", command)
        self.assertIn("/etc/sbproxy/token", command)
        for mutation in ("rm ", "cp ", "install", "apply.sh;", "uci set"):
            self.assertNotIn(mutation, command)

    def test_unreported_keys_count_as_absent(self):
        inventory = appmod.parse_router_inventory("code=1\nagent=1\nnoise\n")
        self.assertTrue(inventory["code"])
        self.assertTrue(inventory["agent"])
        self.assertFalse(inventory["conf"])
        self.assertFalse(inventory["token"])
        self.assertEqual(set(inventory), set(appmod.ROUTER_INVENTORY_KEYS))

    def test_the_description_lists_present_and_missing_parts(self):
        text = appmod.describe_router_inventory(
            appmod.parse_router_inventory("code=1\nagent=1\ntoken=1\ndeps=1"), "en"
        )
        self.assertIn("Present: Code on the router", text)
        self.assertIn("Missing: wifi-socks.conf configuration", text)

    def test_every_inventory_label_has_english(self):
        for label in appmod.ROUTER_INVENTORY_LABELS.values():
            with self.subTest(label=label):
                self.assertIn(label, appmod.EN_TRANSLATIONS)


class TokenAndProbeTests(unittest.TestCase):
    def test_parse_router_token_accepts_the_generated_shape(self):
        self.assertEqual(appmod.parse_router_token("0123456789abcdef0123\n"), "0123456789abcdef0123")

    def test_parse_router_token_rejects_noise(self):
        for value in ("", "\n", "short", "cat: can't open '/etc/sbproxy/token'"):
            with self.subTest(value=value):
                with self.assertRaises(appmod.ProvisionError):
                    appmod.parse_router_token(value)

    def _probe_with(self, opener):
        with mock.patch.object(appmod, "urlopen", opener):
            return appmod.probe_router_state("http://192.168.8.1", "token")

    def test_probe_reports_ok_for_a_healthy_agent(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b'{"ok": true}'

        self.assertEqual(self._probe_with(lambda *_a, **_k: Response()), "ok")

    def test_probe_maps_http_and_socket_errors(self):
        def raiser(exc):
            def opener(*_args, **_kwargs):
                raise exc
            return opener

        cases = {
            401: "unauthorized",
            403: "unauthorized",
            404: "absent",
            500: "unreachable",
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                error = HTTPError("http://x", code, "err", {}, None)
                self.assertEqual(self._probe_with(raiser(error)), expected)
        self.assertEqual(self._probe_with(raiser(URLError("no route"))), "unreachable")


class VersionCompatibilityTests(unittest.TestCase):
    def test_comparison_orders_versions_and_rejects_junk(self):
        self.assertEqual(appmod.compare_versions("0.3.0", "0.4.0"), -1)
        self.assertEqual(appmod.compare_versions("0.4.0", "0.4.0"), 0)
        self.assertEqual(appmod.compare_versions("0.10.0", "0.9.9"), 1)
        self.assertEqual(appmod.compare_versions("1.0.0", "0.9.9"), 1)
        for junk in ("", "unknown", "0.4", "0.4.0-rc1", None):
            with self.subTest(junk=junk):
                self.assertIsNone(appmod.compare_versions(junk, "0.4.0"))
                self.assertIsNone(appmod.compare_versions("0.4.0", junk))

    def test_payload_version_reads_names_and_checkouts(self):
        tmp = Path(tempfile.mkdtemp())
        package = tmp / "sbproxy-update-1.2.3.tar.gz"
        package.write_bytes(b"x")
        self.assertEqual(appmod.payload_version(package), "1.2.3")
        self.assertEqual(appmod.payload_version(ROOT), (ROOT / "VERSION").read_text().strip())
        unnamed = tmp / "package.tar.gz"
        unnamed.write_bytes(b"x")
        self.assertEqual(appmod.payload_version(unnamed), "")
        self.assertEqual(appmod.payload_version(tmp / "missing.tar.gz"), "")

    def test_the_app_version_matches_the_repository_version(self):
        self.assertEqual(appmod.APP_VERSION, (ROOT / "VERSION").read_text().strip())

    def test_the_update_endpoint_posts_the_package_as_raw_bytes(self):
        client = appmod.AgentClient("http://192.168.8.1", "token")
        captured = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b'{"ok": true, "from": "0.3.0", "to": "0.4.0"}'

        def fake_urlopen(request, timeout=None):
            captured["url"] = request.full_url
            captured["method"] = request.get_method()
            captured["body"] = request.data
            captured["type"] = request.get_header("Content-type")
            return Response()

        with mock.patch.object(appmod, "urlopen", fake_urlopen):
            result = client.update(b"tarball-bytes")
        self.assertEqual(result["to"], "0.4.0")
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["body"], b"tarball-bytes")
        self.assertEqual(captured["type"], "application/octet-stream")
        self.assertIn("action=update", captured["url"])
        self.assertNotIn("force", captured["url"])

        with mock.patch.object(appmod, "urlopen", fake_urlopen):
            client.update(b"tarball-bytes", force=True)
        self.assertIn("force=1", captured["url"])

    def test_build_update_package_uses_a_package_as_is(self):
        tmp = Path(tempfile.mkdtemp())
        package = tmp / "sbproxy-update-0.4.0.tar.gz"
        package.write_bytes(b"x")
        self.assertEqual(appmod.build_update_package(str(package)), package)

    def test_build_update_package_packs_a_checkout(self):
        package = appmod.build_update_package(str(ROOT))
        self.assertTrue(package.is_file())
        self.assertEqual(appmod.payload_version(package), appmod.APP_VERSION)
        package.unlink()

    def test_build_update_package_rejects_an_invalid_source(self):
        bare = Path(tempfile.mkdtemp())
        with self.assertRaises(appmod.ProvisionError):
            appmod.build_update_package(str(bare))
        with self.assertRaises(appmod.ProvisionError):
            appmod.build_update_package(str(bare / "missing"))


class ProvisionConfigTests(unittest.TestCase):
    def test_settings_round_trip_through_the_config_file(self):
        tmp = Path(tempfile.mkdtemp())
        with mock.patch.object(appmod, "CONFIG_DIR", tmp), \
             mock.patch.object(appmod, "CONFIG_FILE", tmp / "connection.json"):
            settings = appmod.ProvisionSettings(
                host="10.0.0.1", user="admin", port=2222, password="secret",
                payload=str(ROOT), config_path=str(ROOT / "config" / "wifi-socks.conf.example"),
                run_apply=False,
            )
            appmod.save_provision_settings(settings)
            self.assertNotIn("secret", (tmp / "connection.json").read_text(encoding="utf-8"))
            loaded = appmod.load_provision_settings()
        self.assertEqual((loaded.host, loaded.user, loaded.port), ("10.0.0.1", "admin", 2222))
        self.assertEqual(Path(loaded.payload), ROOT)
        self.assertFalse(loaded.run_apply)
        self.assertEqual(loaded.password, "")

    def test_a_stale_stored_payload_falls_back_to_what_is_installed(self):
        tmp = Path(tempfile.mkdtemp())
        with mock.patch.object(appmod, "CONFIG_DIR", tmp), \
             mock.patch.object(appmod, "CONFIG_FILE", tmp / "connection.json"), \
             mock.patch.dict(os.environ, {"SBPROXY_PAYLOAD": ""}):
            appmod.save_provision_settings(
                appmod.ProvisionSettings(host="10.0.0.1", payload=str(tmp / "gone"))
            )
            loaded = appmod.load_provision_settings()
        self.assertEqual(Path(loaded.payload), ROOT)

    def test_find_payload_prefers_an_explicit_override(self):
        tmp = Path(tempfile.mkdtemp())
        package = tmp / "sbproxy-update-0.4.0.tar.gz"
        package.write_bytes(b"x")
        with mock.patch.dict(os.environ, {"SBPROXY_PAYLOAD": str(package)}):
            self.assertEqual(appmod.find_payload(), str(package))

    def test_the_payload_embedded_in_the_executable_wins(self):
        bundle = Path(tempfile.mkdtemp())
        (bundle / "payload").mkdir()
        package = bundle / "payload" / "sbproxy-update-0.4.0.tar.gz"
        package.write_bytes(b"x")
        with mock.patch.dict(os.environ, {"SBPROXY_PAYLOAD": ""}), \
             mock.patch.object(appmod.sys, "_MEIPASS", str(bundle), create=True):
            self.assertEqual(appmod.bundled_payload(), str(package))
            self.assertEqual(appmod.find_payload(), str(package))
            self.assertTrue(appmod.is_bundled_payload(str(package)))
            settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(package))
            # The bundle unpacks to a new path per launch, so it is not stored.
            self.assertEqual(settings.to_payload()["payload"], "")

    def test_without_a_bundle_nothing_is_embedded(self):
        self.assertEqual(appmod.bundled_payload(), "")
        self.assertFalse(appmod.is_bundled_payload("/srv/sbproxy"))

    def test_the_source_checkout_is_found_by_default(self):
        with mock.patch.dict(os.environ, {"SBPROXY_PAYLOAD": ""}):
            self.assertEqual(Path(appmod.find_payload()), ROOT)


class ProvisionTranslationTests(unittest.TestCase):
    def test_every_step_and_state_label_has_english(self):
        settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(ROOT))
        labels = [label for label, _function in appmod.ProvisionRunner(settings).steps]
        labels += list(appmod.STEP_STATE_LABELS.values())
        labels += list(appmod.ROUTER_STATE_LABELS.values())
        for label in labels:
            with self.subTest(label=label):
                self.assertIn(label, appmod.EN_TRANSLATIONS)

    def test_version_handshake_messages_are_translated(self):
        for template in (
            "Agent trên router là v{agent}, cũ hơn console v{app}.",
            "Agent trên router là v{agent}, mới hơn console v{app}. Hãy dùng bản console mới hơn;"
            " console cũ chỉ được phép xem, mọi thao tác thay đổi bị khoá.",
            "Console v{app} cũ hơn agent v{agent} — hãy cập nhật console trước khi thay đổi router.",
            "Đã nâng cấp agent: {old} → {new}",
            "Router đang chạy bản mới hơn gói cài, hãy dùng console mới hơn",
            "Agent vẫn chạy version cũ, hãy chạy lại và tick “Cài lại agent dù đã có”",
        ):
            with self.subTest(template=template[:40]):
                self.assertIn(template, appmod.EN_TRANSLATIONS)

    def test_composed_step_errors_are_translated_on_both_sides(self):
        self.assertEqual(
            appmod.translate("Cài gói phụ thuộc: quá thời gian chờ", "en"),
            "Install dependencies: timed out",
        )


class AskpassTests(unittest.TestCase):
    def test_the_executable_answers_ssh_password_prompts(self):
        written = []
        with mock.patch.dict(os.environ, {"SBPROXY_ASKPASS": "1", "SBPROXY_SSH_PASSWORD": "hunter2"}), \
             mock.patch.object(appmod.os, "write", lambda fd, data: written.append((fd, data))):
            self.assertEqual(appmod.main(), 0)
        self.assertEqual(written, [(1, b"hunter2\n")])

    def test_askpass_falls_back_when_the_build_has_no_stdout_descriptor(self):
        """A windowed PyInstaller build has no sys.stdout and no usable fd 1."""
        stream = io.StringIO()

        def refuse(_fd, _data):
            raise OSError("no descriptor")

        with mock.patch.object(appmod.os, "write", refuse), \
             mock.patch.object(appmod.os, "name", "posix"), \
             mock.patch.object(appmod.sys, "stdout", stream):
            self.assertEqual(appmod.write_askpass_answer("hunter2"), 0)
        self.assertEqual(stream.getvalue(), "hunter2\n")

    def test_askpass_reports_failure_when_nothing_can_be_written(self):
        def refuse(_fd, _data):
            raise OSError("no descriptor")

        with mock.patch.object(appmod.os, "write", refuse), \
             mock.patch.object(appmod.os, "name", "posix"), \
             mock.patch.object(appmod.sys, "stdout", None):
            self.assertEqual(appmod.write_askpass_answer("hunter2"), 1)

    def test_the_password_reaches_ssh_only_through_the_environment(self):
        settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(ROOT), password="hunter2")
        provisioner = appmod.ProvisionRunner(settings)
        env = provisioner._environment()
        self.assertEqual(env["SBPROXY_SSH_PASSWORD"], "hunter2")
        self.assertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
        self.assertNotIn("hunter2", " ".join(settings.ssh_command("true")))
    def test_the_frozen_bootloader_state_never_reaches_the_askpass_child(self):
        """ssh runs the askpass helper, so it must not inherit onefile state.

        With those variables present the PyInstaller bootloader compares its
        parent (ssh) against its own executable and aborts with "Security
        validation failure: parent process has different executable!".
        """
        inherited = {name: "leftover" for name in appmod.PYINSTALLER_CHILD_VARS}
        settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(ROOT), password="hunter2")
        provisioner = appmod.ProvisionRunner(settings)
        with mock.patch.dict(appmod.os.environ, inherited, clear=False):
            env = provisioner._environment()
        for name in appmod.PYINSTALLER_CHILD_VARS:
            with self.subTest(variable=name):
                self.assertNotIn(name, env)
        self.assertEqual(env["PYINSTALLER_RESET_ENVIRONMENT"], "1")
        # The helper ssh is told to run is still this application.
        self.assertTrue(env["SSH_ASKPASS"])

    def test_a_run_without_a_password_is_cleaned_the_same_way(self):
        inherited = {"_PYI_APPLICATION_HOME_DIR": "leftover"}
        settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(ROOT))
        provisioner = appmod.ProvisionRunner(settings)
        with mock.patch.dict(appmod.os.environ, inherited, clear=False):
            env = provisioner._environment()
        self.assertNotIn("_PYI_APPLICATION_HOME_DIR", env)
        self.assertNotIn("SBPROXY_SSH_PASSWORD", env)


if __name__ == "__main__":
    unittest.main()
