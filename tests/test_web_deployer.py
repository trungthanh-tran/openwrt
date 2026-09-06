#!/usr/bin/env python3
"""Headless tests for the focused Web installer/updater."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))
spec = importlib.util.spec_from_file_location(
    "sbproxy_web_deployer", ROOT / "console" / "deployer" / "web_deployer.py"
)
deployer = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(deployer)


class ConnectionValidationTests(unittest.TestCase):
    def test_accepts_editable_ssh_fields(self):
        self.assertEqual(
            deployer.validate_connection_fields(" router.lan ", " root ", "2222"),
            ("router.lan", "root", 2222),
        )

    def test_rejects_bad_host_user_and_port(self):
        for values in (
            ("http://router", "root", "22"),
            ("router", "root user", "22"),
            ("router", "root", "0"),
            ("router", "root", "abc"),
        ):
            with self.subTest(values=values), self.assertRaises(ValueError):
                deployer.validate_connection_fields(*values)


class DeployerGuiSmokeTests(unittest.TestCase):
    def test_main_window_constructs_with_boolean_variables(self):
        try:
            root = deployer.tk.Tk()
        except deployer.tk.TclError as exc:
            self.skipTest(f"Tk display unavailable: {exc}")
        root.withdraw()
        try:
            with mock.patch.object(
                deployer.core,
                "load_provision_settings",
                return_value=deployer.core.ProvisionSettings(),
            ):
                app = deployer.DeployApp(root)
            root.update_idletasks()
            self.assertFalse(app.show_password.get())
            self.assertTrue(app.open_after.get())
            self.assertGreater(len(app.steps.get_children()), 0)
        finally:
            root.destroy()


class UpdateSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "VERSION").write_text("0.5.20-SNAPSHOT\n", encoding="utf-8")
        self.settings = deployer.core.ProvisionSettings(
            host="192.168.8.1", payload=str(self.root), remote_dir="/root/sbproxy"
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_existing_install_never_applies_wifi(self):
        runner = deployer.WebDeployRunner(self.settings)
        runner.inventory["code"] = True
        with mock.patch.object(deployer.core.ProvisionRunner, "step_apply") as parent_apply:
            result = runner.step_apply()
        parent_apply.assert_not_called()
        self.assertIsInstance(result, deployer.core.Skipped)
        self.assertIn("không apply lại Wi-Fi", result)

    def test_a_failing_preflight_never_blocks_an_update(self):
        """The router keeps its config; the update only refreshes web + agent.

        A settings.sh that preflight rejects used to stop the run before the
        agent was installed, and the web console then answered the login with
        uhttpd's plain-text CGI error instead of JSON.
        """
        runner = deployer.WebDeployRunner(self.settings)
        runner.inventory["code"] = True
        failure = deployer.core.ProvisionError(
            "Chạy preflight: [sbproxy][ERR] WIFI_COUNTRY must be a two-letter uppercase country code"
        )
        with mock.patch.object(deployer.core.ProvisionRunner, "step_preflight", side_effect=failure):
            result = runner.step_preflight()
        self.assertIsInstance(result, deployer.core.Skipped)
        self.assertIn("WIFI_COUNTRY", result)

    def test_a_first_install_still_fails_on_a_bad_configuration(self):
        """Nothing is running yet, so a broken config must stop the wizard."""
        runner = deployer.WebDeployRunner(self.settings)
        runner.inventory["code"] = False
        with mock.patch.object(deployer.core.ProvisionRunner, "step_preflight",
                               side_effect=deployer.core.ProvisionError("preflight failed")):
            with self.assertRaises(deployer.core.ProvisionError):
                runner.step_preflight()

    def test_upload_preserves_all_operator_configuration(self):
        package = self.root / "sbproxy-update-0.5.20-SNAPSHOT.tar.gz"
        package.write_bytes(b"payload")
        runner = deployer.WebDeployRunner(self.settings)
        runner.router_version = "0.5.20-SNAPSHOT"
        commands = []
        with mock.patch.object(runner, "package_payload", return_value=package), \
                mock.patch.object(runner, "upload"), \
                mock.patch.object(runner, "ssh", side_effect=lambda command, *_args, **_kwargs: commands.append(command) or ""), \
                mock.patch.object(deployer.core, "payload_version", return_value="0.5.20-SNAPSHOT"):
            runner.step_push_code()
        command = "\n".join(commands)
        for filename in ("wifi-socks.conf", "proxy-pools.conf", "settings.sh"):
            self.assertIn(filename, command)
        # Config kept from an earlier Windows-side push can still carry CRLF,
        # and the router's shell reads the carriage return as part of every
        # value -- WIFI_COUNTRY="VN" then fails preflight as an invalid code.
        self.assertIn("sed -i 's/\\r$//'", command)


if __name__ == "__main__":
    unittest.main()
