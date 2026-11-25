#!/usr/bin/env python3
"""Unit tests for the DOSE1 T2 synthetic generators and checker (standard library only).

Run from this folder:  python3 -m unittest -v test_t2
"""
from __future__ import annotations

import copy
import json
import os
import re
import sys
import subprocess
import tempfile
import unittest
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_dictation  # noqa: E402
import gen_typing  # noqa: E402
import seeds_public as S  # noqa: E402
from check_t2 import check_row, check_rows  # noqa: E402
from t2_common import (DICT_RATES, EM_DASH, EMPTY, FILLER_ONLY_POOL, SEED, TYPE_RATES, WEEKDAYS,  # noqa: E402
                       control_line, parse_control_line, spoken_int, spoken_ordinal, sub_rng,
                       tokens_from_template)


def setUpModule():
    global samples_dir
    scratch = tempfile.TemporaryDirectory(prefix="flow-synthetic-tests-")
    unittest.addModuleCleanup(scratch.cleanup)
    samples_dir = scratch.name
    for kind in ("dictation", "typing"):
        subprocess.run(
            [sys.executable, os.path.join(HERE, f"gen_{kind}.py"),
             "--out", os.path.join(samples_dir, f"{kind}.jsonl")],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def _load(name: str):
    with open(os.path.join(samples_dir, name), encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


class ControlLineTests(unittest.TestCase):
    def test_clean_line_round_trips(self):
        line = control_line("clean")
        self.assertEqual(line, "[Task: clean] [Level: light] [Styling: formal] [Structure: lists] [Context: general]")
        self.assertEqual(parse_control_line(line)["Task"], "clean")

    def test_polish_line_is_fix_only(self):
        line = control_line("polish")
        rules = parse_control_line(line)["Rules"].split()
        self.assertIn("tone=on", rules)
        self.assertEqual(sum(1 for r in rules if r.endswith("=off")), 4)

    def test_rejects_unknown_values(self):
        with self.assertRaises(ValueError):
            control_line("clean", level="heavy")
        with self.assertRaises(ValueError):
            parse_control_line("[Task: clean] [Level: light] [Styling: casual] [Structure: poem] [Context: general]")

    def test_rejects_malformed_and_duplicate(self):
        with self.assertRaises(ValueError):
            parse_control_line("no brackets here")
        with self.assertRaises(ValueError):
            parse_control_line("[Task: polish] [Rules: concise=on] trailing text")
        with self.assertRaises(ValueError):
            parse_control_line("[Task: clean] [Task: clean] [Level: light] [Styling: casual] [Structure: prose] [Context: general]")

    def test_polish_requires_every_switch(self):
        with self.assertRaises(ValueError):
            parse_control_line("[Task: polish] [Rules: concise=off clear=off reorder=off structure=off]")


class NumberWordTests(unittest.TestCase):
    def test_cardinals(self):
        cases = {0: "zero", 13: "thirteen", 21: "twenty one", 40: "forty", 100: "one hundred",
                 1005: "one thousand five", 42: "forty two", 1250: "one thousand two hundred fifty"}
        for n, words in cases.items():
            self.assertEqual(spoken_int(n), words)

    def test_ordinals(self):
        cases = {1: "first", 2: "second", 3: "third", 4: "fourth", 11: "eleventh", 12: "twelfth",
                 21: "twenty first", 30: "thirtieth", 20: "twentieth"}
        for n, words in cases.items():
            self.assertEqual(spoken_ordinal(n), words)

    def test_out_of_range_raises(self):
        with self.assertRaises(ValueError):
            spoken_int(-1)


class SlotTests(unittest.TestCase):
    def test_slot_formats(self):
        rng = sub_rng("slot-test", 0)
        for _ in range(200):
            toks = tokens_from_template("{NAME} {NUM} {MONEY} {DATE} {TIME} {URL} {EMAIL} {DAY}", rng)
            kinds = {t.kind: t.value for t in toks if t.prot}
            self.assertRegex(kinds["money"], r"^[€$£][\d,]+$")
            self.assertRegex(kinds["time"], r"^\d{1,2}:\d{2}$")
            self.assertTrue(kinds["url"].startswith("https://example.com/"))
            self.assertTrue(kinds["email"].endswith("@example.org"))
            self.assertIn(kinds["weekday"], WEEKDAYS)

    def test_punctuation_joins_protected_token(self):
        rng = sub_rng("punct-test", 0)
        toks = tokens_from_template("Hi {NAME}, thanks for the call.", rng)
        prot = [t for t in toks if t.prot][0]
        self.assertTrue(prot.tgt.endswith(","))
        self.assertFalse(prot.value.endswith(","), "protected value must not carry punctuation")
        self.assertFalse(any(t.tgt == "," for t in toks))

    def test_correction_adds_superseded_value(self):
        rng = sub_rng("corr-test", 0)
        toks = tokens_from_template("Let's book it for {CORR_DAY} at {TIME}.", rng)
        superseded = [t for t in toks if t.superseded]
        self.assertEqual(len(superseded), 1)
        self.assertIsNone(superseded[0].tgt)
        right = [t for t in toks if t.prot and t.kind == "weekday"][0]
        self.assertNotEqual(superseded[0].value, right.value)


class DeterminismTests(unittest.TestCase):
    def test_same_seed_same_rows(self):
        a = list(gen_dictation.generate(40, SEED))
        b = list(gen_dictation.generate(40, SEED))
        self.assertEqual(a, b)
        c = list(gen_typing.generate(40, SEED))
        d = list(gen_typing.generate(40, SEED))
        self.assertEqual(c, d)

    def test_different_seed_different_rows(self):
        a = [r["input"] for r in gen_dictation.generate(40, SEED)]
        b = [r["input"] for r in gen_dictation.generate(40, SEED + 1)]
        self.assertNotEqual(a, b)

    def test_samples_match_generator_exactly(self):
        dictation = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in gen_dictation.generate(120, SEED))
        typing_ = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in gen_typing.generate(80, SEED))
        with open(os.path.join(samples_dir, "dictation.jsonl"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), dictation)
        with open(os.path.join(samples_dir, "typing.jsonl"), encoding="utf-8") as fh:
            self.assertEqual(fh.read(), typing_)


