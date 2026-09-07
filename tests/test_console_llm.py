#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The optional AI layer over the rule-based assistant.

Three things must hold no matter which provider is chosen: the router's private
details do not leave the machine, the model cannot name a repair that does not
exist, and a model that answers badly degrades into plain text rather than an
exception. Everything here runs offline -- the HTTP call is injected.
"""
import io
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))

import main as appmod  # noqa: E402


class FakeResponse:
    """The object urlopen hands back, reduced to what the client reads."""

    def __init__(self, payload):
        self._raw = json.dumps(payload).encode("utf-8")

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


class Recorder:
    """Stands in for urlopen and keeps the request for inspection."""

    def __init__(self, payload):
        self.payload = payload
        self.request = None

    def __call__(self, request, timeout=None):
        self.request = request
        self.timeout = timeout
        return FakeResponse(self.payload)

    @property
    def sent(self) -> dict:
        return json.loads(self.request.data.decode("utf-8"))

    @property
    def sent_text(self) -> str:
        return self.request.data.decode("utf-8")


REPORT = {
    "ok": False,
    "summary": {"crit": 1, "warn": 1, "info": 0},
    "findings": [
        {"id": "proxy_loopback", "severity": "crit", "ssid": "Nha-Trung-5G",
         "endpoint": "127.0.0.1:1080", "fix": "apply",
         "title": "Proxy trỏ về chính router"},
        {"id": "proxy_fail", "severity": "warn", "ssid": "Nha-Trung-5G",
         "endpoint": "203.0.113.9:1080", "detail": "password=hunter2 bị từ chối"},
    ],
}


class RedactionTests(unittest.TestCase):
    def test_the_wifi_name_never_leaves_the_machine(self):
        sent = json.dumps(appmod.redact_for_llm(REPORT), ensure_ascii=False)
        self.assertNotIn("Nha-Trung-5G", sent)

    def test_the_same_wifi_gets_the_same_label_twice(self):
        clean = appmod.redact_for_llm(REPORT)
        first, second = clean["findings"][0]["ssid"], clean["findings"][1]["ssid"]
        self.assertEqual(first, second)
        self.assertTrue(first.startswith("<ssid-"))

    def test_a_public_proxy_address_is_masked(self):
        clean = appmod.redact_for_llm(REPORT)
        self.assertNotIn("203.0.113.9", json.dumps(clean))
        # The port survives: which port failed is diagnostic, not identifying.
        self.assertTrue(clean["findings"][1]["endpoint"].endswith(":1080"))

    def test_loopback_survives_because_it_is_the_whole_diagnosis(self):
        clean = appmod.redact_for_llm(REPORT)
        self.assertEqual(clean["findings"][0]["endpoint"], "127.0.0.1:1080")

    def test_a_lan_address_is_not_a_secret(self):
        self.assertTrue(appmod._is_private_host("192.168.8.1"))
        self.assertTrue(appmod._is_private_host("10.0.0.4"))
        self.assertFalse(appmod._is_private_host("203.0.113.9"))

    def test_a_password_in_a_detail_line_is_stripped(self):
        clean = appmod.redact_for_llm(REPORT)
        self.assertNotIn("hunter2", json.dumps(clean, ensure_ascii=False))

    def test_the_prompt_carries_the_question_and_the_clean_report(self):
        prompt = appmod.llm_prompt(REPORT, "vì sao wifi không có mạng?")
        self.assertIn("vì sao wifi không có mạng?", prompt)
        self.assertNotIn("Nha-Trung-5G", prompt)
        self.assertIn("proxy_loopback", prompt)


class AnswerParsingTests(unittest.TestCase):
    def test_a_json_answer_is_read(self):
        answer = appmod.parse_llm_answer(
            '{"diagnosis":"proxy sai","steps":["đổi proxy"],"fixes":["apply"]}')
        self.assertEqual(answer["diagnosis"], "proxy sai")
        self.assertEqual(answer["steps"], ["đổi proxy"])
        self.assertEqual(answer["fixes"], ["apply"])

    def test_a_fenced_json_answer_is_read(self):
        answer = appmod.parse_llm_answer('```json\n{"diagnosis":"x","fixes":[]}\n```')
        self.assertEqual(answer["diagnosis"], "x")
        self.assertTrue(answer["structured"])

    def test_prose_is_still_an_answer(self):
        answer = appmod.parse_llm_answer("Router của bạn thiếu quyền net_admin.")
        self.assertIn("net_admin", answer["diagnosis"])
        self.assertEqual(answer["fixes"], [])
        self.assertFalse(answer["structured"])

    def test_an_invented_repair_is_dropped(self):
        answer = appmod.parse_llm_answer(
            '{"diagnosis":"x","fixes":["apply","rm -rf /","reflash_router"]}')
        self.assertEqual(answer["fixes"], ["apply"])

    def test_a_repeated_repair_appears_once(self):
        answer = appmod.parse_llm_answer('{"diagnosis":"x","fixes":["apply","apply"]}')
        self.assertEqual(answer["fixes"], ["apply"])

    def test_every_whitelisted_repair_exists_in_the_router_script(self):
        script = io.open(ROOT / "scripts" / "debug-agent.sh", encoding="utf-8").read()
        body = script[script.index("do_fix()"):]
        for fix in appmod.LLM_FIX_IDS:
            with self.subTest(fix=fix):
                self.assertIn(f"    {fix})", body)


class ProviderTests(unittest.TestCase):
    def test_claude_is_asked_the_anthropic_way(self):
        recorder = Recorder({"content": [{"type": "text", "text": '{"diagnosis":"ok"}'}]})
        answer = appmod.ask_llm("claude", "", "sk-test", REPORT, opener=recorder)
        self.assertEqual(answer["diagnosis"], "ok")
        self.assertEqual(recorder.request.full_url, "https://api.anthropic.com/v1/messages")
        self.assertEqual(recorder.request.headers["X-api-key"], "sk-test")
        self.assertEqual(recorder.request.headers["Anthropic-version"], "2023-06-01")
        self.assertEqual(recorder.sent["model"], appmod.LLM_PROVIDERS["claude"]["model"])

    def test_openai_is_asked_the_chat_completions_way(self):
        recorder = Recorder({"choices": [{"message": {"content": '{"diagnosis":"ok"}'}}]})
        answer = appmod.ask_llm("openai", "gpt-test", "sk-test", REPORT, opener=recorder)
        self.assertEqual(answer["diagnosis"], "ok")
        self.assertEqual(recorder.request.full_url,
                         "https://api.openai.com/v1/chat/completions")
        self.assertEqual(recorder.request.headers["Authorization"], "Bearer sk-test")
        self.assertEqual(recorder.sent["model"], "gpt-test")

    def test_gemini_is_asked_the_generate_content_way(self):
        recorder = Recorder(
            {"candidates": [{"content": {"parts": [{"text": '{"diagnosis":"ok"}'}]}}]})
        answer = appmod.ask_llm("gemini", "gemini-test", "sk-test", REPORT, opener=recorder)
        self.assertEqual(answer["diagnosis"], "ok")
        self.assertIn("models/gemini-test:generateContent", recorder.request.full_url)
        self.assertEqual(recorder.request.headers["X-goog-api-key"], "sk-test")

    def test_the_model_name_travels_back_with_the_answer(self):
        recorder = Recorder({"content": [{"type": "text", "text": "hi"}]})
        answer = appmod.ask_llm("claude", "claude-test", "k", REPORT, opener=recorder)
        self.assertEqual((answer["provider"], answer["model"]), ("claude", "claude-test"))

    def test_no_provider_receives_the_wifi_name(self):
        for provider, payload in (
            ("claude", {"content": [{"type": "text", "text": "x"}]}),
            ("openai", {"choices": [{"message": {"content": "x"}}]}),
            ("gemini", {"candidates": [{"content": {"parts": [{"text": "x"}]}}]}),
        ):
            with self.subTest(provider=provider):
                recorder = Recorder(payload)
                appmod.ask_llm(provider, "", "k", REPORT, opener=recorder)
                self.assertNotIn("Nha-Trung-5G", recorder.sent_text)
                self.assertNotIn("hunter2", recorder.sent_text)

    def test_the_system_prompt_lists_only_real_repairs(self):
        for fix in appmod.LLM_FIX_IDS:
            self.assertIn(fix, appmod.LLM_SYSTEM_PROMPT)

    def test_an_unknown_provider_is_refused(self):
        with self.assertRaises(appmod.LlmError):
            appmod.ask_llm("llama", "", "k", REPORT, opener=Recorder({}))

    def test_a_missing_key_is_refused_before_any_request(self):
        recorder = Recorder({})
        with self.assertRaises(appmod.LlmError):
            appmod.ask_llm("claude", "", "   ", REPORT, opener=recorder)
        self.assertIsNone(recorder.request)

    def test_an_api_error_payload_becomes_an_llm_error(self):
        recorder = Recorder({"error": {"message": "invalid api key"}})
        with self.assertRaises(appmod.LlmError) as caught:
            appmod.ask_llm("openai", "", "k", REPORT, opener=recorder)
        self.assertIn("invalid api key", str(caught.exception))

    def test_an_empty_answer_is_an_error_not_an_empty_page(self):
        recorder = Recorder({"content": []})
        with self.assertRaises(appmod.LlmError):
            appmod.ask_llm("claude", "", "k", REPORT, opener=recorder)

    def test_a_transport_failure_names_the_provider(self):
        def broken(_request, timeout=None):
            raise OSError("no route to host")

        with self.assertRaises(appmod.LlmError) as caught:
            appmod.ask_llm("gemini", "", "k", REPORT, opener=broken)
        self.assertIn("Gemini", str(caught.exception))

    def test_every_provider_offers_a_default_model_and_a_key_page(self):
        for name, spec in appmod.LLM_PROVIDERS.items():
            with self.subTest(provider=name):
                self.assertTrue(spec["model"])
                self.assertTrue(spec["key_url"].startswith("https://"))
                self.assertTrue(spec["label"])


class SettingsTests(unittest.TestCase):
    """The key is stored the way the router token is, and never crashes a read."""

    def setUp(self):
        self.saved = appmod._read_config_payload()

    def tearDown(self):
        appmod._write_config_payload(self.saved)

    def test_a_saved_key_reads_back(self):
        appmod.save_llm_settings("gemini", "gemini-test", "sk-secret")
        self.assertEqual(appmod.load_llm_settings(), ("gemini", "gemini-test", "sk-secret"))

    def test_the_key_is_not_stored_in_the_clear_on_windows(self):
        appmod.save_llm_settings("claude", "", "sk-secret")
        raw = appmod.CONFIG_FILE.read_text(encoding="utf-8")
        if "llm_key_dpapi" in raw:            # sealed: the only shape on Windows
            self.assertNotIn("sk-secret", raw)

    def test_an_unknown_provider_falls_back_to_the_default(self):
        appmod.save_llm_settings("llama", "", "k")
        self.assertEqual(appmod.load_llm_settings()[0], appmod.DEFAULT_LLM_PROVIDER)

    def test_no_saved_model_means_the_provider_default(self):
        appmod.save_llm_settings("openai", "   ", "k")
        self.assertEqual(appmod.load_llm_settings()[1],
                         appmod.LLM_PROVIDERS["openai"]["model"])


class TranslationTests(unittest.TestCase):
    def test_the_assistant_labels_have_english(self):
        for label in ("Trợ lý gỡ lỗi", "Chẩn đoán router", "Hỏi AI", "Lưu khoá",
                      "Đang hỏi mô hình AI…", "Chưa có API key"):
            with self.subTest(label=label):
                self.assertIn(label, appmod.EN_TRANSLATIONS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
