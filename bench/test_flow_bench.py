"""Tests for bench/flow_bench.py. Run: python3 -m unittest bench/test_flow_bench.py"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("flow_bench", HERE / "flow_bench.py")
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)


def case(raw, expect, must=(), mustnot=(), category="t", kind="dictation"):
    return {"id": "x", "category": category, "raw": raw, "expect": expect, "kind": kind,
            "must_contain": list(must), "must_not_contain": list(mustnot)}


def out(text, seconds=0.1, error=None, finish="stop"):
    return {"id": "x", "output": text, "seconds": seconds, "error": error, "finish_reason": finish}


class MetricTests(unittest.TestCase):
    def test_identity_is_not_right_for_typos_but_keeps_facts(self):
        c = case("i dont thnik we shoud send 400", "I don't think we should send 400.", ["400"], ["thnik"])
        r = fb.evaluate(c, out("i dont thnik we shoud send 400"))
        self.assertFalse(r["fully_right"])
        self.assertFalse(r["facts_lost"])
        self.assertEqual(r["forbidden_hit"], ["thnik"])

    def test_clean_input_returned_unchanged_counts_as_restraint(self):
        c = case("yes that works for me", "Yes, that works for me.", ["works"])
        r = fb.evaluate(c, out("Yes, that works for me."))
        self.assertTrue(r["clean_input"])
        self.assertTrue(r["unchanged"])
        self.assertTrue(r["fully_right"])

    def test_clean_input_changed_fails_restraint(self):
        c = case("yes that works for me", "Yes, that works for me.")
        r = fb.evaluate(c, out("Yes, that works for me, thanks."))
        self.assertTrue(r["clean_input"])
        self.assertFalse(r["unchanged"])

    def test_number_formatting_is_not_a_lost_fact(self):
        c = case("we paid 4500 euros", "We paid 4500 euros.", ["4500|4,500"])
        r = fb.evaluate(c, out("We paid €4,500."))
        self.assertFalse(r["facts_lost"])
        self.assertTrue(r["fully_right"])

    def test_missing_number_is_a_lost_fact(self):
        c = case("we paid 4500 euros", "We paid 4500 euros.", ["4500|4,500"])
        r = fb.evaluate(c, out("We paid about four thousand euros."))
        self.assertTrue(r["facts_lost"])

    def test_self_correction_cue_left_in_is_not_resolved(self):
        c = case("send the invoice to Mark no wait send it to Sarah", "Send it to Sarah.", ["Sarah"], ["Mark"],
                 category="restarts")
        r = fb.evaluate(c, out("Send it to Mark, no wait, send it to Sarah."))
        self.assertTrue(r["self_corr_cue"])
        self.assertFalse(r["self_corr_resolved"])
        self.assertFalse(r["fully_right"])

    def test_stretched_and_expanded_words_are_not_invented(self):
        c = case("yeahhh ok so we shiped it", "Yeahhh, ok, so we shipped it.", ["shipped"])
        r = fb.evaluate(c, out("Yeah, okay, so we shipped it."))
        self.assertEqual(r["invented_list"], [])

    def test_apostrophe_forms_are_not_invented(self):
        c = case("the sizing chart its off", "The sizing chart is off.", [])
        r = fb.evaluate(c, out("The sizing chart it's off."))
        self.assertEqual(r["invented_list"], [])

    def test_invented_content_word_is_counted(self):
        c = case("idk if hes coming tmrw, he siad maybe arond 6", "idk if he's coming tmrw, he said maybe around 6.", ["6"])
        r = fb.evaluate(c, out("I don't know if he's coming today, probably Arnold 6."))
        self.assertIn("arnold", r["invented_list"])
        self.assertTrue(r["invented"])

    def test_empty_output_is_not_right(self):
        c = case("um yes", "Yes.", [])
        r = fb.evaluate(c, out(""))
        self.assertTrue(r["empty"])
        self.assertFalse(r["fully_right"])

    def test_rules_approx_removes_fillers_and_repeats(self):
        self.assertEqual(fb.rules_approx("um so the the budget is is fine"), "So the budget is fine.")

    def test_table_has_one_row_per_category_and_all(self):
        rows = [fb.evaluate(case("a b", "a b", category="c1"), out("a b")),
                fb.evaluate(case("a b", "a b", category="c2"), out("a b"))]
        table = fb.render_table(rows, "t")
        self.assertIn("| c1 |", table)
        self.assertIn("| c2 |", table)
        self.assertIn("**ALL**", table)

    def test_missing_engine_file_is_an_error(self):
        cfg = {"kind": "llama", "label": "x", "gguf_glob": "/nonexistent/*.gguf", "template_glob": "/nonexistent/*.jinja"}
        with self.assertRaises(FileNotFoundError):
            fb.engine_identity("x", cfg)

    def test_wrong_hash_refuses_to_score(self):
        with tempfile.TemporaryDirectory() as d:
            g = Path(d) / "m.gguf"
            g.write_bytes(b"not a model")
            t = Path(d) / "t.jinja"
            t.write_bytes(b"x")
            cfg = {"kind": "llama", "label": "x", "gguf_glob": str(g), "template_glob": str(t),
                   "expected_sha256": "0" * 64}
            with self.assertRaises(RuntimeError):
                fb.engine_identity("x", cfg)


if __name__ == "__main__":
    unittest.main()
