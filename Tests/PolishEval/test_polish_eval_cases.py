"""Checks the cloud polish eval case file: size, shape, and that every expected output obeys the hard rules."""
import json
import re
import unittest
from pathlib import Path

CASES = Path(__file__).with_name("polish-eval-cases.json")
REPLAY = Path(__file__).with_name("replay-outputs.json")
DASHES = ("—", "–", "―")


class PolishEvalCasesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = json.loads(CASES.read_text())

    def test_replay_covers_exactly_the_public_cases(self):
        replay = json.loads(REPLAY.read_text())
        self.assertEqual(set(replay), {case["id"] for case in self.cases})
        for case_id, answer in replay.items():
            self.assertTrue(answer is None or isinstance(answer, str), case_id)

    def test_at_least_forty_cases(self):
        self.assertGreaterEqual(len(self.cases), 40)

    def test_ids_are_unique(self):
        ids = [c["id"] for c in self.cases]
        self.assertEqual(len(ids), len(set(ids)))

    def test_required_fields_and_kinds(self):
        for c in self.cases:
            for field in ("id", "category", "raw", "expect"):
                self.assertTrue(c.get(field), f"{c.get('id')} missing {field}")
            self.assertIn(c.get("kind", "dictation"), ("dictation", "selected"), c["id"])
            self.assertIn(c.get("cleanupLevel", "medium"), ("light", "medium", "high"), c["id"])

    def test_every_case_has_a_keep_check(self):
        for c in self.cases:
            self.assertTrue(c.get("keep"), f"{c['id']} has no keep tokens")

    def test_expected_outputs_obey_the_hard_rules(self):
        for c in self.cases:
            self.assertFalse(any(d in c["expect"] for d in DASHES), f"{c['id']} expects a dash")

    def test_keep_tokens_appear_in_the_expected_output(self):
        for c in self.cases:
            for token in c["keep"]:
                self.assertIn(token.lower(), c["expect"].lower(), f"{c['id']}: '{token}' not in expect")

    def test_drop_tokens_are_absent_from_the_expected_output(self):
        for c in self.cases:
            for token in c.get("drop", []):
                self.assertNotIn(token.lower(), c["expect"].lower(), f"{c['id']}: '{token}' still in expect")

    def test_covers_the_requested_categories(self):
        cats = {c["category"] for c in self.cases}
        for need in ("fillers", "restarts", "numbers", "names", "lists", "email", "questions",
                     "casual", "work", "dutch-english", "dashes", "emoji", "selected"):
            self.assertIn(need, cats)


if __name__ == "__main__":
    unittest.main()
