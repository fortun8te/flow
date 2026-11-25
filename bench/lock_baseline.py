#!/usr/bin/env python3
"""Writes a lock file for the current baseline: case files, scorer files, engine hashes and run ids."""
import glob
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "bench"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(lock_id, run_ids):
    lock = {"lock_id": lock_id, "scorer_version": "flow_bench-1.0",
            "scorer_files": {str(p.relative_to(ROOT)): sha(p) for p in [
                ROOT / "bench/flow_bench.py", ROOT / "scripts/score-polish-eval.py", ROOT / "bench/wn_metrics.py"]},
            "case_files": {str(p.relative_to(ROOT)): sha(p) for p in sorted((BENCH / "cases").glob("*.json"))},
            "runs": {}}
    for rid in run_ids:
        for run_json in sorted(glob.glob(str(BENCH / "runs" / rid / "*/run.json"))):
            rec = json.loads(Path(run_json).read_text())
            lock["runs"].setdefault(rid, {})[rec["engine"]] = {
                k: rec.get(k) for k in ("suite", "kind", "label", "gguf_sha256", "template_sha256", "weights_sha256_first_file",
                                        "system_prompt_sha256", "control_line", "max_tokens_rule", "decoding",
                                        "load_avg_start", "under_load", "load_s", "wall_s", "cases")}
    out = BENCH / "locks" / f"{lock_id}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(lock, indent=1, ensure_ascii=False))
    print(out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
