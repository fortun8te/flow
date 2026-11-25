#!/usr/bin/env python3
"""Typing generator v2 for DOSE1 T2 (B1a). Replaces gen_typing.py's mess model; that file is unchanged.

Five mess levels replace the old light and heavy rows (MASTER-PLAN 6.3.6):
  L0 clean (guard rows, input equals target)        share 10%   0 errors per 100 words
  L1 tidy                                           share 15%   3
  L2 normal fast typing                             share 25%   8
  L3 messy                                          share 30%   15
  L4 Jordan-level (garbled runs, stray letters)    share 20%   50 (plan says 22 or more; raised so the
                                                                 top level damages at least a third of words,
                                                                 as the calibration request says)

Operators (new): adjacent-key substitution, transposition, dropped and doubled letters, merged words, split
words, dropped apostrophes, missing capitals, lowercase "i", sound-alike spellings, letter-order scramble,
stray letter moved across a space ("it can" -> "tit can"), garbled runs (2 to 3 neighbouring words with
two or more errors each), doubled words, typed fillers (uhm, like, yk, um: removed from the target),
and dropped final punctuation. Shorthand and stretched words are clean seed text, so they stay in the target.

Protected values (numbers, money, dates, times, names, links, emails, negations) never get typos. Only
apostrophes and capitals may change on them, as before. Every row goes through check_t2.check_row.

  python3 gen_typing_v2.py --n 300 --seed 20261114 --out samples/typing_v2_fresh300.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
from collections import Counter
from typing import Dict, Iterator, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_t2 import check_row  # noqa: E402
from seed_bank import typed_templates  # noqa: E402
from t2_common import (SEED, Tok, _typo_word, control_line, join_input, join_target,  # noqa: E402
                       protected_entries, sub_rng, tokens_from_template)

PUNCT = ".,?!;:"

LEVELS: Dict[str, Dict[str, float]] = {
    "L0": {"share": 0.10, "errors_per_100": 0.0},
    "L1": {"share": 0.15, "errors_per_100": 3.0},
    "L2": {"share": 0.25, "errors_per_100": 8.0},
    "L3": {"share": 0.30, "errors_per_100": 15.0},
    "L4": {"share": 0.20, "errors_per_100": 50.0},
}

SOUND_ALIKES = {
    "grammar": "grammer", "definitely": "definately", "receive": "recieve", "their": "thier",
    "separate": "seperate", "quarter": "quater", "because": "becuase", "tomorrow": "tomorow",
    "necessary": "neccessary", "accommodate": "acommodate", "until": "untill", "friend": "freind",
    "calendar": "calender", "schedule": "schedual", "whether": "wether", "business": "bussiness",
    "occurred": "occured", "address": "adress", "embarrass": "embarass", "always": "allways",
    "again": "agian", "believe": "beleive", "thought": "thougth", "probably": "probly",
}
TYPED_FILLERS = ["uhm", "like", "yk", "um"]
OP_WEIGHTS: List[Tuple[str, float]] = [
    ("letter", 0.34), ("garble", 0.12), ("stray", 0.06), ("sound", 0.09), ("scramble", 0.05),
    ("double_letter", 0.05), ("merge", 0.05), ("split", 0.05), ("apostrophe", 0.06), ("filler", 0.05),
    ("doubled_word", 0.04), ("lower_i", 0.02), ("no_final", 0.02),
]
MAX_ATTEMPTS = 12
GARBLE_COST = 2
LEVEL_ORDER = ["L0", "L1", "L2", "L3", "L4"]


def level_plan(n: int, seed: int) -> List[str]:
    total = sum(v["share"] for v in LEVELS.values())
    counts = {k: int(round(n * v["share"] / total)) for k, v in LEVELS.items()}
    diff = n - sum(counts.values())
    keys = LEVEL_ORDER * (abs(diff) // len(LEVEL_ORDER) + 1)
    for k in keys[: abs(diff)]:
        counts[k] += 1 if diff > 0 else -1
    plan = [k for k in LEVEL_ORDER for _ in range(counts[k])]
    sub_rng("typing-v2-plan", 0, 0, seed).shuffle(plan)
    return plan


def _words(toks: List[Tok]) -> List[int]:
    return [i for i, t in enumerate(toks) if not t.prot and t.tgt is not None and len(re.sub(r"[^A-Za-z]", "", t.text)) >= 2]


def _case_like(src: str, dst: str) -> str:
    if src[:1].isupper():
        return dst[:1].upper() + dst[1:]
    return dst


def _op_letter(toks, rng, counts):
    idx = _words(toks)
    if not idx:
        return False
    i = rng.choice(idx)
    new = _typo_word(toks[i].text, rng, 1.0, counts)
    if new == toks[i].text:
        new = toks[i].text[:-1] + toks[i].text[-1] * 2 if len(toks[i].text) > 2 else toks[i].text + toks[i].text[-1]
    toks[i].text = new
    counts["typo"] = counts.get("typo", 0) + 1
    return True


def _op_garble(toks, rng, counts):
    idx = _words(toks)
    if len(idx) < 3:
        return False
    start = rng.choice(idx)
    span = [i for i in range(start, min(start + rng.choice([2, 3]), len(toks)))]
    if not all(i in idx for i in span):
        return False
    for i in span:
        w = toks[i].text
        for _ in range(2):
            pos = rng.randrange(len(w))
            if w[pos].isalpha():
                w = w[:pos] + w[pos + 1:] if rng.random() < 0.5 else w[:pos] + rng.choice("aeiourstn") + w[pos + 1:]
        if w == toks[i].text:
            w = w + rng.choice("qxzj")
        toks[i].text = w
    counts["garble_run"] = counts.get("garble_run", 0) + 1
    return True


def _op_stray(toks, rng, counts):
    idx = [i for i in _words(toks) if len(toks[i].text) <= 4 and toks[i].text.isalpha()]
    if not idx:
        return False
    i = rng.choice(idx)
    w = toks[i].text
    toks[i].text = w[0] + w
    counts["stray_letter"] = counts.get("stray_letter", 0) + 1
    return True


def _op_sound(toks, rng, counts):
    cands = [i for i in _words(toks) if toks[i].text.lower().rstrip(PUNCT) in SOUND_ALIKES]
    if not cands:
        return False
    i = rng.choice(cands)
    core = toks[i].text.rstrip(PUNCT)
    tail = toks[i].text[len(core):]
    toks[i].text = _case_like(core, SOUND_ALIKES[core.lower()]) + tail
    counts["sound_alike"] = counts.get("sound_alike", 0) + 1
    return True


def _op_scramble(toks, rng, counts):
    cands = [i for i in _words(toks) if len(toks[i].text) >= 6 and toks[i].text.isalpha()]
    if not cands:
        return False
    i = rng.choice(cands)
    w = list(toks[i].text)
    k = rng.randrange(1, len(w) - 2)
    w[k], w[k + 1] = w[k + 1], w[k]
    toks[i].text = "".join(w)
    counts["scramble"] = counts.get("scramble", 0) + 1
    return True


def _op_double_letter(toks, rng, counts):
    cands = [i for i in _words(toks) if toks[i].text.isalpha() and len(toks[i].text) >= 3]
    if not cands:
        return False
    i = rng.choice(cands)
    w = toks[i].text
    p = rng.randrange(len(w))
    toks[i].text = w[:p] + w[p] + w[p:]
    counts["double_letter"] = counts.get("double_letter", 0) + 1
    return True


def _op_merge(toks, rng, counts):
    cands = [i for i in range(len(toks) - 1)
             if not toks[i].prot and not toks[i + 1].prot and toks[i].tgt is not None and toks[i + 1].tgt is not None
             and not toks[i + 1].glue]
    if not cands:
        return False
    i = rng.choice(cands)
    toks[i + 1].glue = True
    counts["merge"] = counts.get("merge", 0) + 1
    return True


def _op_split(toks, rng, counts):
    cands = [i for i in _words(toks) if toks[i].text.isalpha() and len(toks[i].text) >= 5]
    if not cands:
        return False
    i = rng.choice(cands)
    w = toks[i].text
    p = rng.randrange(2, len(w) - 1)
    toks[i].text = w[:p] + " " + w[p:]
    counts["split"] = counts.get("split", 0) + 1
    return True


def _op_apostrophe(toks, rng, counts):
    cands = [i for i, t in enumerate(toks) if "'" in t.text]
    if not cands:
        return False
    i = rng.choice(cands)
    toks[i].text = toks[i].text.replace("'", "", 1)
    counts["apostrophe"] = counts.get("apostrophe", 0) + 1
    return True


def _op_filler(toks, rng, counts):
    p = rng.randrange(0, len(toks) + 1)
    toks.insert(p, Tok(text=rng.choice(TYPED_FILLERS), tgt=None))
    counts["typed_filler"] = counts.get("typed_filler", 0) + 1
    return True


def _op_doubled_word(toks, rng, counts):
    cands = [i for i in _words(toks)]
    if not cands:
        return False
    i = rng.choice(cands)
    toks.insert(i + 1, Tok(text=toks[i].text, tgt=None))
    counts["doubled_word"] = counts.get("doubled_word", 0) + 1
    return True


def _op_lower_i(toks, rng, counts):
    cands = [i for i, t in enumerate(toks) if t.text == "I" and not t.prot]
    if not cands:
        return False
    toks[rng.choice(cands)].text = "i"
    counts["lower_i"] = counts.get("lower_i", 0) + 1
    return True


def _op_no_final(toks, rng, counts):
    cands = [i for i, t in enumerate(toks) if t.text[-1:] in PUNCT and not t.prot]
    if not cands:
        return False
    i = rng.choice(cands)
    toks[i].text = toks[i].text.rstrip(PUNCT)
    counts["no_final_punct"] = counts.get("no_final_punct", 0) + 1
    return True


OPS = {"letter": _op_letter, "garble": _op_garble, "stray": _op_stray, "sound": _op_sound,
       "scramble": _op_scramble, "double_letter": _op_double_letter, "merge": _op_merge, "split": _op_split,
       "apostrophe": _op_apostrophe, "filler": _op_filler, "doubled_word": _op_doubled_word,
       "lower_i": _op_lower_i, "no_final": _op_no_final}


def apply_mess(toks: List[Tok], rng: random.Random, level: str) -> List[dict]:
    """Apply typing ops until the level's error budget is reached. Returns the op counts."""
    counts: Dict[str, int] = {}
    n_words = max(1, sum(1 for t in toks if t.tgt is not None))
    budget = max(2, round(LEVELS[level]["errors_per_100"] * n_words / 100.0))  # non-guard rows change at least two words
    if level == "L0":
        return []
    names = [n for n, _ in OP_WEIGHTS]
    weights = [w * (2.5 if (level == "L4" and n == "garble") else 1.0) for n, w in OP_WEIGHTS]
    errors = 0
    tries = 0
    while errors < budget and tries < budget * 20:
        tries += 1
        name = rng.choices(names, weights)[0]
        if name == "garble" and level not in ("L3", "L4"):
            continue
        ok = OPS[name](toks, rng, counts)
        if ok:
            errors += GARBLE_COST if name == "garble" else 1  # a garbled run damages two or three words
    return [{"op": k, "n": v} for k, v in counts.items()]