class SampleFileTests(unittest.TestCase):
    def test_counts_and_schema(self):
        d, t = _load("dictation.jsonl"), _load("typing.jsonl")
        self.assertEqual((len(d), len(t), len(d) + len(t)), (120, 80, 200))
        ids = [r["id"] for r in d + t]
        self.assertEqual(len(ids), len(set(ids)))
        for r in d + t:
            self.assertEqual(set(r), {"id", "task", "control_line", "input", "target", "protected", "ops"})

    def test_every_sample_row_passes_checker(self):
        result = check_rows(_load("dictation.jsonl") + _load("typing.jsonl"))
        self.assertEqual(result["failed_rows"], 0, result["examples"])
        self.assertGreater(result["protected_checked"], 500)

    def test_no_em_dash_in_any_target(self):
        for r in _load("dictation.jsonl") + _load("typing.jsonl"):
            self.assertNotIn(EM_DASH, r["target"])

    def test_filler_only_rows(self):
        rows = [r for r in _load("dictation.jsonl") if r["target"] == EMPTY]
        self.assertGreaterEqual(len(rows), 1)
        for r in rows:
            words = re.findall(r"[A-Za-z']+", r["input"].lower())
            self.assertTrue(words and all(w in FILLER_ONLY_POOL for w in words), r["input"])
            self.assertEqual(r["protected"], [])

    def test_identity_rows_unchanged(self):
        rows = [r for r in _load("dictation.jsonl") + _load("typing.jsonl")
                if any(o["op"] == "identity" for o in r["ops"])]
        self.assertGreaterEqual(len(rows), 20)
        for r in rows:
            self.assertEqual(r["input"], r["target"])

    def test_literal_cue_rows_keep_their_cue(self):
        rows = [r for r in _load("dictation.jsonl") if r["id"].endswith("literal_cue")]
        self.assertGreaterEqual(len(rows), 1)
        for r in rows:
            entries = [e for e in r["protected"] if e["kind"] == "literal_cue"]
            self.assertTrue(entries)
            for e in entries:
                self.assertIn(e["value"], r["target"])

    def test_instruction_rows_stay_text(self):
        rows = [r for r in _load("dictation.jsonl") if r["id"].endswith("instruction")]
        self.assertGreaterEqual(len(rows), 1)
        for r in rows:
            self.assertTrue(any(e["kind"] == "instruction_text" for e in r["protected"]))
            self.assertNotIn("•", r["target"])

    def test_dutch_rows_have_no_english_number_words(self):
        number_words = re.compile(r"\b(forty|fifty|thousand|hundred|twenty|thirty|one|two|three)\b", re.I)
        for r in _load("dictation.jsonl"):
            if r["id"].endswith(("dutch", "mixed")):
                self.assertIsNone(number_words.search(r["target"]), r["target"])

    def test_superseded_values_absent_and_right_values_present(self):
        rows = [r for r in _load("dictation.jsonl") if r["id"].endswith("self_correction")]
        self.assertGreaterEqual(len(rows), 5)
        for r in rows:
            sup = [e["value"] for e in r["protected"] if e["kind"] == "superseded"]
            kept = [e["value"] for e in r["protected"] if e["kind"] != "superseded"]
            self.assertTrue(sup)
            for v in sup:
                self.assertFalse(re.search(r"(?<![A-Za-z0-9])" + re.escape(v) + r"(?![A-Za-z0-9])", r["target"]))
            for v in kept:
                self.assertIn(v.rstrip(".,?!"), r["target"])

    def test_typed_protected_values_never_typoed(self):
        for r in _load("typing.jsonl"):
            for e in r["protected"]:
                if e["kind"] in ("number", "money", "time", "email", "url"):
                    self.assertIn(e["value"], r["target"])
                    self.assertNotIn("input", e, "numbers, links and emails should not change rendering when typed")


