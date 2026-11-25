#!/usr/bin/env python3
"""Writes replay-outputs.json: one recorded model answer per eval case, for offline polish runs.

Default answer = the case's ideal output (a model that does everything right).
FAULTS below are hand-written bad answers, one or more per guard, so each guard in the
production pipeline has a case that exercises it. Each fault names what should happen:
  "guard"  the production code rejects or repairs the answer; the scorer should pass the case
           (or fail it only on the checks the fault is meant to show)
  "gap"    no production guard catches it today; the scorer is expected to fail the case

Run from the repo root:  python3 Tests/PolishEval/make_replay.py
Output: Tests/PolishEval/replay-outputs.json  (null = a failed cloud call)
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
cases = json.loads((HERE / "polish-eval-cases.json").read_text())

# id: (answer, fault name, expected outcome)
FAULTS = {
    "fill-01": ("So I think we should move the meeting to Thursday. Let me know if that works.",
                "added-content", "gap"),
    "fill-02": ("I think the budget is.", "dropped-word", "gap"),
    "restart-01": ("Send it to Mark, no wait, send it to Sarah.", "restart-not-resolved", "gap"),
    "num-02": ("We paid 4050 euros for the car and 250 for the insurance.", "wrong-number", "guard"),
    "name-01": ("I talked to Pria from Dalton Labs about the veCRV rewards.", "wrong-name", "guard"),
    "dash-01": ("The launch is on Friday — we need final assets by Thursday.", "em-dash", "guard"),
    "dash-02": ("We went from 5–10 leads a day to 40 — big jump.", "en-dash-range", "guard"),
    "dash-03": ("Monday — Thursday, that's the window for the shoot.", "dash-between-names", "guard"),
    "dash-04": ("The price went from 100 — or was it 120 — I don't remember.", "dash-clauses", "guard"),
    "emoji-01": ("Ready to go. Let's ship it. \U0001F680\U0001F389", "emoji-added", "guard"),
    "fact-03": ("Remember to buy oat milk not almond milk", "stripped-punctuation", "gap"),
    "high-01": ("Here's the cleaned-up version:\n\n1. Do the research.\n2. Design the pages.\n"
                "3. Test them with five users and ship.", "preamble", "guard"),
    "question-01": ("\"Are you still coming to the gym tomorrow?\"", "wrapping-quotes", "guard"),
    "casual-01": ("<think>Keep it casual.</think>\nLol, pizza tonight?", "think-block", "guard"),
    "para-01": ("Okay, the user wants me to clean this up. Thanks for the call yesterday. "
                "The proposal looks good to me.", "chain-of-thought", "guard"),
    "fact-04": ("", "empty-output", "guard"),
    "list-03": (None, "cloud-failure", "guard"),
    "sel-03": ("The deadline is 12 June and the budget is 4,540 euros.", "selected-wrong-number", "guard"),
    "sel-05": ("Hey Jordan — see attached — ping me when ready.", "selected-em-dash", "guard"),
    # Research addendum faults. Each is a bad answer a model might give.
    "ng-01": ("Merge a change like this without a review.", "negation-dropped", "guard"),
    "ng-02": ("Remember to buy oat milk and almond milk.", "negation-dropped", "guard"),
    "cmd-01": ("The oven is at 125\u00b0.", "unit-symbol", "guard"),
    "hedge-01": ("We should wait a bit.", "hedges-dropped", "guard"),
    "drop-01": ("Hey Bob, yes, I agree. I think we should talk next week. How does Tuesday sound?",
                "dropped-content", "guard"),
    "lit-01": ("Sure, I'll make sure it looks like a text message.", "instruction-obeyed", "guard"),
    "emph-01": ("I'm super excited about this, and it's been a long time coming!", "added-exclamation", "gap"),
    "mix-04": ("The client wants the invoice tomorrow and we'll send it to Sanne then.", "translated", "guard"),
    "mix-05": ("I'm there at half past eight, that's fine.", "translated", "guard"),
    "short-02": ("Thanks for watching, see you next time.", "invented-on-tiny-clip", "guard"),
}


def ideal(case):
    return case["expect"]


answers = {}
for c in cases:
    if c["id"] in FAULTS:
        answers[c["id"]] = FAULTS[c["id"]][0]
    else:
        answers[c["id"]] = ideal(c)

(HERE / "replay-outputs.json").write_text(json.dumps(answers, indent=2, ensure_ascii=False) + "\n")
(HERE / "replay-faults.json").write_text(json.dumps(
    {k: {"fault": v[1], "expect": v[2]} for k, v in FAULTS.items()}, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {len(answers)} answers, {len(FAULTS)} faults")
