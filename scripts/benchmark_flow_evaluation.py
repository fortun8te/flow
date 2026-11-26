#!/usr/bin/env python3
"""Synthetic evaluator/serializer microbenchmark; never invokes a model.

Example: python3 scripts/benchmark_flow_evaluation.py --baseline-ref 533db16
The baseline score function comes from the requested commit in this checkout.
Both scorers use the current exact text metrics, isolating repeated-output work.
"""
import argparse
import ast
import gc
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time
import tracemalloc

import export_flow_runs as export
import flow_hillclimb as hill

ROOT = Path(__file__).resolve().parents[1]


def old_scorer(reference):
    commit = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", reference + "^{commit}"],
                                     cwd=ROOT, text=True).strip()
    source = subprocess.check_output(["git", "show", commit + ":scripts/flow_hillclimb.py"], cwd=ROOT, text=True)
    function = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == "score")
    namespace = dict(vars(hill))
    exec(compile(ast.Module(body=[function], type_ignores=[]), "baseline-score", "exec"), namespace)
    return commit, namespace["score"]


def fixtures(count, words, repetitions):
    workload = []
    for index in range(count):
        tokens = [f"invented{index}word{word}" for word in range(words)]
        target = "\n".join(" ".join(tokens[start:start + 40]) for start in range(0, words, 40))
        edited = [token if word % 17 else "variant" + token for word, token in enumerate(tokens)]
        output = "\n".join(" ".join(edited[start:start + 40]) for start in range(0, words, 40))
        case = {"id": f"synthetic-{index}", "target": target, "requireExactLayout": index % 4 == 0,
                "mustContain": [tokens[1]], "mustNotContain": ["forbidden invented phrase"]}
        samples = [{"output": output, "latencyMs": 100 + sample, "finish_reason": "stop"} for sample in range(repetitions)]
        prediction = {"output": output, "latencyMs": statistics.median(item["latencyMs"] for item in samples),
                      "finish_reason": "stop", "attempts": samples}
        workload.append((case, prediction))
    return workload


def score_all(scorer, workload):
    return [scorer(case, prediction) for case, prediction in workload]


def measured_score(scorer, workload):
    started = time.perf_counter()
    score_all(scorer, workload)
    return time.perf_counter() - started


def old_writer(path, rows):
    contents = "".join(export.canonical(row) + "\n" for row in rows)
    export.write_private(path, contents)
    return {"sha256": export.digest(contents), "rows": len(rows)}


def measured_writer(writer, path, rows):
    gc.collect()
    tracemalloc.start()
    try:
        result = writer(path, rows)
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    return result, peak


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--cases", type=int, default=80)
    parser.add_argument("--words", type=int, default=400)
    parser.add_argument("--repetitions", type=int, default=6)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--export-rows", type=int, default=5000)
    args = parser.parse_args()
    if min(args.cases, args.repetitions, args.trials, args.export_rows) < 1 or args.words < 2:
        parser.error("positive workload/trial counts and at least two words are required")
    commit, baseline = old_scorer(args.baseline_ref)
    workload = fixtures(args.cases, args.words, args.repetitions)
    if score_all(baseline, workload) != score_all(hill.score, workload):
        raise ValueError("scoring changed; do not interpret these timings as an equivalent optimization")
    timings = {"baseline": [], "current": []}
    for trial in range(args.trials):
        scorers = [("baseline", baseline), ("current", hill.score)]
        for label, scorer in scorers if trial % 2 == 0 else reversed(scorers):
            timings[label].append(measured_score(scorer, workload))
    baseline_ms = 1000 * statistics.median(timings["baseline"])
    current_ms = 1000 * statistics.median(timings["current"])
    rows = [{"id": f"synthetic-{index}", "input": "invented text " * 80,
             "target": "Independently reviewed invented text " * 40} for index in range(args.export_rows)]
    with tempfile.TemporaryDirectory(prefix="flow-evaluation-benchmark-") as temporary:
        path = Path(temporary) / "synthetic.jsonl"
        before, before_peak = measured_writer(old_writer, path, rows)
        after, after_peak = measured_writer(export.write_private_jsonl, path, rows)
        if before != after:
            raise ValueError("serialization byte hash or row count changed")
        size = path.stat().st_size
    print(json.dumps({
        "scope": "synthetic offline evaluator and JSONL serialization; no model or device inference measurement",
        "baselineCommit": commit, "python": platform.python_version(), "platform": platform.platform(),
        "scoring": {"cases": args.cases, "wordsPerCase": args.words, "identicalAttemptsPerCase": args.repetitions,
                    "alternatingTrials": args.trials, "resultEquality": True, "baselineMedianMs": baseline_ms,
                    "currentMedianMs": current_ms, "ratioBaselineOverCurrent": baseline_ms / current_ms},
        "serialization": {"rows": args.export_rows, "bytes": size, "hashAndCountEquality": True,
                          "baselinePeakExtraPythonBytes": before_peak, "currentPeakExtraPythonBytes": after_peak,
                          "scope": "tracemalloc peak extra allocations; input rows already materialized, excludes process RSS"},
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
