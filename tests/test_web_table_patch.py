"""The console must patch its tables, never rebuild them.

Both tables refresh on a timer — Wi-Fi health every 10 s, devices every 5-60 s.
Rebuilding the whole `<tbody>` on each tick made the table blink, threw away
the scroll position and a text selection, and destroyed a checkbox the operator
had just clicked. A `match` in tests/run.sh cannot prove that a row survived:
only node identity can, so the real `patchTable` is cut out of
control-panel.html and run under Node against a small DOM stand-in that counts
every innerHTML write.
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


def patch_table_source() -> str:
    """The real function, from its comment block to its closing brace."""
    text = PANEL.with_name("app.js").read_text(encoding="utf-8")
    start = text.index("  // Patch a <tbody> from a keyed list")
    end = text.index("\n  }\n", text.index("function patchTable", start)) + len("\n  }\n")
    return text[start:end]


HARNESS = r"""
// --- the smallest DOM patchTable can run against -------------------------
let htmlWrites = 0;
class El {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.parent = null; this.className = ""; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  set innerHTML(v) { htmlWrites++; this._inner = v; }
  get innerHTML() { return this._inner; }
  get firstElementChild() { return this.children[0] || null; }
  get nextElementSibling() {
    if (!this.parent) return null;
    return this.parent.children[this.parent.children.indexOf(this) + 1] || null;
  }
  insertBefore(node, ref) {
    if (node.parent) node.parent.children.splice(node.parent.children.indexOf(node), 1);
    node.parent = this;
    const at = ref ? this.children.indexOf(ref) : this.children.length;
    this.children.splice(at < 0 ? this.children.length : at, 0, node);
    return node;
  }
  remove() {
    if (!this.parent) return;
    this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
}
const document = { createElement: tag => new El(tag) };

%(patch_table)s

// --- the scenario --------------------------------------------------------
const tbody = new El("tbody");
// Whatever placeholder the table starts with ("Loading…") carries no key.
tbody.insertBefore(new El("tr"), null);

const render = rows => patchTable(tbody, rows, r => r.k, r => r.cells, r => r.cls || "");
const ids = () => tbody.children.map(tr => tr.getAttribute("data-key"));
// Identity across renders: same object === the row was never re-created.
const nodes = {};
const snapshot = () => { tbody.children.forEach(tr => { nodes[tr.getAttribute("data-key")] = tr; }); };
const same = key => nodes[key] === tbody.children[ids().indexOf(key)];

const out = {};
render([{ k: "a", cells: "A" }, { k: "b", cells: "B" }, { k: "c", cells: "C" }]);
out.first_render = { keys: ids(), writes: htmlWrites, placeholder_gone: tbody.children.every(t => t.getAttribute("data-key")) };
snapshot();

// 1. An identical payload must touch nothing at all.
htmlWrites = 0;
render([{ k: "a", cells: "A" }, { k: "b", cells: "B" }, { k: "c", cells: "C" }]);
out.unchanged = { writes: htmlWrites, kept: ["a", "b", "c"].every(same), keys: ids() };

// 2. One changed row is rewritten; its neighbours are not.
htmlWrites = 0;
render([{ k: "a", cells: "A" }, { k: "b", cells: "B2" }, { k: "c", cells: "C" }]);
out.one_changed = { writes: htmlWrites, kept: ["a", "b", "c"].every(same), b: tbody.children[1].innerHTML };

// 3. A class-only change (row selected) rewrites no HTML.
htmlWrites = 0;
render([{ k: "a", cells: "A" }, { k: "b", cells: "B2", cls: "selected" }, { k: "c", cells: "C" }]);
out.class_only = { writes: htmlWrites, cls: tbody.children[1].className, kept: same("b") };

// 4. A device that left is removed; the rest keep their nodes.
htmlWrites = 0;
render([{ k: "a", cells: "A" }, { k: "c", cells: "C" }]);
out.removed = { keys: ids(), writes: htmlWrites, kept: ["a", "c"].every(same) };

// 5. Re-sorting moves the existing nodes instead of re-creating them.
htmlWrites = 0;
render([{ k: "c", cells: "C" }, { k: "a", cells: "A" }]);
out.reordered = { keys: ids(), writes: htmlWrites, kept: ["a", "c"].every(same) };

// 6. A new device is inserted in place; the others are still untouched.
htmlWrites = 0;
render([{ k: "c", cells: "C" }, { k: "d", cells: "D" }, { k: "a", cells: "A" }]);
out.inserted = { keys: ids(), writes: htmlWrites, kept: ["a", "c"].every(same) };

console.log(JSON.stringify(out));
"""


@unittest.skipUnless(NODE, "node is not installed; the table-patch check cannot run")
class TablePatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = HARNESS % {"patch_table": patch_table_source()}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "patch.js")
            Path(path).write_text(script, encoding="utf-8")
            done = subprocess.run([NODE, path], capture_output=True, text=True, timeout=30, check=True)
        cls.out = json.loads(done.stdout.strip().splitlines()[-1])

    def test_the_first_render_builds_every_row_and_drops_the_placeholder(self):
        first = self.out["first_render"]
        self.assertEqual(first["keys"], ["a", "b", "c"])
        self.assertEqual(first["writes"], 3)
        self.assertTrue(first["placeholder_gone"], "the keyless placeholder row must be cleared")

    def test_an_unchanged_payload_touches_no_row(self):
        """The poll case: the router reported exactly what is on screen."""
        self.assertEqual(self.out["unchanged"]["writes"], 0)
        self.assertTrue(self.out["unchanged"]["kept"])
        self.assertEqual(self.out["unchanged"]["keys"], ["a", "b", "c"])

    def test_only_the_row_that_changed_is_rewritten(self):
        changed = self.out["one_changed"]
        self.assertEqual(changed["writes"], 1)
        self.assertEqual(changed["b"], "B2")
        self.assertTrue(changed["kept"], "the row keeps its node even when its cells change")

    def test_selecting_a_row_changes_the_class_without_rewriting_cells(self):
        cls = self.out["class_only"]
        self.assertEqual(cls["writes"], 0)
        self.assertEqual(cls["cls"], "selected")
        self.assertTrue(cls["kept"])

    def test_a_departed_row_is_removed_and_the_others_stay(self):
        removed = self.out["removed"]
        self.assertEqual(removed["keys"], ["a", "c"])
        self.assertEqual(removed["writes"], 0)
        self.assertTrue(removed["kept"])

    def test_sorting_moves_nodes_rather_than_re_creating_them(self):
        order = self.out["reordered"]
        self.assertEqual(order["keys"], ["c", "a"])
        self.assertEqual(order["writes"], 0)
        self.assertTrue(order["kept"])

    def test_a_new_row_is_inserted_without_disturbing_the_rest(self):
        ins = self.out["inserted"]
        self.assertEqual(ins["keys"], ["c", "d", "a"])
        self.assertEqual(ins["writes"], 1, "only the new row is rendered")
        self.assertTrue(ins["kept"])


class PanelUsesThePatcherTests(unittest.TestCase):
    """Both timer-driven tables must go through patchTable, not innerHTML."""

    @classmethod
    def setUpClass(cls):
        cls.text = console_source()

    def test_the_wifi_table_is_patched(self):
        self.assertIn("patchTable(tb, sorted, s => s.id, wifiRowCells)", self.text)

    def test_the_device_table_is_patched(self):
        self.assertIn("patchTable(box, list, c => deviceKey(c.idx, c.mac)", self.text)

    def test_neither_table_body_is_rebuilt_wholesale(self):
        for target in ('$("devRows").innerHTML = list', "tb.innerHTML = sorted"):
            self.assertNotIn(target, self.text)

    def test_the_page_never_reloads_itself(self):
        self.assertNotIn("location.reload", self.text)


class RouterBusyStateTests(unittest.TestCase):
    """Applying takes seconds on the router; the page has to say so.

