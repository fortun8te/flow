#!/usr/bin/env python3
"""Calibration numbers for typing v2 and dictation v2 (aggregates only, no text). Writes samples/stats_v2.json.

  python3 measure_v2.py [--n 2000]
"""
import argparse
import collections
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gen_dictation_v2 as gd  # noqa: E402
import gen_typing_v2 as g  # noqa: E402
from check_t2 import check_row  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    args = ap.parse_args(argv)
    rows = list(g.generate(args.n, 20261114))
    by = collections.defaultdict(lambda: {"rows": 0, "words": 0, "ops": 0, "damaged": 0, "shares": []})
    for r in rows:
        lvl = [o["n"] for o in r["ops"] if o["op"] == "mess_level"][0]
        d, t = g.damaged_words(r["input"], r["target"])
        b = by[lvl]
        b["rows"] += 1
        b["words"] += t
        b["ops"] += sum(o["n"] for o in r["ops"] if o["op"] != "mess_level")
        b["damaged"] += d
        b["shares"].append(d / t)
    out = {"typing": {"generator": "gen_typing_v2.py", "seed": 20261114, "rows": len(rows),
                      "checker_failures": sum(1 for r in rows if check_row(r)), "levels": {}}}
    for lvl in g.LEVEL_ORDER:
        b = by[lvl]
        out["typing"]["levels"][lvl] = {
            "share_realised": round(b["rows"] / len(rows), 3), "share_table": g.LEVELS[lvl]["share"],
            "ops_per_100_words": round(100 * b["ops"] / max(1, b["words"]), 1),
            "ops_per_100_table": g.LEVELS[lvl]["errors_per_100"],
            "damaged_word_share_pooled": round(b["damaged"] / max(1, b["words"]), 3),
            "damaged_word_share_row_mean": round(statistics.mean(b["shares"]), 3),
            "rows_with_third_or_more_damaged": round(sum(1 for x in b["shares"] if x >= 1 / 3) / len(b["shares"]), 3)}
    drows = list(gd.generate(1000, 20261114))
    out["dictation"] = {"generator": "gen_dictation_v2.py", "rows": len(drows),
                        "checker_failures": sum(1 for r in drows if check_row(r)),
                        "measured_on_input": gd.stats(drows),
                        "table": {k: gd.RATES_V2[k] for k in ("soft_filler_per_100", "repeat_per_token",
                                                             "cutoff_per_token", "lowercase_row", "drop_final_punct")}}
    (HERE / "samples/stats_v2.json").write_text(json.dumps(out, indent=1))
    print(json.dumps(out["typing"]["levels"], indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
