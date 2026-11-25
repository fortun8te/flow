#!/usr/bin/env python3
"""One comparison table across engines and public suites, read from the run files. Prints Markdown.

  python3 bench/summary.py 20261114-174327-baseline 20261114-175331-baseline 20261114-174448-baseline

Private runs are not summarised here: their numbers stay under VOICE.
"""
import importlib.util
import json
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("flow_bench", BENCH / "flow_bench.py")
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)

ORDER = ["s1mini", "stock", "dose1", "rules", "identity"]


def main(run_ids):
    print("| suite | engine | n | fully right | facts lost | invented | restraint | zero-edit | added /100 | "
          "fillers removed | self-corr | budget trips | latency median | latency p95 | under load |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for rid in run_ids:
        for run_json in sorted((BENCH / "runs" / rid).glob("*/run.json"), key=lambda p: ORDER.index(json.loads(p.read_text())["engine"])):
            rec = json.loads(run_json.read_text())
            rows = [json.loads(x) for x in (run_json.parent / "cases.jsonl").read_text().splitlines()]
            s = fb.summarise(rows)
            print(f"| {rec['suite']} | {rec['label']} | {s['n']} | {s['fully_right']}/{s['n']} | {s['facts_lost']} | "
                  f"{s['invented']} | {s['restraint_ok']}/{s['restraint_n']} | {fb.pct(s['zero_edit'], s['n'])} | "
                  f"{s['added_per_100']} | {s['fillers_removed']}/{s['fillers_in']} | {s['self_corr_ok']}/{s['self_corr_n']} | "
                  f"{s['budget_trips']} | {s['lat_median']} | {s['lat_p95']} | {'yes' if rec.get('under_load') else 'no'} |")


if __name__ == "__main__":
    main(sys.argv[1:])
