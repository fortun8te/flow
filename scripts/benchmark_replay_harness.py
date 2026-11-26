#!/usr/bin/env python3
"""Compare replay retention/write memory and deadline behavior on invented data.

Loads only the supplied local Git commit's replay/export source. No model, real
dictation, downloads or production server is used. JSONL lives in a temporary
directory and is deleted. The report goes to stdout; no inference speed claim.
"""
import argparse
import gc
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tracemalloc
import types

import export_flow_runs as export
import run_flow_candidate as replay

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "533db16c4c449132337916ee9fe78ae8235aae08"
sys.path.insert(0, str(ROOT / "Tests"))
from test_flow_replay_transport import case, completion, local_server


def historical_module(revision, filename):
    module = types.ModuleType("historical_" + Path(filename).stem)
    module.__file__ = str(ROOT / filename)
    source = subprocess.check_output(["git", "show", revision + ":" + filename], cwd=ROOT, text=True)
    exec(compile(source, module.__file__, "exec"), module.__dict__)
    return module


def memory_measurement(previous, previous_export, count, repetitions, output_bytes):
    cases = []
    for index in range(count):
        row = {"id": str(index), "input": "invented violet kettle",
               "target": (f"Invented violet kettle {index:04d}. " + "violet " * (output_bytes // 7 + 1))[:output_bytes],
               "kind": "dictation"}
        row["caseHash"] = export.case_hash(row)
        cases.append(row)

    def invoke(row):
        return {"id": row["id"], "caseHash": row["caseHash"], "output": row["target"].encode().decode(),
                "error": None, "finish_reason": "stop", "latencyMs": 10, "completionTokens": 100}

    results = []
    with tempfile.TemporaryDirectory(prefix="flow-invented-benchmark-") as directory:
        for name, module in (("before", previous), ("after", replay)):
            gc.collect()
            tracemalloc.start()
            rows = module.replay_cases(cases, invoke, module.benchmark_protocol(repetitions=repetitions), "invented-model", "invented-dataset")
            path = Path(directory) / (name + ".jsonl")
            if name == "before":
                previous_export.write_private(path, "".join(export.canonical(row) + "\n" for row in rows))
                fingerprint = export.digest("".join(export.canonical(row) + "\n" for row in rows))
            else:
                fingerprint = export.write_private_jsonl(path, rows)["sha256"]
            retained, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
            results.append({"version": name, "peakPythonMiB": peak / 1024**2, "retainedPythonMiB": retained / 1024**2,
                            "cases": len(rows), "attempts": sum(len(row["attempts"]) for row in rows),
                            "fileBytes": path.stat().st_size, "sha256": fingerprint})
            del rows
    if results[0]["sha256"] != results[1]["sha256"]:
        raise ValueError("invented outputs differ; memory results cannot claim equivalent evidence")
    return results


def deadline_measurement(previous):
    def drip(handler):
        payload = json.dumps(completion()).encode()
        handler.send_response(200)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        for index in range(0, len(payload), 2):
            handler.wfile.write(payload[index:index + 2])
            handler.wfile.flush()
            time.sleep(0.02)

    results = []
    for name, module in (("before", previous), ("after", replay)):
        with local_server(drip) as (endpoint, server):
            started = time.perf_counter()
            row = module.request_case(case(), endpoint, "invented-cleanup", "Edit.", 0.08, 64)
            results.append({"version": name, "declaredDeadlineMs": 80,
                            "observedElapsedMs": (time.perf_counter() - started) * 1000,
                            "error": row["error"], "requests": len(server.requests)})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=BASELINE, help="full SHA of a trusted commit already in this local repository")
    parser.add_argument("--cases", type=int, default=250)
    parser.add_argument("--repetitions", type=int, default=12)
    parser.add_argument("--output-bytes", type=int, default=8192)
    args = parser.parse_args()
    if (not re.fullmatch(r"[0-9a-f]{40}", args.baseline) or not 1 <= args.cases <= 10000
            or not 1 <= args.repetitions <= 50 or not 1 <= args.output_bytes <= replay.MAX_RESPONSE_BYTES
            or args.cases * args.repetitions * args.output_bytes > 256 * 1024**2):
        parser.error("use a full commit SHA, positive bounded workload and at most 256 MiB of repeated payloads")
    previous = historical_module(args.baseline, "scripts/run_flow_candidate.py")
    previous_export = historical_module(args.baseline, "scripts/export_flow_runs.py")
    print(json.dumps({"baselineCommit": args.baseline, "python": sys.version.split()[0],
                      "scope": "Invented Python replay retention/write allocations and HTTP deadline failure behavior; no model inference.",
                      "outputBytesPerCase": args.output_bytes,
                      "memory": memory_measurement(previous, previous_export, args.cases, args.repetitions, args.output_bytes),
                      "slowDrip": deadline_measurement(previous)}, indent=2))


if __name__ == "__main__":
    main()
