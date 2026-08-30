"""Reset everything: the desktop app and the web console must do the same thing.

Both fronts drive the same agent, so for one fixture (two SSIDs, two online
devices, one offline) the *sequence of agent calls* must be identical, and
both must refuse in the same ways (declined warning, wrong typed word).

The web side runs the real `resetEverything` function, cut out of
control-panel.html, under Node with a recording `api`; the desktop side runs
`NativeApp.reset_everything` with a recording client. The two transcripts are
then compared verbatim.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "console" / "desktop"))
sys.path.insert(0, str(ROOT / "tests"))
import main as appmod  # noqa: E402
from test_desktop_workflows import FakeRoot, bare_app, synchronous_run_task  # noqa: E402

WEB = ROOT / "console" / "web" / "control-panel.html"
NODE = shutil.which("node")

# One fixture for both fronts.
SSIDS = [{"idx": 1, "name": "a"}, {"idx": 2, "name": "b"}]
CLIENTS = [
    {"idx": 1, "mac": "aa:bb:cc:dd:ee:01", "online": True},
    {"idx": 2, "mac": "aa:bb:cc:dd:ee:02", "online": True},
    {"idx": 2, "mac": "aa:bb:cc:dd:ee:03", "online": False},
]
EXPECTED = [
    "kick:1:aa:bb:cc:dd:ee:01",
    "kick:2:aa:bb:cc:dd:ee:02",
    "pool:1:0",
    "pool:2:0",
    "dryrun:empty-conf",
    "save:empty-conf",
    "apply",
]


def conf_shape(text: str) -> str:
    """'empty-conf' when only comment/blank lines remain — the headers differ per front."""
    rows = [line for line in str(text).splitlines() if line.strip() and not line.startswith("#")]
    return "empty-conf" if not rows else f"conf:{len(rows)}"


# --- web ---------------------------------------------------------------------

def web_reset_source() -> str:
    html = WEB.read_text(encoding="utf-8")
    start = html.index('const RESET_WORD = "RESET";')
    end = html.index("function pullFromRouter() {", start)
    return html[start:end]


NODE_HARNESS = r"""
const calls = [];
const fixture = %(fixture)s;
let ssids = fixture.ssids.map(s => ({ ...s }));
const agent = { connected: true };
const pick = (en, vi) => vi;
const toast = () => {};
const showLog = () => {};
const poll = () => {};
const save = () => {};
const render = () => {};
function genConf() {
  return "# header\n" + ssids.map(s => `${s.name}|5g|${s.idx}`).join("\n") + (ssids.length ? "\n" : "");
}
const confirm = () => fixture.confirm;
const prompt = () => fixture.typed;
function shape(text) {
  const rows = String(text).split("\n").filter(l => l.trim() && !l.startsWith("#"));
  return rows.length ? `conf:${rows.length}` : "empty-conf";
}
function api(action, method, body) {
  switch (action) {
    case "clients": return Promise.resolve({ ok: true, clients: fixture.clients });
    case "kick": calls.push(`kick:${body.idx}:${body.mac}`); return Promise.resolve({ ok: true });
    case "save_pool": calls.push(`pool:${body.idx}:${body.proxies.length}`); return Promise.resolve({ ok: true });
    case "dryrun_conf": calls.push(`dryrun:${shape(body)}`); return Promise.resolve({ ok: true });
    case "save_conf": calls.push(`save:${shape(body)}`); return Promise.resolve({ ok: true });
    case "apply": calls.push("apply"); return Promise.resolve({ ok: true, log: "APPLY COMPLETE" });
    default: throw new Error("unexpected action " + action);
  }
}
%(source)s
resetEverything();
setTimeout(() => console.log(JSON.stringify({ calls, ssids: ssids.length })), 50);
"""


def run_web(confirm=True, typed="RESET"):
    fixture = {"ssids": SSIDS, "clients": CLIENTS, "confirm": confirm, "typed": typed}
    script = NODE_HARNESS % {"fixture": json.dumps(fixture), "source": web_reset_source()}
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "reset.js")
        Path(path).write_text(script, encoding="utf-8")
        out = subprocess.run([NODE, path], capture_output=True, text=True, timeout=30, check=True)
    return json.loads(out.stdout.strip().splitlines()[-1])


# --- desktop ------------------------------------------------------------------

def run_desktop(confirm=True, typed="RESET"):
    instance = bare_app("vi")
    calls = []
    client = mock.Mock()
    client.client_action.side_effect = lambda action, idx, mac: calls.append(f"{action}:{idx}:{mac}") or {"ok": True}
    client.save_pool.side_effect = lambda idx, rows: calls.append(f"pool:{idx}:{len(rows)}") or {"ok": True}
    client.dryrun_conf.side_effect = lambda content: calls.append(f"dryrun:{conf_shape(content)}") or {"ok": True}
    client.save_conf.side_effect = lambda content: calls.append(f"save:{conf_shape(content)}") or {"ok": True}
    client.apply.side_effect = lambda: calls.append("apply") or {"ok": True, "log": "APPLY COMPLETE"}
    instance.client = client
    instance.records = [
        appmod.WifiRecord(name=s["name"], band="5g", idx=s["idx"], wifi_password="password12",
                          host="1.1.1.1", port=1080) for s in SSIDS
    ]
    instance.clients_data = [dict(c) for c in CLIENTS]
    instance.pool_cache, instance.pool_counts = {}, {}
    instance.block_if_incompatible = lambda: False
    instance.append_log = mock.Mock()
    instance.refresh_all = mock.Mock()
    instance.root = FakeRoot(immediate=True)
    instance.hide_loading = mock.Mock()
    instance.update_loading = mock.Mock()
    instance.confirm_important = mock.Mock(return_value=confirm)
    synchronous_run_task(instance)
    with mock.patch.object(appmod.simpledialog, "askstring", return_value=typed):
        instance.reset_everything()
    return {"calls": calls, "ssids": len(instance.records)}


@unittest.skipUnless(NODE, "node is not installed; the web half of the parity check cannot run")
class ResetParityTests(unittest.TestCase):
    def test_the_web_function_is_still_where_the_harness_cuts_it(self):
        source = web_reset_source()
        self.assertIn("function resetEverything()", source)
        self.assertNotIn("function pullFromRouter", source)

    def test_both_fronts_issue_the_same_agent_calls(self):
        web, desktop = run_web(), run_desktop()
        self.assertEqual(web["calls"], EXPECTED)
        self.assertEqual(desktop["calls"], EXPECTED)
        self.assertEqual(web["calls"], desktop["calls"])
        self.assertEqual((web["ssids"], desktop["ssids"]), (0, 0), "both must clear their local SSID list")

    def test_both_fronts_refuse_a_wrong_word_identically(self):
        for typed in ("", "nope", "RESE", None):
            with self.subTest(typed=typed):
                web, desktop = run_web(typed=typed), run_desktop(typed=typed)
                self.assertEqual(web["calls"], [])
                self.assertEqual(desktop["calls"], [])
                self.assertEqual((web["ssids"], desktop["ssids"]), (2, 2))

    def test_both_fronts_accept_the_word_case_and_space_insensitively(self):
        for typed in (" reset ", "Reset", "RESET\n"):
            with self.subTest(typed=typed):
                self.assertEqual(run_web(typed=typed)["calls"], EXPECTED)
                self.assertEqual(run_desktop(typed=typed)["calls"], EXPECTED)

    def test_both_fronts_stop_at_a_declined_warning_before_asking_the_word(self):
        self.assertEqual(run_web(confirm=False)["calls"], [])
        self.assertEqual(run_desktop(confirm=False)["calls"], [])

    def test_both_fronts_carry_the_same_warning_facts(self):
        """Counts of SSIDs, pools and devices, the backup note, and 'cannot be undone'."""
        html = WEB.read_text(encoding="utf-8")
        py = (ROOT / "console" / "desktop" / "main.py").read_text(encoding="utf-8")
        for needle in ("Xoá TẤT CẢ", "pre-apply", "Không hoàn tác được", "Gõ RESET"):
            self.assertTrue(re.search(needle.replace("RESET", r"(RESET|\$\{RESET_WORD\}|\{word\})"), html), needle)
            self.assertTrue(re.search(needle.replace("RESET", r"(RESET|\{word\})"), py), needle)


if __name__ == "__main__":
    unittest.main()
