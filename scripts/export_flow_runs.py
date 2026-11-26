#!/usr/bin/env python3
"""Export private Flow observations and independently labelled training examples.

Paste verification is delivery evidence, never approval of model quality. Only
explicit human-reviewed labels become supervised targets. Observed corrections,
old field-wide edits, unchanged output and Undo remain observations for review.

Usage: python3 scripts/export_flow_runs.py [--source DIR] [--out DIR] [--labels FILE]
Repeat with the same output directory to preserve split-lock.json. Every export
rebuilds the snapshot, so a later Undo can remove an earlier training label.
Nothing is uploaded. Do not commit any generated output.
"""
import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
from datetime import datetime, timezone
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata

DEFAULT_SOURCE = os.path.expanduser("~/Library/Application Support/VOICE/training")
DEFAULT_OUT = os.path.expanduser("~/flow-train/runs")
EXPORT_SCHEMA = 2
SPLIT_POLICY = "flow-grouped-v1-80-10-10"
UNDO = {"undo", "undo-and-retry", "undo-paste", "rejected"}
SCOPES = {"dictation": "pasted-span", "opt1": "selection"}
INTEGRITY_ERRORS = {"invalidJSON", "invalidRecord", "unknownKind", "sourceReadError", "sourceChanged"}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalized(text):
    """Group case/spacing/punctuation variants, plus identical corrected targets."""
    return " ".join(re.findall(r"\w+", unicodedata.normalize("NFKC", text).casefold()))


def fingerprint(text):
    return digest(normalized(text))


def case_hash(row):
    content = {key: row[key] for key in ("input", "target", "kind")}
    content.update({key: row.get(key, []) for key in ("mustContain", "mustNotContain")})
    return digest(canonical(content))


def read_records(source, diagnostics=None):
    diagnostics = diagnostics if diagnostics is not None else Counter()
    def snapshot():
        files = sorted(glob.glob(os.path.join(source, "runs-*.jsonl")))
        live = os.path.join(source, "runs.jsonl")
        if os.path.exists(live):
            files.append(live)
        result = {}
        for path in files:
            try:
                stat = os.stat(path)
                result[path] = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
            except OSError:
                diagnostics["sourceReadError"] += 1
        return result

    initial = snapshot()
    for path in initial:
        try:
            with open(path, "rb") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        record = json.loads(line)
                    except (json.JSONDecodeError, UnicodeError):
                        diagnostics["invalidJSON"] += 1
                        continue
                    if not isinstance(record, dict) or not isinstance(record.get("id"), str) or not record["id"]:
                        diagnostics["invalidRecord"] += 1
                        continue
                    if not valid_record(record):
                        diagnostics["invalidRecord"] += 1
                        continue
                    yield record
        except OSError:
            diagnostics["sourceReadError"] += 1
    if initial != snapshot():
        diagnostics["sourceChanged"] += 1


def valid_record(record):
    if record.get("kind") == "followup" and (not isinstance(record.get("followup"), str) or not record["followup"]):
        return False
    for key in ("kind", "input", "output", "recordedAt", "followup", "editedText", "targetScope", "feedbackSource", "outcome"):
        if record.get(key) is not None and not isinstance(record[key], str):
            return False
    for key in ("settings", "models", "timingsMs"):
        if key in record and not isinstance(record[key], dict):
            return False
    diff_id = record.get("settings", {}).get("diffID")
    if diff_id is not None and not isinstance(diff_id, str):
        return False
    for key in ("stages", "decisions"):
        if key in record and (not isinstance(record[key], list) or any(not isinstance(item, dict) for item in record[key])):
            return False
    return True


