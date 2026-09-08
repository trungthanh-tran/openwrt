"""A non-JSON answer from the router must explain itself.

The console reached a router whose agent CGI was not installed. uhttpd replied
with its own plain-text "Unable to launch the requested CGI program", the
console called `.json()` on it, and the operator was shown the browser's
`Unexpected token 'U', "Unable to "... is not valid JSON` -- a message that
names neither the router, the status code, nor the fix. The parsing helpers are
cut out of control-panel.html and run under Node so the wording is checked
against real bodies rather than by reading the source.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / "console" / "web" / "control-panel.html"
NODE = shutil.which("node")

# The console used to be one HTML file with its CSS and JS inline. Both are now
# separate files shared by every page, so a test that only searches for a string
# looks at all three rather than guessing which one it landed in.
def console_source() -> str:
    return "\n".join(
        p.read_text(encoding="utf-8")
        for p in (PANEL, PANEL.with_name("app.css"), PANEL.with_name("app.js"))
    )


def reader_source() -> str:
    """agentBodyError + readJson, from the comment block to readJson's brace."""
    text = PANEL.with_name("app.js").read_text(encoding="utf-8")
    start = text.index("  // Every answer from the agent is JSON")
    end = text.index("\n  }\n", text.index("function readJson", start)) + len("\n  }\n")
    return text[start:end]


HARNESS = r"""
// The console picks English or Vietnamese; both must be answered.
let LANG = "en";
const pick = (en, vi) => (LANG === "en" ? en : vi);

// Just enough of fetch's Response for the reader.
const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, text: () => Promise.resolve(body) });

%(reader)s

const CGI_MISSING = "Unable to launch the requested CGI program: /www/cgi-bin/sbproxy: No such file or directory";

const out = {};
const record = (name, res) => readJson(res).then(
  data => { out[name] = { ok: true, data }; },
  err  => { out[name] = { ok: false, message: err.message }; });

Promise.resolve()
  .then(() => record("cgi_missing", reply(500, CGI_MISSING)))
  .then(() => record("not_found", reply(404, "<html><body>Not Found</body></html>")))
  .then(() => record("empty", reply(502, "")))
  .then(() => record("html", reply(200, "<html><head><title>Login</title></head></html>")))
  .then(() => record("good", reply(200, JSON.stringify({ ok: true, token: "t" }))))
  .then(() => record("json_error", reply(401, JSON.stringify({ ok: false, error: "sai mat khau" }))))
  .then(() => { LANG = "vi"; return record("cgi_missing_vi", reply(500, CGI_MISSING)); })
  .then(() => { LANG = "vi"; return record("html_vi", reply(500, "boom")); })
  .then(() => console.log(JSON.stringify(out)));
"""


@unittest.skipUnless(NODE, "node is not installed; the agent-answer check cannot run")
class AgentAnswerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = HARNESS % {"reader": reader_source()}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "reader.js")
            Path(path).write_text(script, encoding="utf-8")
            # The messages are Vietnamese; decoding Node's output with the
            # Windows locale codec would corrupt them before the asserts run.
            done = subprocess.run([NODE, path], capture_output=True, text=True,
                                  encoding="utf-8", timeout=30, check=True)
        cls.out = json.loads(done.stdout.strip().splitlines()[-1])

    def test_a_missing_agent_names_the_install_command(self):
        got = self.out["cgi_missing"]
        self.assertFalse(got["ok"])
        self.assertIn("install-agent.sh", got["message"])
        self.assertNotIn("Unexpected token", got["message"])

    def test_a_404_is_read_as_a_missing_agent_too(self):
        self.assertIn("install-agent.sh", self.out["not_found"]["message"])

    def test_an_empty_body_reports_the_status_code(self):
        message = self.out["empty"]["message"]
        self.assertIn("502", message)
        self.assertIn("empty", message.lower())

    def test_an_html_body_is_quoted_back_with_its_status(self):
        message = self.out["html"]["message"]
        self.assertIn("200", message)
        self.assertIn("Login", message, "the operator needs to see what came back")

    def test_json_still_passes_through_untouched(self):
        self.assertTrue(self.out["good"]["ok"])
        self.assertEqual(self.out["good"]["data"], {"ok": True, "token": "t"})

    def test_a_json_error_body_is_returned_not_raised(self):
        """401 answers carry the agent's own message; callers read d.error."""
        got = self.out["json_error"]
        self.assertTrue(got["ok"])
        self.assertEqual(got["data"]["error"], "sai mat khau")

    def test_the_vietnamese_console_gets_vietnamese_errors(self):
        self.assertIn("agent", self.out["cgi_missing_vi"]["message"])
        self.assertIn("kh\u00f4ng ph\u1ea3i JSON", self.out["html_vi"]["message"])


