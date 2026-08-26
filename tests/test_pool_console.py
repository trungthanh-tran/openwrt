#!/usr/bin/env python3
"""Headless tests for the console's proxy-pool logic.

Two pure functions live here: parsing a pasted proxy list, and dealing a set of
devices over that list. Both are shared by the preview the operator sees and by
the request that is then sent, so a disagreement between them would show one
layout and commit another.

No Tk window is created, so this runs anywhere the other core suites run.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "console" / "desktop"
sys.path.insert(0, str(DESKTOP))
import main as app  # noqa: E402


class ParseProxyListTests(unittest.TestCase):
    """Whatever the operator has in their clipboard has to be accepted."""

    def parse(self, text, **kw):
        return app.parse_proxy_list(text, **kw)

    def test_the_scheme_form_genrouter_users_already_have(self):
        rows, dropped = self.parse("socks5://user:pass@1.2.3.4:1080")
        self.assertEqual(rows, [("socks5", "1.2.3.4", 1080, "user", "pass", "")])
        self.assertEqual(dropped, [])

    def test_every_accepted_shape(self):
        rows, _ = self.parse(
            "socks5://user:pass@1.2.3.4:1080\n"
            "http://5.6.7.8:8080\n"
            "user2:pass2@9.9.9.9:1080\n"
            "10.0.0.1:3128:user3:pass3\n"
            "10.0.0.2:1080\n"
        )
        self.assertEqual(rows, [
            ("socks5", "1.2.3.4", 1080, "user", "pass", ""),
            ("http", "5.6.7.8", 8080, "", "", ""),
            ("socks5", "9.9.9.9", 1080, "user2", "pass2", ""),
            ("socks5", "10.0.0.1", 3128, "user3", "pass3", ""),
            ("socks5", "10.0.0.2", 1080, "", "", ""),
        ])

    def test_the_scheme_is_case_insensitive(self):
        rows, _ = self.parse("SOCKS5://1.2.3.4:1080\nHTTP://1.2.3.4:8080")
        self.assertEqual([r[0] for r in rows], ["socks5", "http"])

    def test_socks5h_and_socks_are_both_socks5(self):
        rows, _ = self.parse("socks5h://1.2.3.4:1080\nsocks://1.2.3.4:1081")
        self.assertEqual([r[0] for r in rows], ["socks5", "socks5"])

    def test_a_password_may_contain_an_at_sign(self):
        """Split on the last @, or the host is read out of the password."""
        rows, _ = self.parse("user:p@ss@1.2.3.4:1080")
        self.assertEqual(rows, [("socks5", "1.2.3.4", 1080, "user", "p@ss", "")])

    def test_a_password_may_contain_a_colon(self):
        """Split credentials on the first colon, for the same reason."""
        rows, _ = self.parse("user:pa:ss@1.2.3.4:1080")
        self.assertEqual(rows, [("socks5", "1.2.3.4", 1080, "user", "pa:ss", "")])

    def test_credentials_from_an_at_are_not_overwritten_by_colons(self):
        """host:port:user:pass only applies when no @ already supplied them."""
        rows, dropped = self.parse("user:pass@1.2.3.4:1080:x:y")
        self.assertEqual(rows, [])
        self.assertEqual(len(dropped), 1)

    def test_the_colon_form_without_an_at_is_host_first(self):
        rows, _ = self.parse("1.2.3.4:1080:user:pass")
        self.assertEqual(rows, [("socks5", "1.2.3.4", 1080, "user", "pass", "")])

    def test_a_hostname_is_accepted(self):
        rows, _ = self.parse("proxy.example.com:1080")
        self.assertEqual(rows[0][1], "proxy.example.com")

    def test_blank_lines_and_comments_are_skipped_silently(self):
        rows, dropped = self.parse("\n  \n# a note\n1.2.3.4:1080\n")
        self.assertEqual(len(rows), 1)
        self.assertEqual(dropped, [])

    def test_carriage_returns_survive_a_windows_clipboard(self):
        rows, _ = self.parse("1.2.3.4:1080\r\n5.6.7.8:1080\r\n")
        self.assertEqual(len(rows), 2)

    def test_surrounding_whitespace_is_trimmed(self):
        rows, _ = self.parse("   1.2.3.4:1080   ")
        self.assertEqual(rows[0][1], "1.2.3.4")


class ParseProxyListRejectionTests(unittest.TestCase):
    """A rejected line is reported, never dropped in silence."""

    def parse(self, text, **kw):
        return app.parse_proxy_list(text, **kw)

    def assert_rejected(self, line, reason_fragment):
        rows, dropped = self.parse(line)
        self.assertEqual(rows, [], f"expected {line!r} to be rejected")
        self.assertEqual(len(dropped), 1)
        number, text, reason = dropped[0]
        self.assertEqual(number, 1)
        self.assertEqual(text, line.strip())
        self.assertIn(reason_fragment, reason)

    def test_a_pipe_would_corrupt_the_config_file(self):
        self.assert_rejected("1.2.3.4:1080:us|er:pass", "|")

    def test_a_control_character_is_rejected(self):
        self.assert_rejected("1.2.3.4:1080:us\ter:pass", "ký tự")

    def test_a_missing_port_is_rejected(self):
        self.assert_rejected("1.2.3.4", "cổng")

    def test_a_non_numeric_port_is_rejected(self):
        self.assert_rejected("1.2.3.4:http", "cổng")

    def test_port_zero_is_rejected(self):
        self.assert_rejected("1.2.3.4:0", "cổng")

    def test_a_port_above_65535_is_rejected(self):
        self.assert_rejected("1.2.3.4:65536", "cổng")

    def test_an_empty_host_is_rejected(self):
        self.assert_rejected("user:pass@:1080", "host")

    def test_a_host_with_a_space_is_rejected(self):
        self.assert_rejected("1.2.3.4 evil:1080", "host")

    def test_a_host_with_a_shell_metacharacter_is_rejected(self):
        """Not covered by the whitespace check above, which would mask this."""
        self.assert_rejected("1.2.3.4;rm:1080", "host")

    def test_an_unknown_scheme_is_rejected(self):
        self.assert_rejected("ftp://1.2.3.4:1080", "loại proxy")

    def test_good_lines_survive_alongside_bad_ones(self):
        rows, dropped = self.parse("1.2.3.4:1080\nnonsense\n5.6.7.8:1080")
        self.assertEqual(len(rows), 2)
        self.assertEqual([d[0] for d in dropped], [2])


class ParseProxyListLimitTests(unittest.TestCase):
    def test_duplicates_collapse_keeping_the_first(self):
        rows, dropped = app.parse_proxy_list(
            "1.2.3.4:1080:u:p\n1.2.3.4:1080:u:p\n5.6.7.8:1080")
        self.assertEqual(len(rows), 2)
        self.assertEqual([d[0] for d in dropped], [2])
        self.assertIn("trùng", dropped[0][2])

    def test_a_label_difference_is_still_a_duplicate(self):
        """Identity is the endpoint and its credentials, exactly as in lib.sh."""
        rows, _ = app.parse_proxy_list("1.2.3.4:1080:u:p\nsocks5://u:p@1.2.3.4:1080")
        self.assertEqual(len(rows), 1)

    def test_going_over_the_cap_says_how_many_were_left_out(self):
        text = "\n".join(f"10.0.0.{i}:1080" for i in range(1, 12))
        rows, dropped = app.parse_proxy_list(text, limit=8)
        self.assertEqual(len(rows), 8)
        self.assertEqual(len(dropped), 3)
        self.assertIn("8", dropped[0][2])

    def test_nothing_at_all_is_not_an_error(self):
        self.assertEqual(app.parse_proxy_list(""), ([], []))


class SplitDevicesTests(unittest.TestCase):
    """Dealing devices over slots: even, and reproducible from the seed."""

    def deal(self, devices, slots, seed=1):
        return app.split_devices_evenly(devices, slots, seed=seed)

    def counts(self, mapping, slots):
        return sorted(sum(1 for s in mapping.values() if s == i) for i in range(slots))

    def test_devices_divide_exactly(self):
        macs = [f"aa:bb:cc:dd:ee:{i:02x}" for i in range(6)]
        mapping = self.deal(macs, 3)
        self.assertEqual(self.counts(mapping, 3), [2, 2, 2])
        self.assertEqual(sorted(mapping), sorted(macs))

    def test_a_remainder_differs_by_at_most_one(self):
        for total in (1, 2, 4, 5, 7, 100, 300):
            for slots in (1, 3, 7, 8, 32):
                macs = [f"aa:bb:cc:dd:{i // 256:02x}:{i % 256:02x}" for i in range(total)]
                counts = self.counts(self.deal(macs, slots), slots)
                self.assertLessEqual(counts[-1] - counts[0], 1,
                                     f"{total} devices over {slots} slots: {counts}")

    def test_more_slots_than_devices_gives_each_its_own(self):
        macs = [f"aa:bb:cc:dd:ee:{i:02x}" for i in range(3)]
        mapping = self.deal(macs, 10)
        self.assertEqual(len(set(mapping.values())), 3)

    def test_every_device_appears_exactly_once(self):
        macs = [f"aa:bb:cc:dd:ee:{i:02x}" for i in range(50)]
        mapping = self.deal(macs, 7)
        self.assertEqual(len(mapping), 50)

    def test_the_same_seed_reproduces_the_layout(self):
        macs = [f"aa:bb:cc:dd:ee:{i:02x}" for i in range(20)]
        self.assertEqual(self.deal(macs, 5, seed=99), self.deal(macs, 5, seed=99))

    def test_different_seeds_do_not_all_agree(self):
        """Without a real shuffle the deal would just follow the paste order."""
        macs = [f"aa:bb:cc:dd:ee:{i:02x}" for i in range(12)]
        layouts = {tuple(sorted(self.deal(macs, 4, seed=s).items())) for s in range(12)}
        self.assertGreater(len(layouts), 1)

    def test_no_devices_is_an_empty_layout(self):
        self.assertEqual(self.deal([], 3), {})

    def test_no_slots_is_refused_rather_than_dividing_by_zero(self):
        with self.assertRaises(ValueError):
            self.deal(["aa:bb:cc:dd:ee:01"], 0)

    def test_duplicate_devices_collapse(self):
        mapping = self.deal(["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:01"], 2)
        self.assertEqual(len(mapping), 1)

    def test_duplicates_do_not_shift_the_deal(self):
        """The dict collapses duplicate keys on its own, so length alone cannot
        show whether they were removed before dealing. Three copies of one
        device must still be the first slot, not the third."""
        mapping = self.deal(["aa:bb:cc:dd:ee:01"] * 3, 3)
        self.assertEqual(mapping, {"aa:bb:cc:dd:ee:01": 0})


class ProxyDisplayTests(unittest.TestCase):
    """What one pool row, and one device's pin, read as in the tables."""

    def row(self, **over):
        base = {"slot": 0, "type": "socks5", "host": "1.2.3.4", "port": 1080,
                "user": "u", "pass": "p", "label": ""}
        base.update(over)
        return base

    def test_a_label_wins_over_the_endpoint(self):
        self.assertEqual(app.proxy_display(self.row(label="Hà Nội 1")), "Hà Nội 1")

    def test_without_a_label_the_endpoint_is_shown(self):
        self.assertEqual(app.proxy_display(self.row()), "1.2.3.4:1080")

    def test_a_label_of_spaces_is_not_a_label(self):
        self.assertEqual(app.proxy_display(self.row(label="   ")), "1.2.3.4:1080")

    def test_credentials_are_never_part_of_the_display(self):
        shown = app.proxy_display(self.row(user="secretuser", **{"pass": "secretpass"}))
        self.assertNotIn("secret", shown)

    def test_a_row_missing_its_port_still_renders(self):
        self.assertEqual(app.proxy_display({"host": "1.2.3.4"}), "1.2.3.4")


