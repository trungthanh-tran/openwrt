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


def patch_table_source() -> str:
    """The real function, from its comment block to its closing brace."""
    text = PANEL.read_text(encoding="utf-8")
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
        cls.text = PANEL.read_text(encoding="utf-8")

    def test_the_wifi_table_is_patched(self):
        self.assertIn("patchTable(tb, sorted, s => s.id, wifiRowCells)", self.text)

    def test_the_device_table_is_patched(self):
        self.assertIn("patchTable(box, list, c => deviceKey(c.idx, c.mac)", self.text)

    def test_neither_table_body_is_rebuilt_wholesale(self):
        for target in ('$("devRows").innerHTML = list', "tb.innerHTML = sorted"):
            self.assertNotIn(target, self.text)

    def test_the_page_never_reloads_itself(self):
        self.assertNotIn("location.reload", self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