def join(records, diagnostics=None):
    diagnostics = diagnostics if diagnostics is not None else Counter()
    runs, followups = {}, []
    for record in records:
        if record.get("kind") == "followup":
            followups.append(record)
        elif record.get("kind") in SCOPES:
            old = runs.get(record["id"])
            if old:
                diagnostics["duplicateRunID"] += 1
            conflict = old and (old.get("input"), old.get("kind")) != (record.get("input"), record.get("kind"))
            run = dict(record, followups=[])
            if conflict or (old and old.get("conflictingRunID")):
                run["conflictingRunID"] = True
            runs[record["id"]] = run
        else:
            diagnostics["unknownKind"] += 1
    # A non-unique Changes card id must not attach feedback to an arbitrary run.
    diff_runs = defaultdict(list)
    for run in runs.values():
        diff_id = (run.get("settings") or {}).get("diffID")
        if diff_id:
            diff_runs[diff_id].append(run)
    seen = set()
    for followup in followups:
        signature = canonical(followup)
        if signature in seen:
            continue
        seen.add(signature)
        matches = diff_runs.get(followup["id"], [])
        run = runs.get(followup["id"])
        if run is None and len(matches) == 1:
            run = matches[0]
        if run is None:
            diagnostics["unmatchedFollowup"] += 1
            for match in matches:
                match["ambiguousFeedback"] = True
            continue
        fields = ("followup", "editedText", "recordedAt", "feedbackSource", "targetScope", "schemaVersion")
        run["followups"].append({key: followup[key] for key in fields if key in followup})
    for run in runs.values():
        run["followups"].sort(key=lambda item: item.get("recordedAt") or "")
    return sorted(runs.values(), key=lambda item: (item.get("recordedAt") or "", item["id"]))


