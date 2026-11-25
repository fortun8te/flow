#!/usr/bin/env python3
"""Dictation generator v2 for DOSE1 T2 (B1a). The old gen_dictation.py is unchanged.

Uses the following measured rates:
  soft fillers removed by cleanup  3.3 per 100 words (was 2.6)
  um and uh share of fillers       8% (rare, as measured)
  immediate repeats                0.35 per 100 words (was 0.4)
  dash or ellipsis cut-offs        0.02 per 100 words (was 0.15)
  self-correction cue rows         3.4%
  all-lowercase rows               8%, rows with no final punctuation 27%
Source of the templates: seed_bank.dictation_templates (450 distinct, spoken style).

The rates were measured on Wispr speech text. Re-measure them on the target corpus before training.

  python3 gen_dictation_v2.py --n 200 --seed 20261114 --out samples/dictation_v2.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from typing import Dict, Iterator, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_t2 import check_row  # noqa: E402
from seed_bank import dictation_templates  # noqa: E402
from t2_common import (DICT_RATES, SEED, control_line, dictation_ops, join_input, join_target,  # noqa: E402
                       protected_entries, sub_rng, tokens_from_template)

RATES_V2: Dict[str, float] = dict(DICT_RATES)
RATES_V2.update({
    "soft_filler_per_100": 3.3,
    "repeat_per_token": 0.0035,
    "cutoff_per_token": 0.0002,
    "lowercase_row": 0.08,
    "drop_final_punct": 0.27,
    "self_correction_per_slot": 0.034,
})
SELF_CORRECTION_ROW_RATE = 0.034
MAX_ATTEMPTS = 10


def build_row(idx: int, seed: int, attempt: int, pool: List[str]) -> dict:
    rng = sub_rng("dictation-v2", idx, attempt, seed)
    clean = [t for t in pool if "{CORR_" not in t]
    corr = [t for t in pool if "{CORR_" in t]
    if rng.random() < SELF_CORRECTION_ROW_RATE:
        toks = tokens_from_template(rng.choice(corr), rng, 0.0, explicit_url_protocol=True)  # the CORR_ slot makes the correction
    else:
        toks = tokens_from_template(rng.choice(clean), rng, 0.0, explicit_url_protocol=True)
    toks, ops = dictation_ops(toks, rng, RATES_V2, dutch=False)
    target = join_target(toks)
    return {
        "id": f"dct2-{idx:05d}",
        "task": "clean",
        "control_line": control_line("clean"),
        "input": join_input(toks),
        "target": target,
        "protected": protected_entries(toks),
        "ops": ops,
    }


def generate(n: int, seed: int = SEED) -> Iterator[dict]:
    pool = dictation_templates(max(450, n), seed)
    for idx in range(n):
        for attempt in range(MAX_ATTEMPTS):
            row = build_row(idx, seed, attempt, pool)
            if not check_row(row):
                yield row
                break
        else:
            raise RuntimeError(f"row {idx} failed the checker {MAX_ATTEMPTS} times")


def stats(rows: List[dict]) -> Dict[str, float]:
    """Realised synthetic operations, with word counts over input text.

    Filler phrases such as "sort of" and "I mean" are one sampled insertion,
    not missing from the denominator because a word-proxy list omitted them.
    Already-authored target words are not measured as injected disfluencies.
    """
    words = fillers = uhum = repeats = cutoffs = lower = nofinal = corr = 0
    for r in rows:
        w = re.findall(r"[A-Za-z']+", r["input"])
        words += len(w)
        fillers += sum(o["n"] for o in r["ops"] if o.get("op") == "filler")
        noise = {"um", "uh", "erm", "uhm", "eh", "ehm"}
        uhum += max(0, sum(x.lower() in noise for x in w) -
                    sum(x.lower() in noise for x in re.findall(r"[A-Za-z']+", r["target"])))
        repeats += sum(1 for a, b in zip(w, w[1:]) if a.lower() == b.lower())
        cutoffs += len(re.findall(r"(—|–|\.\.\.)", r["input"]))
        lower += r["input"] == r["input"].lower() and bool(r["input"])
        nofinal += r["input"][-1:] not in ".?!" if r["input"] else 0
        corr += any(o.get("op") == "self_correction" for o in r["ops"])
    n = max(1, len(rows))
    return {
        "rows": len(rows),
        "words": words,
        "filler_insertions": fillers,
        "um_uh_insertions": uhum,
        "soft_fillers_per_100_words": round(100 * fillers / max(1, words), 2),
        "um_uh_share_of_fillers": round(uhum / max(1, fillers), 3),
        "repeats_per_100_words": round(100 * repeats / max(1, words), 3),
        "cutoffs_per_100_words": round(100 * cutoffs / max(1, words), 3),
        "lowercase_rows": round(lower / n, 3),
        "rows_without_final_punct": round(nofinal / n, 3),
        "self_correction_rows": round(corr / n, 3),
    }


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=200)
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
    print(json.dumps(stats(rows)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
