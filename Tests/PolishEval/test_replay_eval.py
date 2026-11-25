"""End-to-end polish regression with no key, no network and no running Flow.

Runs the real pipeline (prompts aside, which the model would normally answer) on the recorded
answers in replay-outputs.json, through `Flow --polish-eval ... -voice.polishReplay`, then checks:
  * every guarded fault leaves no dash, emoji, preamble, think block, quotes, meta-narration,
    or swapped number or name in the output;
  * the cases that still fail the scorer are exactly the known list below. If a change fixes one,
    or breaks another, this test fails and the list must be updated on purpose.

Needs the debug binary: `swift build --product Flow` from the repo root. Skips when it is missing.
Run: python3 -m unittest Tests/PolishEval/test_replay_eval.py
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / ".build" / "debug" / "Flow"
CASES = ROOT / "Tests" / "PolishEval" / "polish-eval-cases.json"
REPLAY = ROOT / "Tests" / "PolishEval" / "replay-outputs.json"
SCORER = ROOT / "scripts" / "score-polish-eval.py"

# Cases that still fail a mechanical check on purpose. Each fails only the listed checks:
#   list-03  cloud failure (null answer)                     fault, expected
#   sel-03   selected text with a swapped number is refused  fault, expected (nonempty)
# fill-01, fill-02, num-01, num-04 and mix-01 pass: the speaker-wording guards reject the added
# sentence, the dropped word and the unit swap, and fall back to the cleaned original; date order
# and units are kept by the postprocessor; Dutch passes through unchanged.
#   emph-01  fault: an added "!" that no guard removes yet (tone; open gap)
#   short-02 one-word input takes the fast path and never reaches the model (routing; open gap)
KNOWN_FAILS = {
    "list-03": {"cloud"}, "sel-03": {"nonempty"},
    "emph-01": {"drop"}, "short-02": {"cloud", "casing", "ending"},
}


def load_scorer():
    spec = importlib.util.spec_from_file_location("score_polish_eval", SCORER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(BINARY.exists(), "build the Flow product first: swift build --product Flow")
class ReplayEvalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory(prefix="flow-replay-")
        cls.addClassCleanup(scratch.cleanup)
        cls.tmp = scratch.name
        os.chmod(cls.tmp, 0o700)
        out = Path(cls.tmp) / "results.json"
        env = dict(os.environ, FLOW_EVAL_SUPPORT_DIR=cls.tmp)
        result = subprocess.run([str(BINARY), "--polish-eval", str(CASES), str(out),
                        "-voice.allowCloudPolishing", "YES", "-voice.privacyMode", "NO",
                        "-voice.cleanupModel", "qwen3", "-voice.evalCloudOnly", "YES",
                        "-voice.polishReplay", str(REPLAY)],
                       cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        if result.returncode == 75:
            raise unittest.SkipTest("Flow could not claim sole backend ownership for replay")
        result.check_returncode()
        cls.results = {r["id"]: r for r in json.loads(out.read_text())}
        cls.cases = {c["id"]: c for c in json.loads(CASES.read_text())}
        cls.scorer = load_scorer()

    def check(self, cid):
        case, res = self.cases[cid], self.results[cid]
        checks, _ = self.scorer.check_case(case, res, None)
        return {k for k, ok in checks.items() if not ok}

    def test_every_case_has_a_result(self):
        self.assertEqual(set(self.results), set(self.cases))

    def test_failing_checks_are_exactly_the_known_list(self):
        failing = {cid: self.check(cid) for cid in self.cases}
        failing = {cid: f for cid, f in failing.items() if f}
        self.assertEqual({cid: sorted(f) for cid, f in failing.items()},
                         {cid: sorted(f) for cid, f in KNOWN_FAILS.items()})

    def test_dash_faults_never_ship_a_dash(self):
        for cid in ("dash-01", "dash-02", "dash-03", "dash-04", "sel-05"):
            out = self.results[cid].get("output") or ""
            self.assertFalse(any(d in out for d in "—–―"), f"{cid}: {out!r}")

    def test_model_added_emoji_is_removed(self):
        out = self.results["emoji-01"].get("output") or ""
        self.assertNotIn("\U0001F680", out)
        self.assertNotIn("\U0001F389", out)

    def test_preamble_and_quotes_are_stripped(self):
        self.assertFalse((self.results["high-01"].get("output") or "").lower().startswith("here"))
        out = self.results["question-01"].get("output") or ""
        self.assertFalse(out.startswith('"'), out)

    def test_think_block_never_ships(self):
        self.assertNotIn("<think>", self.results["casual-01"].get("output") or "")
        self.assertNotIn("Keep it casual", self.results["casual-01"].get("output") or "")

    def test_model_narration_never_ships(self):
        out = (self.results["para-01"].get("output") or "").lower()
        self.assertNotIn("the user wants", out)

    def test_swapped_number_and_name_never_ship(self):
        self.assertNotIn("4050", self.results["num-02"].get("output") or "")
        self.assertNotIn("Pria", self.results["name-01"].get("output") or "")

    def test_refused_selected_text_returns_nothing(self):
        self.assertIsNone(self.results["sel-03"].get("output"))

    def test_cloud_failure_is_not_credited_to_local(self):
        self.assertNotIn("engine", self.results["list-03"])

    def test_added_sentence_is_rejected(self):
        out = self.results["fill-01"].get("output") or ""
        self.assertNotIn("Let me know", out)
        self.assertIn("move the meeting to", out.lower())

    def test_dropped_word_is_restored(self):
        out = self.results["fill-02"].get("output") or ""
        self.assertIn("fine", out)
        self.assertFalse(out.rstrip().endswith("is."), out)

    def test_unit_stays_as_spoken(self):
        out = self.results["num-04"].get("output") or ""
        self.assertIn("kilos", out)
        self.assertNotIn(" kg", out)

    def test_date_order_stays_as_spoken(self):
        out = self.results["num-01"].get("output") or ""
        self.assertIn("12th of March", out)

    def test_range_dash_reads_to_not_a_full_stop(self):
        out = self.results["dash-03"].get("output") or ""
        self.assertEqual(out, "Monday to Thursday, that's the window for the shoot.")

    def test_dutch_passes_through_unchanged(self):
        self.assertEqual(self.results["mix-01"].get("output"), self.cases["mix-01"]["raw"])


if __name__ == "__main__":
    unittest.main()
