#!/usr/bin/env python3
"""Export Flow's local run records as training pairs.

Reads ~/Library/Application Support/VOICE/training/runs*.jsonl (written by FlowRunLog.swift), joins each
run with its follow-up lines (Undo, Original shown, edited after paste) and writes, under ~/flow-train/runs/:

  runs-joined.jsonl      every run with its follow-ups attached (the full record, for analysis)
  dictation-pairs.jsonl  {"input": raw ASR, "rules": rules text, "model": cleanup output, "output": pasted,
                          "target": the field after his edit, else the pasted text, "label": ...}
  opt1-pairs.jsonl       {"input": selection, "model": model edit, "output": applied text, "target", "label"}
  stage-pairs.jsonl      one row per text stage: {"stage", "input", "output", "changes"} (tinyfix, tinynext...)

Labels: "edited" (he changed the paste: the edited field is the target), "undone" (he undid it: keep the
input as the target), "accepted" (pasted and left alone), or the run's outcome when it never landed.
Everything stays on this Mac. Nothing is uploaded.

Usage: python3 scripts/export_flow_runs.py [--source DIR] [--out DIR] [--since YYYY-MM-DD]
"""
import argparse
import glob
import json
import os
import sys

DEFAULT_SOURCE = os.path.expanduser("~/Library/Application Support/VOICE/training")
DEFAULT_OUT = os.path.expanduser("~/flow-train/runs")


def read_records(source):
    # Rotated files first (runs-<sequence>-<date>.jsonl sort oldest first), then the live file.
    files = sorted(glob.glob(os.path.join(source, "runs-*.jsonl"))) + [os.path.join(source, "runs.jsonl")]
    for path in files:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def join(records):
    runs, followups = {}, []
    for record in records:
        if record.get("kind") == "followup":
            followups.append(record)
        else:
            runs[record["id"]] = dict(record, followups=[])
    # Opt+1 follow-ups from the Changes card carry the diff id; map it to the run.
    by_diff = {r.get("settings", {}).get("diffID"): r for r in runs.values() if r.get("settings", {}).get("diffID")}
    for f in followups:
        run = runs.get(f["id"]) or by_diff.get(f["id"])
        if run is not None:
            run["followups"].append({k: f[k] for k in ("followup", "editedText", "recordedAt") if k in f})
    return list(runs.values())


def stage_text(run, name):
    for stage in run.get("stages", []):
        if stage.get("name") == name and stage.get("text") is not None:
            return stage["text"]
    return None


def label(run):
    kinds = [f.get("followup") for f in run["followups"]]
    if any(k in ("undo", "undo-and-retry", "undo-paste") for k in kinds):
        return "undone"
    if "edited" in kinds:
        return "edited"
    outcome = run.get("outcome") or ""
    if outcome in ("verified", "applied", "unconfirmed", "unchanged") or outcome.startswith("readback"):
        return "accepted"
    return outcome or "unknown"


def target(run):
    edits = [f.get("editedText") for f in run["followups"] if f.get("followup") == "edited" and f.get("editedText")]
    if edits:
        return edits[-1]
    if label(run) == "undone":
        return run.get("input")
    return run.get("output")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--since", help="only runs recorded on or after this date (YYYY-MM-DD)")
    args = parser.parse_args()

    runs = join(read_records(args.source))
    if args.since:
        runs = [r for r in runs if (r.get("recordedAt") or "") >= args.since]
    os.makedirs(args.out, exist_ok=True)
    counts = {"runs": len(runs), "dictation": 0, "opt1": 0, "stages": 0}
    with open(os.path.join(args.out, "runs-joined.jsonl"), "w", encoding="utf-8") as joined, \
         open(os.path.join(args.out, "dictation-pairs.jsonl"), "w", encoding="utf-8") as dictation, \
         open(os.path.join(args.out, "opt1-pairs.jsonl"), "w", encoding="utf-8") as opt1, \
         open(os.path.join(args.out, "stage-pairs.jsonl"), "w", encoding="utf-8") as stages:
        for run in runs:
            joined.write(json.dumps(run, ensure_ascii=False) + "\n")
            if not run.get("input"):
                continue
            base = {"id": run["id"], "app": run.get("app"), "recordedAt": run.get("recordedAt"),
                    "label": label(run), "models": run.get("models", {}), "fallback": run.get("fallbackReason")}
            if run.get("kind") == "dictation":
                row = dict(base, input=run["input"], rules=stage_text(run, "rules"), model=stage_text(run, "cleanup"),
                           output=run.get("output"), target=target(run), asrWords=run.get("asrWords"))
                dictation.write(json.dumps(row, ensure_ascii=False) + "\n")
                counts["dictation"] += 1
            elif run.get("kind") == "opt1":
                row = dict(base, input=run["input"],
                           model=stage_text(run, "opt1.model") or stage_text(run, "opt1.polish") or stage_text(run, "polish"),
                           output=run.get("output"), target=target(run))
                opt1.write(json.dumps(row, ensure_ascii=False) + "\n")
                counts["opt1"] += 1
            previous = run["input"]
            for stage in run.get("stages", []):
                text = stage.get("text")
                if text is None:
                    continue
                if text != previous:
                    stages.write(json.dumps({"id": run["id"], "kind": run.get("kind"), "stage": stage.get("name"),
                                             "input": previous, "output": text, "changes": stage.get("changes")},
                                            ensure_ascii=False) + "\n")
                    counts["stages"] += 1
                previous = text
    print(f"{counts['runs']} runs: {counts['dictation']} dictation pairs, {counts['opt1']} Opt+1 pairs, "
          f"{counts['stages']} stage pairs -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