class ClientProxyTextTests(unittest.TestCase):
    """The Proxy column has to distinguish four states, not just two."""

    def text(self, language="vi", **item):
        return app.client_proxy_text(item, language)

    def test_pinned_shows_the_label(self):
        self.assertEqual(
            self.text(proxy_state="pinned", proxy_label="Hà Nội 1", proxy_host="1.2.3.4:1080"),
            "Hà Nội 1")

    def test_pinned_without_a_label_shows_the_endpoint(self):
        self.assertEqual(
            self.text(proxy_state="pinned", proxy_label="", proxy_host="1.2.3.4:1080"),
            "1.2.3.4:1080")

    def test_unpinned_says_so_rather_than_looking_empty(self):
        self.assertEqual(self.text(proxy_state="unpinned", slot=None), "chưa ghim")
        self.assertEqual(self.text("en", proxy_state="unpinned", slot=None), "not pinned")

    def test_a_stale_pin_names_the_slot_that_vanished(self):
        # A device left pointing at a slot the pool no longer has must not read
        # like an ordinary unpinned device: the operator has to go fix it.
        vi = self.text(proxy_state="stale", slot=7)
        self.assertIn("7", vi)
        self.assertNotEqual(vi, "chưa ghim")
        self.assertIn("7", self.text("en", proxy_state="stale", slot=7))

    def test_an_ssid_with_no_pool_is_blank(self):
        self.assertEqual(self.text(proxy_state="none"), "—")

    def test_an_unknown_state_from_an_older_agent_is_blank(self):
        self.assertEqual(self.text(proxy_state="something-new"), "—")
        self.assertEqual(self.text(), "—")


