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

    def test_tabs_use_compact_regular_weight_focus_styles(self):
        style = appmod.ttk.Style(self.root)
        for theme in ("dark", "light"):
            with self.subTest(theme=theme):
                self.set_mode("en", theme)
                font = str(style.lookup("TNotebook.Tab", "font"))
                padding = str(style.lookup("TNotebook.Tab", "padding"))
                backgrounds = dict(style.map("TNotebook.Tab", "background"))
                foregrounds = dict(style.map("TNotebook.Tab", "foreground"))
                self.assertNotIn("Semibold", font)
                self.assertIn("9", font)
                self.assertIn("14", padding)
                self.assertEqual(backgrounds.get("selected"), appmod.PALETTES[theme]["tab_selected"])
                self.assertEqual(backgrounds.get("active"), appmod.PALETTES[theme]["tab_hover"])
                self.assertEqual(foregrounds.get("selected"), appmod.PALETTES[theme]["tab_selected_text"])

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
