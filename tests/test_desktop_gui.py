#!/usr/bin/env python3
"""Tk smoke tests; automatically skipped when CI has no graphical display."""

from __future__ import annotations

from pathlib import Path
import sys
import tkinter as tk
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))
import main as appmod  # noqa: E402


def widget_texts(widget):
    values = []
    try:
        value = widget.cget("text")
        if isinstance(value, str) and value:
            values.append(value)
    except (tk.TclError, AttributeError):
        pass
    if isinstance(widget, appmod.ttk.Notebook):
        values.extend(widget.tab(tab, "text") for tab in widget.tabs())
    if isinstance(widget, appmod.ttk.Treeview):
        values.extend(widget.heading(column, "text") for column in widget["columns"])
    for child in widget.winfo_children():
        values.extend(widget_texts(child))
    return values


class DesktopGuiSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.root = tk.Tk()
            cls.root.withdraw()
        except tk.TclError as exc:
            raise unittest.SkipTest(f"Tk display unavailable: {exc}")
        with mock.patch.object(appmod, "load_connection", return_value=(appmod.DEFAULT_BASE, "")), mock.patch.object(appmod, "load_preferences", return_value=("en", "dark")):
            cls.app = appmod.NativeApp(cls.root)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "root"):
            cls.root.destroy()

    def set_mode(self, language, theme):
        self.app.language = language
        self.app.theme = theme
        self.app.palette = appmod.PALETTES[theme]
        self.app.language_var.set("English" if language == "en" else "Tiếng Việt")
        self.app.theme_var.set("Dark" if theme == "dark" else "Light")
        self.app.t = lambda value, **kw: appmod.translate(value, language, **kw)
        self.app._rebuild_ui()
        self.root.update_idletasks()

    def test_all_language_theme_combinations_render(self):
        for language in ("en", "vi"):
            for theme in ("dark", "light"):
                with self.subTest(language=language, theme=theme):
                    self.set_mode(language, theme)
                    texts = widget_texts(self.root)
                    expected = ("Devices", "Language", "Theme") if language == "en" else ("Thiết bị", "Ngôn ngữ", "Giao diện")
                    self.assertTrue(all(label in texts for label in expected))
                    gateway_title = "INTERNET GATEWAY" if language == "en" else "CỔNG RA INTERNET"
                    self.assertIn(gateway_title, texts)
                    self.assertEqual(
                        self.app.gateway_state_var.get(),
                        "● Gateway not checked" if language == "en" else "● Internet chưa kiểm tra",
                    )
                    self.assertEqual(
                        self.app.gateway_link_var.get(),
                        "Link/DNS: —" if language == "en" else "Kết nối/DNS: —",
                    )
                    self.assertEqual(self.root.cget("background").lower(), appmod.PALETTES[theme]["bg"].lower())

    def test_language_and_theme_handlers_persist(self):
        self.set_mode("en", "dark")
        with mock.patch.object(appmod, "save_preferences") as save:
            self.app.language_var.set("Tiếng Việt")
            self.app._on_language_changed()
            save.assert_called_with("vi", "dark")
        with mock.patch.object(appmod, "save_preferences") as save:
            self.app.theme_var.set("Light")
            self.app._on_theme_changed()
            save.assert_called_with("vi", "light")

    def test_wifi_item_actions_use_context_menu(self):
        self.set_mode("en", "dark")
        self.assertEqual(set(self.app.wifi_edit_buttons), {"edit", "delete"})
        self.assertEqual(
            [self.app.wifi_context_menu.entrycget(index, "label") for index in (0, 1, 2, 4)],
            ["Edit configuration", "Change SOCKS", "Random MAC", "Delete SSID"],
        )

    def test_tabs_use_chrome_style_rounded_surfaces(self):
        style = appmod.ttk.Style(self.root)
        for theme in ("dark", "light"):
            with self.subTest(theme=theme):
                self.set_mode("en", theme)
                font = str(style.lookup("Chrome.TNotebook.Tab", "font"))
                padding = str(style.lookup("Chrome.TNotebook.Tab", "padding"))
                backgrounds = dict(style.map("Chrome.TNotebook.Tab", "background"))
                foregrounds = dict(style.map("Chrome.TNotebook.Tab", "foreground"))
                self.assertNotIn("Semibold", font)
                self.assertIn("9", font)
                self.assertIn("18", padding)
                self.assertEqual(self.app.tabs.cget("style"), "Chrome.TNotebook")
                self.assertEqual(style.lookup("Chrome.TNotebook", "background"), appmod.PALETTES[theme]["tab_strip"])
                self.assertEqual(backgrounds.get("selected"), appmod.PALETTES[theme]["tab_selected"])
                self.assertEqual(backgrounds.get("active"), appmod.PALETTES[theme]["tab_hover"])
                self.assertEqual(foregrounds.get("selected"), appmod.PALETTES[theme]["tab_selected_text"])
                layout = style.layout("Chrome.TNotebook.Tab")
                self.assertEqual(layout[0][0], f"Chrome.{theme}.tab")
                image = self.app._style_images[theme]["selected"]
                self.assertTrue(image.transparency_get(0, 0))
                self.assertFalse(image.transparency_get(image.width() // 2, 0))

    def test_tables_have_borders_headers_and_zebra_rows(self):
        style = appmod.ttk.Style(self.root)
        for theme in ("dark", "light"):
            with self.subTest(theme=theme):
                self.set_mode("en", theme)
                palette = appmod.PALETTES[theme]
                self.assertEqual(str(style.lookup("Treeview", "borderwidth")), "1")
                self.assertEqual(style.lookup("Treeview", "bordercolor"), palette["table_border"])
                self.assertEqual(str(style.lookup("Treeview.Heading", "borderwidth")), "1")
                self.assertEqual(style.lookup("Treeview.Heading", "bordercolor"), palette["table_header_border"])
                for tree in (self.app.wifi_tree, self.app.client_tree):
                    self.assertEqual(tree.tag_configure("row_even")["background"], palette["table_row_even"])
                    self.assertEqual(tree.tag_configure("row_odd")["background"], palette["table_row_odd"])

    def test_all_table_headers_and_cells_are_centered(self):
        for language in ("en", "vi"):
            with self.subTest(language=language):
                self.set_mode(language, "dark")
                for tree in (self.app.wifi_tree, self.app.client_tree):
                    for column in tree["columns"]:
                        self.assertEqual(str(tree.heading(column, "anchor")), "center")
                        self.assertEqual(str(tree.column(column, "anchor")), "center")

    def test_wifi_table_assigns_alternating_row_tags(self):
        original_records = self.app.records
        original_health = self.app.health
        original_runtime = self.app.runtime_ssids
        try:
            self.app.records = [
                appmod.WifiRecord("one", "2g", 1, "password12", "proxy", 1080),
                appmod.WifiRecord("two", "5g", 2, "password12", "proxy", 1080),
            ]
            self.app.health = {}
            self.app.runtime_ssids = {}
            self.app.render_wifi()
            self.assertIn("row_even", self.app.wifi_tree.item("1", "tags"))
            self.assertIn("row_odd", self.app.wifi_tree.item("2", "tags"))
        finally:
            self.app.records = original_records
            self.app.health = original_health
            self.app.runtime_ssids = original_runtime
            self.app.render_wifi()

    def test_every_table_heading_is_sortable_and_shows_direction(self):
        self.set_mode("en", "dark")
        for tree in (self.app.wifi_tree, self.app.client_tree):
            for column in tree["columns"]:
                with self.subTest(table=str(tree), column=column):
                    self.assertTrue(tree.heading(column, "command"))

        original_records = self.app.records
        original_health = self.app.health
        original_runtime = self.app.runtime_ssids
        try:
            self.app.records = [
                appmod.WifiRecord("Zulu", "2g", 2, "password12", "proxy", 9000),
                appmod.WifiRecord("alpha", "5g", 10, "password12", "proxy", 1080),
            ]
            self.app.health = {}
            self.app.runtime_ssids = {}
            self.app.wifi_sort_column = "idx"
            self.app.wifi_sort_reverse = False

            self.app.sort_wifi("name")
            self.assertEqual(self.app.wifi_tree.get_children(), ("10", "2"))
            self.assertTrue(self.app.wifi_tree.heading("name", "text").endswith("▲"))

            self.app.sort_wifi("name")
            self.assertEqual(self.app.wifi_tree.get_children(), ("2", "10"))
            self.assertTrue(self.app.wifi_tree.heading("name", "text").endswith("▼"))
        finally:
            self.app.records = original_records
            self.app.health = original_health
            self.app.runtime_ssids = original_runtime
            self.app.wifi_sort_column = "idx"
            self.app.wifi_sort_reverse = False
            self.app.render_wifi()

    def test_primary_dialogs_render_in_both_languages(self):
        record = appmod.WifiRecord("test1", "2g", 1, "password12", "proxy", 1080)
        for language, palette, expected in (
            ("en", appmod.LIGHT_PALETTE, ("Edit Wi-Fi", "Cancel", "Save")),
            ("vi", appmod.DARK_PALETTE, ("Sửa Wi‑Fi", "Huỷ", "Lưu")),
        ):
            with self.subTest(language=language):
                dialogs = [
                    appmod.WifiDialog(self.root, record, 2, language, palette),
                    appmod.RandomMacDialog(self.root, record, "50:c7:bf:11:22:33", language, palette),
                    appmod.ManualBanDialog(self.root, [record], language, palette),
                    appmod.LoadingWindow(self.root, "test", 5, language, palette),
                ]
                texts = []
                for dialog in dialogs:
                    texts.extend(widget_texts(dialog))
                titles = [dialog.title() for dialog in dialogs]
                self.assertTrue(all(value in texts or value in titles for value in expected))
                for dialog in reversed(dialogs):
                    if hasattr(dialog, "close"):
                        dialog.close()
                    elif dialog.winfo_exists():
                        dialog.destroy()


class SetupWizardGuiTests(unittest.TestCase):
    """The post-flash screens must render and gate on the saved token."""

    @classmethod
    def setUpClass(cls):
        try:
            cls.root = tk.Tk()
            cls.root.withdraw()
        except tk.TclError as exc:
            raise unittest.SkipTest(f"Tk display unavailable: {exc}")

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "root"):
            cls.root.destroy()

    def build_app(self, token):
        with mock.patch.object(appmod, "load_connection", return_value=(appmod.DEFAULT_BASE, token)),              mock.patch.object(appmod, "load_preferences", return_value=("en", "dark")),              mock.patch.object(appmod.NativeApp, "connect"):
            app = appmod.NativeApp(self.root)
        self.root.update_idletasks()
        return app

    def test_the_setup_bar_appears_only_without_a_token(self):
        app = self.build_app("")
        self.assertEqual(app.setup_bar.winfo_manager(), "pack")
        self.assertIn("ROUTER NOT CONFIGURED", widget_texts(app.setup_bar))
        app.token_var.set("0123456789abcdef0123")
        app.update_setup_banner()
        self.root.update_idletasks()
        self.assertEqual(app.setup_bar.winfo_manager(), "")

    def test_a_saved_token_starts_the_tool_immediately(self):
        with mock.patch.object(appmod, "load_connection", return_value=(appmod.DEFAULT_BASE, "0123456789abcdef0123")),              mock.patch.object(appmod, "load_preferences", return_value=("en", "dark")),              mock.patch.object(appmod.NativeApp, "connect") as connect:
            app = appmod.NativeApp(self.root)
            self.root.update()
            self.root.after(400, self.root.quit)
            self.root.mainloop()
        self.assertEqual(app.setup_bar.winfo_manager(), "")
        connect.assert_called()

    def test_the_wizard_renders_every_step_in_both_languages(self):
        settings = appmod.ProvisionSettings(host="192.168.8.1", payload=str(ROOT))
        for language, expected in (("en", "Fetch the agent token"), ("vi", "Lấy token agent")):
            with self.subTest(language=language):
                wizard = appmod.SetupWizard(self.root, settings, language, appmod.DARK_PALETTE)
                self.root.update_idletasks()
                rows = [wizard.steps_tree.item(item, "values") for item in wizard.steps_tree.get_children()]
                self.assertEqual(len(rows), len(settings and appmod.ProvisionRunner(settings).steps))
                self.assertIn(expected, [row[1] for row in rows])
                wizard.set_step(0, appmod.STEP_OK, "OpenWrt 24.10")
                self.assertIn("OpenWrt 24.10", wizard.steps_tree.item("0", "values")[2])
                wizard.close()

    def test_a_finished_wizard_hands_the_token_to_the_app(self):
        app = self.build_app("")
        with mock.patch.object(appmod, "save_connection") as save,              mock.patch.object(appmod.NativeApp, "connect") as connect:
            app.adopt_token("http://192.168.8.1", "0123456789abcdef0123")
        save.assert_called_with("http://192.168.8.1", "0123456789abcdef0123")
        connect.assert_called_once()
        self.root.update_idletasks()
        self.assertEqual(app.setup_bar.winfo_manager(), "")
        self.assertEqual(app.token_var.get(), "0123456789abcdef0123")
    def test_a_first_run_without_a_token_opens_the_ssh_form_itself(self):
        """No token means the SSH form is the only useful action: show it."""
        with mock.patch.object(appmod, "load_connection", return_value=(appmod.DEFAULT_BASE, "")),              mock.patch.object(appmod, "load_preferences", return_value=("en", "dark")),              mock.patch.object(appmod.NativeApp, "connect"),              mock.patch.object(appmod.NativeApp, "check_router_state"),              mock.patch.object(appmod, "load_provision_settings",
                               return_value=appmod.ProvisionSettings(payload=str(ROOT))):
            app = appmod.NativeApp(self.root)
            self.root.update()
            self.root.after(1200, self.root.quit)
            self.root.mainloop()
        try:
            self.assertIsNotNone(app.setup_wizard)
            self.assertTrue(app.setup_wizard.winfo_exists())
            labels = widget_texts(app.setup_wizard)
            for field in ("Router (IP)", "SSH account", "SSH port", "SSH password"):
                self.assertIn(field, labels)
        finally:
            if app.setup_wizard is not None:
                app.setup_wizard.close()

    def test_the_button_reuses_the_open_wizard_instead_of_stacking_windows(self):
        app = self.build_app("")
        with mock.patch.object(appmod, "load_provision_settings",
                               return_value=appmod.ProvisionSettings(payload=str(ROOT))):
            app.open_setup_wizard()
            first = app.setup_wizard
            app.open_setup_wizard()
        try:
            self.assertIs(app.setup_wizard, first)
        finally:
            first.close()
        # A closed wizard must not block a later run.
        with mock.patch.object(appmod, "load_provision_settings",
                               return_value=appmod.ProvisionSettings(payload=str(ROOT))):
            app.open_setup_wizard()
        self.assertIsNot(app.setup_wizard, first)
        app.setup_wizard.close()

    def test_a_wizard_that_cannot_be_built_reports_instead_of_dying_silently(self):
        app = self.build_app("")
        with mock.patch.object(appmod, "load_provision_settings", side_effect=OSError("config unreadable")),              mock.patch.object(appmod.messagebox, "showerror") as error:
            app.open_setup_wizard()
        error.assert_called_once()
        self.assertIn("config unreadable", error.call_args[0][1])
        self.assertIsNone(app.setup_wizard)


if __name__ == "__main__":
    unittest.main(verbosity=2)