class CheckerNegativeTests(unittest.TestCase):
    """The checker must catch deliberately broken rows, or its passing results mean nothing."""

    @classmethod
    def setUpClass(cls):
        cls.good = next(r for r in _load("dictation.jsonl") if any(e["kind"] == "number" for e in r["protected"]))

    def _mutated(self, fn):
        row = copy.deepcopy(self.good)
        fn(row)
        return row

    def test_good_row_passes(self):
        self.assertEqual(check_row(self.good), [])

    def test_missing_number_fails(self):
        def drop_number(row):
            num = next(e["value"] for e in row["protected"] if e["kind"] == "number")
            row["target"] = row["target"].replace(num, "many", 1)
        self.assertTrue(any(name == "protected" for name, _ in check_row(self._mutated(drop_number))))

    def test_superseded_value_left_in_target_fails(self):
        def leak(row):
            sup = [e["value"] for e in row["protected"] if e["kind"] == "superseded"]
            if sup:
                row["target"] += " " + sup[0]
            else:
                row["target"] += " 999999"
                row["protected"].append({"kind": "superseded", "value": "999999"})
        self.assertTrue(check_row(self._mutated(leak)))

    def test_leftover_filler_fails(self):
        self.assertTrue(any(name == "leftover_filler" for name, _ in
                            check_row(self._mutated(lambda r: r.__setitem__("target", r["target"] + " um")))))

    def test_em_dash_fails(self):
        self.assertTrue(any(name == "no_em_dash" for name, _ in
                            check_row(self._mutated(lambda r: r.__setitem__("target", r["target"] + " — ok")))))

    def test_bad_control_line_fails(self):
        self.assertTrue(any(name == "control_line" for name, _ in
                            check_row(self._mutated(lambda r: r.__setitem__("control_line", "[Task: clean]")))))

    def test_missing_rendering_fails(self):
        def fake_rendering(row):
            row["protected"].append({"kind": "number", "value": row["protected"][0]["value"], "input": "zzqqx"})
        self.assertTrue(any(name == "protected" for name, _ in check_row(self._mutated(fake_rendering))))

    def test_identity_mismatch_fails(self):
        row = {"id": "x", "task": "clean", "control_line": control_line("clean"), "input": "a b", "target": "a c",
               "protected": [], "ops": [{"op": "identity", "n": 1}]}
        self.assertTrue(any(name == "identity" for name, _ in check_row(row)))

    def test_empty_target_with_content_fails(self):
        row = {"id": "x", "task": "clean", "control_line": control_line("clean"), "input": "hello there",
               "target": EMPTY, "protected": [], "ops": []}
        self.assertTrue(any(name == "filler_only" for name, _ in check_row(row)))

    def test_extra_schema_key_fails(self):
        self.assertTrue(check_row(self._mutated(lambda r: r.__setitem__("extra", 1))))