class PoolSlotUsageTests(unittest.TestCase):
    """How many devices sit on each slot, for the pool table."""

    def clients(self):
        return [
            {"idx": 1, "mac": "aa", "slot": 0},
            {"idx": 1, "mac": "bb", "slot": 0},
            {"idx": 1, "mac": "cc", "slot": 2},
            {"idx": 1, "mac": "dd", "slot": None},
            {"idx": 2, "mac": "ee", "slot": 1},          # another Wi-Fi
            {"idx": 1, "mac": "ff", "slot": 9},          # a stale pin
        ]

    def test_counts_are_per_slot_and_per_wifi(self):
        self.assertEqual(app.pool_slot_usage(self.clients(), 1, 3), [2, 0, 1])

    def test_another_wifi_is_not_counted(self):
        self.assertEqual(app.pool_slot_usage(self.clients(), 2, 3), [0, 1, 0])

    def test_a_pin_past_the_end_is_left_out_rather_than_wrapped(self):
        # Wrapping it would credit the count to an unrelated proxy.
        self.assertEqual(sum(app.pool_slot_usage(self.clients(), 1, 3)), 3)

    def test_an_empty_pool_gives_an_empty_list(self):
        self.assertEqual(app.pool_slot_usage(self.clients(), 1, 0), [])

    def test_dirty_rows_do_not_raise(self):
        rows = [{"idx": "x", "slot": 0}, {"idx": 1, "slot": "0"}, {}, "not a dict"]
        self.assertEqual(app.pool_slot_usage(rows, 1, 2), [1, 0])