def reason_source() -> str:
    """routerReason, from its comment block to its closing brace."""
    text = PANEL.with_name("app.js").read_text(encoding="utf-8")
    start = text.index("  // What the router said, trimmed")
    end = text.index("\n  }\n", text.index("function routerReason", start)) + len("\n  }\n")
    return text[start:end]


REASON_HARNESS = r"""
let LANG = "en";
const pick = (en, vi) => (LANG === "en" ? en : vi);

%(reason)s

const APPLY_FAILURE = "[sbproxy] Backing up before apply...\n[sbproxy] Wrote /tmp/x\n[sbproxy][ERR] WIFI_COUNTRY must be a two-letter uppercase country code";
const out = {
  from_log: routerReason({ ok: false, rc: 1, log: APPLY_FAILURE }, "fallback"),
  from_error: routerReason({ ok: false, error: "cần POST" }, "fallback"),
  empty: routerReason({ ok: false, log: "" }, "fallback"),
  missing: routerReason(null, "fallback"),
  chatty: routerReason({ log: "line one\nline two\nline three" }, "fallback"),
  long: routerReason({ log: "x".repeat(400) + " failed" }, "fallback"),
  denied: routerReason({ log: "step ok\nFATAL read config: permission denied\ndone" }, "fallback")
};
console.log(JSON.stringify(out));
"""


@unittest.skipUnless(NODE, "node is not installed; the reason check cannot run")
class RouterReasonTests(unittest.TestCase):
    """A failed action must repeat what the router said, not "X failed"."""

    @classmethod
    def setUpClass(cls):
        script = REASON_HARNESS % {"reason": reason_source()}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "reason.js")
            Path(path).write_text(script, encoding="utf-8")
            done = subprocess.run([NODE, path], capture_output=True, text=True,
                                  encoding="utf-8", timeout=30, check=True)
        cls.out = json.loads(done.stdout.strip().splitlines()[-1])

    def test_the_failing_line_is_picked_out_of_a_long_log(self):
        """apply prints progress first and the reason last."""
        self.assertIn("WIFI_COUNTRY", self.out["from_log"])
        self.assertNotIn("Backing up", self.out["from_log"])

    def test_a_cgi_refusal_comes_through(self):
        self.assertEqual(self.out["from_error"], "cần POST")

    def test_a_silent_answer_falls_back(self):
        self.assertEqual(self.out["empty"], "fallback")
        self.assertEqual(self.out["missing"], "fallback")

    def test_a_log_with_no_obvious_failure_shows_its_last_line(self):
        """Where a script stopped is more useful than where it started."""
        self.assertEqual(self.out["chatty"], "line three")

    def test_a_huge_line_is_trimmed_for_the_toast(self):
        self.assertLessEqual(len(self.out["long"]), 241)
        self.assertTrue(self.out["long"].endswith("\u2026"))

    def test_the_permission_error_survives(self):
        self.assertIn("permission denied", self.out["denied"])


class PanelParsesEveryAnswerSafelyTests(unittest.TestCase):
    """No fetch may go straight to .json() again."""

    @classmethod
    def setUpClass(cls):
        cls.text = console_source()

    def test_no_raw_json_parsing_is_left(self):
        self.assertNotIn("r.json()", self.text)
        self.assertNotIn(".then(res => res.json())", self.text)

    def test_the_reader_is_used(self):
        self.assertIn("readJson", self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
