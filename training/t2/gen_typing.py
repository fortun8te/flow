#!/usr/bin/env python3
"""Generate DOSE1 T2 typed rows for the Opt+1 "fix only" task (typo reconstruction).

Each row starts as clean typed text (the target: shorthand and slang kept, as Jordan's tone
does). Typing ops add keystroke errors to the input. Protected values (numbers, money, dates,
times, names, links, emails, negations) are never typo'd; only their apostrophe and casing move.
Guard rows (no typing errors) are identity rows. Rows that fail check_t2.check_row are redrawn.

  python3 gen_typing.py --n 80 --seed 20261114 --out samples/typing.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from typing import Dict, Iterator, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seeds_public as S  # noqa: E402
from check_t2 import check_row  # noqa: E402
from t2_common import (SEED, TYPE_RATES, Tok, control_line, join_input, join_target,  # noqa: E402
                       protected_entries, sub_rng, tokens_from_template, typing_ops)

# Category weights for 80 rows.
WEIGHTS: Dict[str, int] = {"chat": 18, "email": 16, "notes": 8, "slang": 12, "dutch": 8, "mixed": 6, "guard": 12}
MAX_ATTEMPTS = 8
SOURCES = {
    "chat": (S.TYPED_CHAT, 1, 2),
    "email": (S.TYPED_EMAIL, 1, 2),
    "notes": (S.TYPED_NOTES, 1, 3),
    "slang": (S.TYPED_SLANG, 1, 3),
    "dutch": (S.TYPED_DUTCH, 1, 2),
    "mixed": (S.TYPED_MIXED, 1, 2),
    "guard": (S.TYPED_CHAT + S.TYPED_EMAIL, 1, 2),
}


def category_plan(weights: Dict[str, int], n: int, seed: int) -> List[str]:
    total = sum(weights.values())
    raw = {k: n * v / total for k, v in weights.items()}
    counts = {k: int(x) for k, x in raw.items()}
    leftover = n - sum(counts.values())
    for k in sorted(raw, key=lambda k: raw[k] - counts[k], reverse=True)[:leftover]:
        counts[k] += 1
    plan = [k for k in weights for _ in range(counts[k])]
    sub_rng("typing-plan", 0, 0, seed).shuffle(plan)
    return plan


def build_row(idx: int, category: str, seed: int, attempt: int) -> dict:
    rng = sub_rng(f"typing:{category}", idx, attempt, seed)
    pool, lo, hi = SOURCES[category]
    toks: List[Tok] = []
    for template in [rng.choice(pool) for _ in range(rng.randint(lo, hi))]:
        # Typed templates never get random self-correction; the rate is 0 here.
        toks.extend(tokens_from_template(template, rng, 0.0))
    if category == "guard":
        ops = [{"op": "identity", "n": 1}]
        heavy = False
    else:
        heavy = rng.random() < TYPE_RATES["heavy_row_share"]
        ops = typing_ops(toks, rng, category, heavy)
        if heavy:
            ops.append({"op": "heavy_row", "n": 1})
    target = join_target(toks)
    inp = target if category == "guard" else join_input(toks)
    return {
        "id": f"typ-{idx:05d}-{category}",
        "task": "polish",
        "control_line": control_line("polish"),
        "input": inp,
        "target": target,
        "protected": protected_entries(toks),
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
    ap.add_argument("--n", type=int, default=80)
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