    A toast fades after a moment, which left an operator watching an unchanged
    page wondering whether the router was working or the click had been lost --
    and free to press Apply again into the middle of the first one.
    """

    @classmethod
    def setUpClass(cls):
        cls.text = console_source()

    def test_the_page_has_a_busy_chip(self):
        self.assertIn('id="busyChip"', self.text)
        self.assertIn('id="busyText"', self.text)
        self.assertIn("body.busy .busychip { display: inline-flex; }", self.text)

    def test_a_busy_page_refuses_a_second_write(self):
        self.assertIn("body.busy .side-nav .btn, body.busy .btn.primary, body.busy .btn.danger", self.text)

    def test_every_router_write_raises_and_clears_the_chip(self):
        """Whatever raises it must clear it, on failure as much as on success."""
        self.assertGreaterEqual(self.text.count("busy(pick("), 8,
                                "each step of each router write announces itself")
        # Clearing must be unconditional: a refusal has to hand the page back
        # exactly like a success does.
        self.assertGreaterEqual(self.text.count(".finally(busyDone)"), 6,
                                "each flow clears the chip in a finally")

    def test_the_clearing_always_runs(self):
        for tail in (".finally(busyDone)", "configApplying = false; busyDone();"):
            self.assertIn(tail, self.text)


class EveryWriteReachesTheRouterTests(unittest.TestCase):
    """Wi-Fi, proxy and device actions all take effect on the router at once.