def apply_labels(runs, path, diagnostics):
    """External labels are explicit review records, bound to the exact raw input."""
    if path is None:
        return
    by_id = {run["id"]: run for run in runs}
    seen = set()
    with open(path, encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            entry = json.loads(line)
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
                raise ValueError(f"label line {line_number}: missing id")
            if entry["id"] in seen:
                raise ValueError(f"label line {line_number}: duplicate id")
            seen.add(entry["id"])
            run = by_id.get(entry["id"])
            if run is None:
                diagnostics["unmatchedReviewedLabel"] += 1
                continue
            raw = run.get("input")
            if not isinstance(raw, str) or entry.get("inputHash") != digest(raw):
                raise ValueError(f"label line {line_number}: inputHash does not match run")
            if entry.get("source") != "human-reviewed" or entry.get("scope") != SCOPES[run["kind"]]:
                raise ValueError(f"label line {line_number}: explicit human-reviewed source and matching scope required")
            value = entry.get("target")
            if not isinstance(value, str) or not value.strip() or len(value) > 20_000:
                raise ValueError(f"label line {line_number}: nonempty bounded target required")
            for key in ("mustContain", "mustNotContain"):
                literals = entry.get(key, [])
                if not isinstance(literals, list) or any(not isinstance(text, str) or not text or len(text) > 500
                                                         for text in literals):
                    raise ValueError(f"label line {line_number}: {key} must be a list of nonempty literal strings")
                if any((text in value) != (key == "mustContain") for text in literals):
                    raise ValueError(f"label line {line_number}: {key} contradicts the reviewed target")
            run["reviewedLabel"] = entry


def stage_text(run, name):
    return next((stage["text"] for stage in run.get("stages", [])
                 if stage.get("name") == name and isinstance(stage.get("text"), str)), None)


def supervision(run):
    """Return (label, target, provenance); never infer approval from a successful paste."""
    feedback = run.get("followups", [])
    if any(item.get("followup") in UNDO for item in feedback):
        return "undone", None, None
    if run.get("conflictingRunID"):
        return "conflicting-run-id", None, None
    if run.get("sourceIntegrityBlocked"):
        return "source-integrity-unverified", None, None
    if run.get("ambiguousFeedback"):
        return "ambiguous-feedback", None, None
    reviewed = run.get("reviewedLabel")
    if reviewed:
        return "human-reviewed", reviewed["target"], {
            "source": "human-reviewed", "scope": reviewed["scope"], "inputHash": reviewed["inputHash"]}
    for item in reversed(feedback):
        if item.get("followup") == "edited":
            if item.get("targetScope") == SCOPES.get(run.get("kind")):
                return "correction-candidate", None, None
            return "edited-unscoped", None, None
    outcome = run.get("outcome") or "unknown"
    if outcome in {"verified", "applied", "unchanged"}:
        return "observed-unchanged", None, None
    return outcome, None, None


def label(run):
    return supervision(run)[0]


def target(run):
    return supervision(run)[1]


def make_pair(run):
    verdict, expected, provenance = supervision(run)
    edits = [item for item in run.get("followups", []) if item.get("followup") == "edited"]
    last_edit = edits[-1] if edits else {}
    proposal = last_edit.get("editedText") if last_edit.get("targetScope") == SCOPES[run["kind"]] else None
    row = {"schemaVersion": EXPORT_SCHEMA, "id": run["id"], "kind": run["kind"],
           "app": run.get("app"), "recordedAt": run.get("recordedAt"), "flowBuild": run.get("flowBuild"),
           "flowVersion": run.get("flowVersion"), "pipelineVersion": run.get("pipelineVersion"),
           "sourceSHA256": run.get("sourceSHA256"),
           "label": verdict, "models": run.get("models", {}), "settings": run.get("settings", {}),
           "timingsMs": run.get("timingsMs", {}), "decisions": run.get("decisions", []),
           "fallback": run.get("fallbackReason"), "outcome": run.get("outcome"),
           "input": run["input"], "inputHash": digest(run["input"]), "output": run.get("output"),
           "target": expected, "proposedTarget": proposal, "targetProvenance": provenance,
           "trainingEligible": expected is not None, "inputFingerprint": fingerprint(run["input"])}
    row.update({key: (run.get("reviewedLabel") or {}).get(key, []) for key in ("mustContain", "mustNotContain")})
    # Existing runs provide audioPath; future/imported records can provide stronger recording identity.
    # Never open audio paths during text export. Renamed/copied audio needs a content hash or stable source id.
    recording_keys = []
    for key in ("audioSHA256", "sourceRecordingID", "recordingID", "audioPath"):
        value = run.get(key) or (run.get("settings") or {}).get(key)
        if isinstance(value, str) and value:
            recording_keys.append("recording:" + digest(key + "\0" + value))
    row["recordingKeys"] = sorted(set(recording_keys))
    if run["kind"] == "dictation":
        row.update(rules=stage_text(run, "rules"), model=stage_text(run, "cleanup"), asrWords=run.get("asrWords"))
    else:
        row["model"] = next((stage_text(run, name) for name in ("opt1.model", "opt1.polish", "polish")
                             if stage_text(run, name) is not None), None)
    return row


def split_examples(pairs, registry):
    """Group matching inputs OR targets. Preserve assignments across incremental exports.

    Connecting an old training group to a held-out group quarantines the component:
    neither a formerly trained text nor its reference can become a clean test case.
    """
    if registry.get("policy") != SPLIT_POLICY or not isinstance(registry.get("assignments"), dict):
        raise ValueError("unsupported split-lock.json; keep the old snapshot and review its split policy")
    assignments = dict(registry["assignments"])
    if any(value not in {"train", "valid", "test", "quarantine"} for value in assignments.values()):
        raise ValueError("invalid split assignment")
    candidates = [row for row in pairs if row["trainingEligible"]]
    by_input = defaultdict(list)
    for row in candidates:
        by_input[row["inputFingerprint"]].append(row)
    for rows in by_input.values():
        # Divergent labels for the same source need review, even across app/style settings.
        if len({row["target"] for row in rows}) > 1:
            for row in rows:
                row.update(trainingEligible=False, label="conflicting-human-targets", target=None)
    candidates = [row for row in candidates if row["trainingEligible"]]
    parent = {}

    def find(key):
        parent.setdefault(key, key)
        while parent[key] != key:
            parent[key] = parent[parent[key]]
            key = parent[key]
        return key

    # Keep historical family links, including examples no longer in rotated logs.
    # Otherwise a later cross-split bridge could taint only today's visible members.
    history = registry.get("groups", {})
    if not isinstance(history, dict) or any(not isinstance(key, str) or not isinstance(value, str)
                                          for key, value in history.items()):
        raise ValueError("invalid historical split groups")
    for key, group in history.items():
        parent[find(key)] = find(group)
    for row in candidates:
        a, b = row["inputFingerprint"], fingerprint(row["target"])
        root_a, root_b = find(a), find(b)
        parent[root_a] = root_b
        for recording_key in row.get("recordingKeys", []):
            parent[find(recording_key)] = find(a)
    components = defaultdict(set)
    for key in parent:
        components[find(key)].add(key)
    group_splits, group_ids = {}, {}
    for component, members in components.items():
        known = {assignments[key] for key in members if key in assignments}
        group_id = min(members)
        if len(known) > 1 or "quarantine" in known:
            split = "quarantine"
        elif known:
            split = next(iter(known))
        else:
            bucket = int(digest(SPLIT_POLICY + group_id)[:16], 16) % 1000
            split = "train" if bucket < 800 else "valid" if bucket < 900 else "test"
        group_splits[component], group_ids[component] = split, group_id
        assignments.update({key: split for key in members})
    dedup = {}
    for row in candidates:
        component = find(row["inputFingerprint"])
        row.update(groupID=group_ids[component], split=group_splits[component])
        if row["split"] == "quarantine":
            row.update(trainingEligible=False, label="split-contamination", target=None)
            continue
        # Retries of the same example are one vote, not extra training weight.
        key = (row["kind"], row["inputFingerprint"], row["target"])
        if key not in dedup:
            dedup[key] = dict(row, sourceRunIDs=[row["id"]])
        else:
            dedup[key]["sourceRunIDs"].append(row["id"])
            for field in ("mustContain", "mustNotContain"):
                dedup[key][field] = sorted(set(dedup[key].get(field, [])) | set(row.get(field, [])))
    examples = sorted(dedup.values(), key=lambda row: row["id"])
    for row in examples:
        row["sourceRunIDs"].sort()
        row["caseHash"] = case_hash(row)
    historical_groups = {key: group_ids[find(key)] for key in parent}
    return examples, {"schemaVersion": 1, "policy": SPLIT_POLICY, "assignments": assignments,
                      "groups": historical_groups}


def write_private(path, contents):
    """Atomic 0600 replacement, including when an older export had loose permissions."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=".flow-export-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def output_lock(out):
    """Serialize split-history updates across exporter processes on the recording Mac.

    Keep the inode in place: unlinking a flock file permits another writer to lock
    a replacement inode while a waiting process still holds the old one.
    """
    try:
        import fcntl
    except ImportError as error:
        raise ValueError("run export on macOS/Linux, where its split-history process lock is available") from error
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(out, 0o700)
    fd = os.open(out / ".export.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another Flow export is writing this output directory; wait for it to finish and rerun") from error
        os.fchmod(fd, 0o600)
        yield
    finally:
        # Closing releases the advisory lock, including when the export raises.
        os.close(fd)


def export(source, out, since=None, labels=None):
    if not Path(source).is_dir():
        raise ValueError("source must be an existing directory; no export was changed")
    with output_lock(out):
        return _export_locked(source, out, since, labels)


def _export_locked(source, out, since=None, labels=None):
    diagnostics = Counter()
    runs = join(read_records(source, diagnostics), diagnostics)
    integrity_errors = sorted(key for key in INTEGRITY_ERRORS if diagnostics[key])
    if integrity_errors:
        for run in runs:
            run["sourceIntegrityBlocked"] = True
    else:
        apply_labels(runs, labels, diagnostics)
    if since:
        datetime.strptime(since, "%Y-%m-%d")
        runs = [run for run in runs if (run.get("recordedAt") or "") >= since]
    out = Path(out)
    lock_path = out / "split-lock.json"
    if lock_path.exists():
        locked_content = lock_path.read_bytes().decode("utf-8")
        manifest_path = out / "manifest.json"
        if manifest_path.exists():
            prior = json.loads(manifest_path.read_bytes().decode("utf-8"))
            if digest(locked_content) != prior.get("splitLockSHA256"):
                raise ValueError("split-lock hash mismatch; restore the complete previous snapshot before exporting")
        registry = json.loads(locked_content)
    else:
        # Losing the lock after training is unsafe; never silently reshuffle an existing export.
        if (out / "manifest.json").exists():
            raise ValueError("split-lock.json is missing from an existing export; restore it before exporting")
        registry = {"schemaVersion": 1, "policy": SPLIT_POLICY, "assignments": {}}
    pairs = [make_pair(run) for run in runs if isinstance(run.get("input"), str) and run["input"].strip()]
    examples, registry = split_examples(pairs, registry)
    stages = []
    for run in runs:
        previous = run.get("input")
        for stage in run.get("stages", []):
            value = stage.get("text")
            if not isinstance(value, str):
                continue
            if isinstance(previous, str) and value != previous:
                stages.append({"id": run["id"], "kind": run["kind"], "stage": stage.get("name"),
                               "input": previous, "output": value, "changes": stage.get("changes"),
                               "trainingEligible": False, "label": "model-observation"})
            previous = value
    files = {"runs-joined.jsonl": runs, "stage-pairs.jsonl": stages,
             "dictation-pairs.jsonl": [row for row in pairs if row["kind"] == "dictation"],
             "opt1-pairs.jsonl": [row for row in pairs if row["kind"] == "opt1"],
             "review-queue.jsonl": [row for row in pairs if not row["trainingEligible"]]}
    files.update({split + ".jsonl": [row for row in examples if row["split"] == split]
                  for split in ("train", "valid", "test")})
    hashes = {}
    for name, rows in files.items():
        content = "".join(canonical(row) + "\n" for row in rows)
        write_private(out / name, content)
        hashes[name] = {"sha256": digest(content), "rows": len(rows)}
    write_private(lock_path, canonical(registry) + "\n")
    manifest = {"schemaVersion": EXPORT_SCHEMA, "createdAt": datetime.now(timezone.utc).isoformat(),
                "splitPolicy": SPLIT_POLICY, "files": hashes, "diagnostics": dict(diagnostics),
                "labels": dict(Counter(row["label"] for row in pairs)), "supervisedExamples": len(examples),
                "supervisedBlocked": bool(integrity_errors), "sourceIntegrityErrors": integrity_errors,
                "splitLockSHA256": digest(canonical(registry) + "\n"),
                "datasetID": digest(canonical({name: hashes[name] for name in ("train.jsonl", "valid.jsonl", "test.jsonl")}))}
    # The manifest is last: consumers verify hashes and fail on a partial snapshot.
    write_private(out / "manifest.json", canonical(manifest) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--labels", help="private JSONL of explicit human-reviewed labels, bound by id and inputHash")
    parser.add_argument("--since", help="only runs recorded on/after YYYY-MM-DD; retain the same split lock")
    args = parser.parse_args()
    try:
        manifest = export(args.source, args.out, args.since, args.labels)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, f"Export refused: {error}\n")
    print(f"{manifest['supervisedExamples']} independently labelled examples; "
          f"{manifest['files']['review-queue.jsonl']['rows']} observations awaiting review -> {args.out}")
    if manifest["diagnostics"]:
        print("Input diagnostics: " + canonical(manifest["diagnostics"]))
    if manifest["supervisedBlocked"]:
        parser.exit(2, "Supervised export blocked: source records are malformed, unreadable or changed during export. "
                       "Train/valid/test were emptied; observation diagnostics remain. "
                       "Freeze a complete stable source snapshot (or wait for the app write to finish), repair corruption "
                       "without dropping feedback, and rerun.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