class PoolAgentCallTests(unittest.TestCase):
    """The four pool actions have to reach the agent in the shape it validates."""

    def client(self):
        instance = app.AgentClient("http://router", "token")
        instance._request = lambda *a, **kw: (a, kw)
        return instance

    def test_get_pool_passes_the_index_as_a_query_field(self):
        args, kwargs = self.client().get_pool(3)
        self.assertEqual(args[0], "get_pool")
        self.assertEqual(kwargs["query"], {"idx": "3"})

    def test_save_pool_posts_rows_as_objects(self):
        rows = [("socks5", "1.2.3.4", 1080, "u", "p", "nhãn")]
        args, kwargs = self.client().save_pool(2, rows)
        self.assertEqual(args[:2], ("save_pool", "POST"))
        self.assertEqual(kwargs["body"], {"idx": 2, "proxies": [
            {"type": "socks5", "host": "1.2.3.4", "port": 1080,
             "user": "u", "pass": "p", "label": "nhãn"}]})

    def test_assign_proxy_posts_the_pairs_untouched(self):
        pairs = [{"mac": "aa:bb:cc:dd:ee:01", "slot": 0}]
        args, kwargs = self.client().assign_proxy(1, pairs)
        self.assertEqual(args[:2], ("assign_proxy", "POST"))
        self.assertEqual(kwargs["body"], {"idx": 1, "assignments": pairs})

    def test_rebalance_omits_the_optional_fields_when_unset(self):
        _args, kwargs = self.client().rebalance(1, ["aa:bb:cc:dd:ee:01"])
        self.assertEqual(kwargs["body"], {"idx": 1, "macs": ["aa:bb:cc:dd:ee:01"]})

    def test_rebalance_carries_a_seed_and_a_pool_when_given(self):
        _args, kwargs = self.client().rebalance(
            1, ["aa:bb:cc:dd:ee:01"], proxies=[("http", "5.6.7.8", 8080, "", "", "")], seed=42)
        self.assertEqual(kwargs["body"]["seed"], 42)
        self.assertEqual(kwargs["body"]["proxies"][0]["type"], "http")


if __name__ == "__main__":
    unittest.main(verbosity=2)