    Nothing in this console is a local edit waiting for a later "push": an
    operator who deletes a Wi-Fi, repoints a proxy or blocks a device expects
    the router to be in that state when the toast fades. Each of these actions
    must therefore go out immediately, behind the progress chip, and report the
    router's own words if it refuses.
    """

    # The action each write uses, and how far back its wrapper may sit.
    WRITES = ("set_sock", "assign_proxy", "rebalance", "rotate_mac", "set_gateway",
              "switch_gateway", "save_pool", "restart_singbox", "debug_fix")

    @classmethod
    def setUpClass(cls):
        cls.text = console_source()

    def test_every_router_write_announces_itself(self):
        for action in self.WRITES:
            with self.subTest(action=action):
                at = self.text.find(f'api("{action}"')
                self.assertNotEqual(at, -1, f"{action} is no longer called")
                window = self.text[max(0, at - 500):at]
                self.assertTrue("routerWrite(" in window or "busy(" in window,
                                f"{action} runs without raising the progress chip")

    def test_device_actions_go_through_the_shared_path(self):
        self.assertIn('routerWrite(verb, () => api(action, "POST", { idx, mac })', self.text)

    def test_wifi_edits_apply_without_a_second_click(self):
        """Add, edit, duplicate, import and delete each end in an apply."""
        self.assertGreaterEqual(self.text.count("autoApplyConfig(previous"), 5)
        self.assertIn("applyConfigText(genConf(), false)", self.text)

    def test_a_refused_write_restores_the_previous_wifi_list(self):
        self.assertIn("ssids = previous; configDirty = true; render();", self.text)


class PlainSkinTests(unittest.TestCase):
    """The console is skinned as a settings page, and both themes still work."""

    @classmethod
    def setUpClass(cls):
        cls.text = console_source()

    def test_dark_is_the_default_and_an_explicit_dark_lands_on_it(self):
        self.assertIn(':root, :root[data-theme="dark"] {', self.text)
        # The older palette also matches [data-theme="dark"]; the skin has to
        # come after it, or choosing dark from the toggle undoes the skin.
        self.assertGreater(self.text.index(':root, :root[data-theme="dark"] {'),
                           self.text.index(':root[data-theme="dark"] {'))

    def test_light_is_still_reachable(self):
        self.assertIn(':root[data-theme="light"] {', self.text)

    def test_the_toggle_reads_an_unset_theme_as_dark(self):
        """Otherwise the first click sets dark on a page that is already dark."""
        self.assertIn('document.documentElement.getAttribute("data-theme") || "dark"', self.text)

    def test_the_add_form_suggests_no_proxy_address(self):
        """127.0.0.1:1080 was a default, and became three routers' live outbound."""
        self.assertNotIn('$("f_host").value = s ? s.host : "127.0.0.1";', self.text)
        self.assertIn('$("f_host").value = "";', self.text)
        self.assertIn('const host = "";', self.text)
        self.assertIn('SSID này chỉ dùng proxy trong Pool', self.text)
        self.assertIn('id="f_subnet"', self.text)
        self.assertIn('local_subnet', self.text)

    def test_the_skin_changes_no_behaviour(self):
        """It is presentation only: no id or handler is renamed by it."""
        for probe in ('id="pushApplyBtn"', 'id="devicesBtn"', 'id="debugBtn"', 'id="busyChip"'):
            self.assertIn(probe, self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
