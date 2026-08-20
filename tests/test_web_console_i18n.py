"""Static i18n audit for console/web/control-panel.html.

The web console keeps both languages in one file: static markup is translated at
runtime from EN_TEXT/EN_ATTR/EN_HTML, dynamic strings go through pick(en, vi).
These checks guard the failure modes that are invisible until someone switches
the UI to English: a duplicate map key silently overriding another, a label that
carries a leading icon so it never matches its key, and any new Vietnamese
string added without a translation.
"""
from __future__ import annotations

import html
import re
import unittest
from pathlib import Path

PANEL = Path(__file__).resolve().parents[1] / "console" / "web" / "control-panel.html"

# Vietnamese-specific letters; plain ASCII words need no translation entry.
VIETNAMESE = re.compile(
    "[àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợ"
    "ùúủũụưừứửữựỳýỷỹỵđĐÀÁẢÃẠĂÂÈÉÊÌÍÒÓÔƠÙÚƯỲ]"
)
# Mirrors ICON_PREFIX in the panel: strip a leading icon such as "＋ " or "🔌 ".
ICON_PREFIX = re.compile(r"^[^\w(À-ỹ]*", re.UNICODE)
# Language names are shown in their own language and are never translated.
NEVER_TRANSLATED = {"Tiếng Việt"}


def source() -> str:
    return PANEL.read_text(encoding="utf-8")


def map_keys(text: str, start: str, end: str) -> list[str]:
    block = text[text.index(start):text.index(end)]
    return re.findall(r'"([^"]+)"\s*:', block)


def bare_map_keys(text: str, start: str, end: str) -> set[str]:
    """Keys of an object literal written as identifiers rather than strings."""
    block = text[text.index(start):text.index(end)]
    return set(re.findall(r"^\s*([A-Za-z_$][\w$]*)\s*:", block, re.M))


def strip_calls(script: str, name: str) -> str:
    """Blank out every `name(...)` call, honouring quotes so that parentheses
    inside string literals do not end the span early."""
    out = list(script)
    for match in re.finditer(rf"\b{name}\(", script):
        i = match.end()
        depth, quote, escaped = 1, "", False
        while i < len(script) and depth:
            char = script[i]
            if escaped:
                escaped = False
            elif quote:
                if char == "\\":
                    escaped = True
                elif char == quote:
                    quote = ""
            elif char in "\"'`":
                quote = char
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            if depth:
                out[i] = " " if char != "\n" else "\n"
            i += 1
    return "".join(out)


def static_markup(text: str) -> str:
    """Body markup minus <script>, and minus blocks translated as a whole."""
    body = text[text.index("<body>"):text.index("<script>")]
    return re.sub(r"<div[^>]*data-i18n-(?:html|skip)[^>]*>.*?</div>", "", body, flags=re.S)


def phrase_key(raw: str) -> str:
    return ICON_PREFIX.sub("", html.unescape(raw).strip()).strip()


class WebConsoleI18nTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = source()
        cls.en_text = map_keys(cls.text, "const EN_TEXT = {", "const EN_ATTR")
        cls.en_attr = map_keys(cls.text, "const EN_ATTR = {", "function localizeStatic")
        cls.markup = static_markup(cls.text)

    def test_translation_maps_have_no_duplicate_keys(self):
        # A repeated key silently wins over the earlier one in a JS object
        # literal, so one of the two labels renders with the wrong translation.
        for name, keys in (("EN_TEXT", self.en_text), ("EN_ATTR", self.en_attr)):
            duplicates = sorted({k for k in keys if keys.count(k) > 1})
            self.assertEqual(duplicates, [], f"{name} defines these keys twice: {duplicates}")

    def test_every_static_phrase_has_an_english_translation(self):
        keys = set(self.en_text)
        missing = sorted(
            {phrase_key(t) for t in re.findall(r">([^<>]+)<", self.markup)
             if VIETNAMESE.search(t)}
            - keys - NEVER_TRANSLATED
        )
        self.assertEqual(missing, [], f"static text without an EN_TEXT entry: {missing}")

    def test_every_tooltip_has_an_english_translation(self):
        titles = {t for t in re.findall(r'title="([^"]+)"', self.markup) if VIETNAMESE.search(t)}
        missing = sorted(titles - set(self.en_attr))
        self.assertEqual(missing, [], f"title= without an EN_ATTR entry: {missing}")

    def test_rich_blocks_declare_a_whole_block_translation(self):
        declared = set(re.findall(r'data-i18n-html="([^"]+)"', self.text))
        provided = bare_map_keys(self.text, "const EN_HTML = {", "// Labels carry")
        self.assertTrue(declared, "expected at least one data-i18n-html block")
        self.assertEqual(declared - provided, set(),
                         f"data-i18n-html blocks with no EN_HTML entry: {declared - provided}")

    def test_language_choice_is_persisted_and_restored(self):
        self.assertIn('localStorage.setItem(LANGUAGE_KEY, language)', self.text)
        self.assertIn('localStorage.getItem(LANGUAGE_KEY) === "vi" ? "vi" : "en"', self.text)

    def test_language_switch_rerenders_every_dependent_surface(self):
        switch = self.text[self.text.index("function setLanguage(next)"):]
        switch = switch[:switch.index("\n  }")]
        for call in ("localizeStatic()", "renderVendorOptions()", "render()",
                     "updateConnHint()", "renderVersion()"):
            self.assertIn(call, switch, f"setLanguage must refresh {call}")

    def test_dynamic_strings_do_not_bypass_pick(self):
        """Vietnamese inside the script must always sit in a pick() call.

        Every runtime string the user can see is built in JavaScript, so one
        forgotten pick() leaves a Vietnamese toast or confirm dialog in the
        English UI. Blanking out the pick() spans leaves only the offenders.
        """
        script = self.text[self.text.index("<script>"):]
        # The translation maps legitimately hold Vietnamese as their keys.
        maps = slice(script.index("const EN_TEXT = {"), script.index("function localizeStatic"))
        script = script[:maps.start] + script[maps.stop:]
        remaining = strip_calls(script, "pick")
        offenders = [
            line.strip()[:100] for line in remaining.splitlines()
            if VIETNAMESE.search(line)
            and not line.lstrip().startswith("//")
            # The vendor table stores its display name as data; vendorLabel()
            # translates the one entry that is a phrase rather than a brand.
            and "{ name:" not in line
        ]
        self.assertEqual(offenders, [], f"Vietnamese outside pick(): {offenders}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
