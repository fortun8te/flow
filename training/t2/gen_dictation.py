#!/usr/bin/env python3
"""Generate DOSE1 T2 dictation rows: messy dictation (S1), no-edit guards (N) and filler-only rows.

Each row starts as clean text (the target). Ops corrupt it into what a recogniser would hear.
Rows that fail check_t2.check_row are redrawn with a new attempt index, never edited.

  python3 gen_dictation.py --n 120 --seed 20261114 --out samples/dictation.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from collections import Counter
from typing import Dict, Iterator, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seeds_public as S  # noqa: E402
from check_t2 import check_row  # noqa: E402
from t2_common import (DICT_RATES, DUTCH_SOFT_FILLERS, EMPTY, SEED, SOFT_FILLERS, UHUM_FILLERS, Tok,  # noqa: E402
                       control_line, dictation_ops, join_input, join_target, protected_entries,
                       sub_rng, tokens_from_template, whole_sentence_token)

# Category weights for 120 rows. "no_edit" is the N guard; "filler_only" becomes target EMPTY.
WEIGHTS: Dict[str, int] = {
    "prose": 28, "meeting": 12, "recipe": 8, "ramble": 14, "self_correction": 14,
    "literal_cue": 8, "instruction": 6, "no_edit": 8, "filler_only": 3, "dutch": 6, "mixed": 5, "long": 8,
}
MAX_ATTEMPTS = 8


def category_plan(weights: Dict[str, int], n: int, seed: int) -> List[str]:
    total = sum(weights.values())
    raw = {k: n * v / total for k, v in weights.items()}
    counts = {k: int(x) for k, x in raw.items()}
    leftover = n - sum(counts.values())
    for k in sorted(raw, key=lambda k: raw[k] - counts[k], reverse=True)[:leftover]:
        counts[k] += 1
    plan = [k for k in weights for _ in range(counts[k])]
    sub_rng("plan", 0, 0, seed).shuffle(plan)
    return plan


def _pick(rng: random.Random, pool: List[str], lo: int, hi: int) -> List[str]:
    return [rng.choice(pool) for _ in range(rng.randint(lo, hi))]


def _clean_tokens(category: str, rng: random.Random) -> List[Tok]:
    rate = DICT_RATES["self_correction_per_slot"]
    if category == "literal_cue":
        return [whole_sentence_token(s, "literal_cue") for s in _pick(rng, S.LITERAL_CUE, 1, 2)]
    if category == "instruction":
        return [whole_sentence_token(s, "instruction_text") for s in _pick(rng, S.INSTRUCTION, 1, 1)]
    pools = {
        "prose": (S.PROSE, 1, 3), "meeting": (S.MEETING, 1, 2), "recipe": (S.RECIPE, 1, 2),
        "ramble": (S.RAMBLE, 1, 2), "self_correction": (S.SELF_CORRECTION, 1, 2),
        "no_edit": (S.PROSE, 1, 2), "dutch": (S.DUTCH, 2, 3), "mixed": (S.MIXED, 1, 2),
        "filler_only": (S.PROSE, 1, 1),
    }
    if category == "long":
        longpool = S.PROSE + S.MEETING + S.RAMBLE + S.RECIPE
        toks: List[Tok] = []
        for _ in range(14):
            toks.extend(tokens_from_template(rng.choice(longpool), rng, rate))
            if sum(1 for t in toks if t.tgt is not None) >= 170:
                break
        return toks
    pool, lo, hi = pools[category]
    # Correction slots: the forced category always corrects; other categories only at the random rate.
    corr = 0.0 if category == "no_edit" else rate
    if category == "self_correction":
        corr = 1.0
    toks: List[Tok] = []
    for sentence in _pick(rng, pool, lo, hi):
        toks.extend(tokens_from_template(sentence, rng, corr))
    return toks


def _filler_only_tokens(rng: random.Random) -> List[Tok]:
    words = []
    for _ in range(rng.randint(2, 5)):
        pick = rng.random()
        if pick < 0.45:
            words.append(rng.choice(UHUM_FILLERS))
        elif pick < 0.8:
            words.append(rng.choice(SOFT_FILLERS).lower())
        else:
            words.append(rng.choice(DUTCH_SOFT_FILLERS))
    return [Tok(text=w, tgt=None) for w in words]


def build_row(idx: int, category: str, seed: int, attempt: int) -> dict:
    rng = sub_rng(f"dictation:{category}", idx, attempt, seed)
    if category == "filler_only":
        toks = _filler_only_tokens(rng)
        ops = [{"op": "filler_only", "n": len(toks)}]
        target, inp, prot = EMPTY, " ".join(t.text for t in toks), []
    else:
        toks = _clean_tokens(category, rng)
        if category == "no_edit":
            ops = [{"op": "identity", "n": 1}]
        else:
            toks, ops = dictation_ops(toks, rng, DICT_RATES, dutch=(category in ("dutch", "mixed")))
        target = join_target(toks)
        inp = join_input(toks)
        if category == "no_edit":
            inp = target
        prot = protected_entries(toks)
    return {
        "id": f"dct-{idx:05d}-{category}",
        "task": "clean",
        "control_line": control_line("clean"),
        "input": inp,
        "target": target,
        "protected": prot,
        "ops": ops,
    }


def generate(n: int, seed: int = SEED) -> Iterator[dict]:
    plan = category_plan(WEIGHTS, n, seed)
    for idx, category in enumerate(plan):
        for attempt in range(MAX_ATTEMPTS):
            row = build_row(idx, category, seed, attempt)
            if not check_row(row):
                yield row
                break
        else:
            raise RuntimeError(f"row {idx} ({category}) failed the checker {MAX_ATTEMPTS} times")


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=120)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--out", default=None, help="JSONL path; stdout if omitted")
    args = ap.parse_args(argv)
    rows = list(generate(args.n, args.seed))
    text = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {len(rows)} rows to {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    print(json.dumps({"rows": len(rows), "categories": dict(Counter(r["id"].split("-")[-1] for r in rows))}),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
