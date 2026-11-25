"""Runs the 40 Wispr-pilot texts through the local engines with bench/flow_bench.py.

No Wispr, no Mac focus, no keys. The texts are invented. The bench scorer needs expected outputs,
which these texts do not have, so only the checks that apply are reported:
- nonempty output;
- every protected value kept (numbers, names, negations; "dont" also accepts "don't");
- invented content words (flow_bench's own check, with no expected text);
- clean inputs left unchanged (none of the 40 texts is clean, so this is reported as n/a).
The bench's full table is still written by flow_bench into bench/runs/.
"""
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SUITE = "wispr-pilot40"
ENGINES = ["identity", "rules", "s1mini", "dose1"]
PILOT = HERE / "drivers" / "pilot_manifest.json"
OUT = Path.home() / "Library/Application Support/VOICE/T2Inputs/wispr-pilot/bench40-summary.json"
ALIASES = {"dont": "dont|don't", "cant": "cant|can't", "wont": "wont|won't",
           "shouldnt": "shouldnt|shouldn't", "didnt": "didnt|didn't"}


def load_bench():
    spec = importlib.util.spec_from_file_location("flow_bench", REPO / "bench" / "flow_bench.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_cases():
    manifest = json.loads(PILOT.read_text())
    cases = []
    for it in manifest["text_items"]:
        must = [ALIASES.get(p, p) for p in it["protected"]]
        cases.append({"id": it["id"], "raw": it["text"], "expect": "", "category": "wispr-pilot",
                      "level": None, "kind": "pilot-text", "must_contain": must})
    return cases


def main():
    fb = load_bench()
    cases = build_cases()
    engines = fb.load_engines()
    run_id = fb.make_run_id("wispr40")
    summary = {"suite": SUITE, "n": len(cases), "run_id": run_id, "engines": {}}
    for name in ENGINES:
        rec, rows, table, _private = fb.run_engine(name, SUITE, cases, run_id, engines)
        n = len(rows)
        empty = sum(1 for r in rows if r.get("empty"))
        kept = sum(1 for r in rows if not r.get("facts_lost"))
        invented = sum(1 for r in rows if r.get("invented"))
        errors = sum(1 for r in rows if r.get("error"))
        secs = sorted(r["seconds"] for r in rows if r.get("seconds") is not None)
        summary["engines"][name] = {
            "label": rec.get("label", name), "n": n, "nonempty": n - empty, "errors": errors,
            "protected_kept": kept, "protected_lost": n - kept, "outputs_with_invented_words": invented,
            "median_s": round(secs[len(secs) // 2], 3) if secs else None,
            "under_load": rec.get("under_load"), "model_sha": rec.get("model_sha256", rec.get("sha256")),
        }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    print(json.dumps(summary["engines"], indent=1, ensure_ascii=False))
    print("summary:", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
