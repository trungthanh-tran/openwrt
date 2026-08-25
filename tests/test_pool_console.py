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


if __name__ == "__main__":
    unittest.main(verbosity=2)