def damaged_words(inp: str, tgt: str) -> Tuple[int, int]:
    """Words in the target that the input does not show intact (case, apostrophes and punctuation ignored)."""
    def norm(s):
        return [re.sub(r"[^a-z0-9]", "", w.lower()) for w in re.findall(r"\S+", s)]
    a, b = norm(inp), norm(tgt)
    bag = Counter(a)
    bad = 0
    for w in b:
        if bag[w] > 0:
            bag[w] -= 1
        else:
            bad += 1
    return bad, max(1, len(b))


def build_row(idx: int, level: str, seed: int, attempt: int, pool: List[str]) -> dict:
    rng = sub_rng(f"typing-v2:{level}", idx, attempt, seed)
    toks: List[Tok] = []
    for template in [rng.choice(pool) for _ in range(rng.randint(1, 2))]:
        toks.extend(tokens_from_template(template, rng, 0.0))
    target = join_target(toks)
    if level == "L0":
        inp = target
        ops = []
    else:
        ops = apply_mess(toks, rng, level)
        inp = join_input(toks)
    ops = ops + [{"op": "mess_level", "n": level}]
    return {
        "id": f"typ2-{idx:05d}-{level}",
        "task": "polish",
        "control_line": control_line("polish"),
        "input": inp,
        "target": target,
        "protected": protected_entries(toks),
        "ops": ops,
    }


def generate(n: int, seed: int = SEED) -> Iterator[dict]:
    pool = typed_templates(max(600, n * 2), seed)
    plan = level_plan(n, seed)
    for idx, level in enumerate(plan):
        for attempt in range(MAX_ATTEMPTS):
            row = build_row(idx, level, seed, attempt, pool)
            if check_row(row):
                continue
            if level != "L0":
                bad, total = damaged_words(row["input"], row["target"])
                if bad < 2:  # a non-guard row must change at least two words
                    continue
            yield row
            break
        else:
            raise RuntimeError(f"row {idx} ({level}) failed {MAX_ATTEMPTS} attempts")


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--out", default=None)
    args = ap.parse_args(argv)
    rows = list(generate(args.n, args.seed))
    text = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {len(rows)} rows to {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