class TemplateSafetyTests(unittest.TestCase):
    def test_every_template_fills_without_error(self):
        for pool in (S.PROSE, S.MEETING, S.RECIPE, S.RAMBLE, S.SELF_CORRECTION, S.DUTCH, S.MIXED,
                     S.TYPED_CHAT, S.TYPED_EMAIL, S.TYPED_NOTES, S.TYPED_SLANG, S.TYPED_DUTCH, S.TYPED_MIXED):
            for template in pool:
                for seed in range(5):
                    tokens_from_template(template, sub_rng("fill", seed))

    def test_dutch_templates_use_only_name_and_email_slots(self):
        for pool in (S.DUTCH, S.TYPED_DUTCH):
            for template in pool:
                slots = set(re.findall(r"\{([A-Z_]+)\}", template))
                self.assertLessEqual(slots, {"NAME", "EMAIL"}, template)


class RateTests(unittest.TestCase):
    """Realised rates should be close to the configured planning rates (large sample, loose bounds)."""

    def test_dictation_soft_filler_rate(self):
        rows = list(gen_dictation.generate(400, SEED))
        fillers = 0
        target_words = 0
        for r in rows:
            target_words += len(r["target"].split()) if r["target"] != EMPTY else 0
            fillers += sum(o["n"] for o in r["ops"] if o["op"] == "filler")
        rate = 100.0 * fillers / max(1, target_words)
        self.assertGreater(rate, DICT_RATES["soft_filler_per_100"] * 0.6)
        self.assertLess(rate, DICT_RATES["soft_filler_per_100"] * 1.4)

    def test_dictation_lowercase_and_repeat_rates(self):
        rows = list(gen_dictation.generate(400, SEED))
        lower = sum(1 for r in rows if any(o["op"] == "lowercase_row" for o in r["ops"]))
        self.assertGreater(lower / len(rows), 0.02)
        self.assertLess(lower / len(rows), 0.16)
        self.assertTrue(any(o["op"] == "repeat" for r in rows for o in r["ops"]))

    def test_typing_heavy_share_and_typo_presence(self):
        rows = [r for r in gen_typing.generate(400, SEED) if r["id"].split("-")[-1] != "guard"]
        heavy = sum(1 for r in rows if any(o["op"] == "heavy_row" for o in r["ops"])) / len(rows)
        self.assertGreater(heavy, TYPE_RATES["heavy_row_share"] * 0.5)
        self.assertLess(heavy, TYPE_RATES["heavy_row_share"] * 1.6)
        totals = Counter()
        for r in rows:
            for o in r["ops"]:
                totals[o["op"]] += o.get("n", 0)
        for op in ("substitute", "omit", "apostrophe", "lowercase_row"):
            self.assertGreater(totals[op], 0, op)


if __name__ == "__main__":
    unittest.main(verbosity=2)
