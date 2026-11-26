#!/usr/bin/env python3
"""Freeze and screen private, same-audio native Wispr/Flow captures offline.

Inputs are manually supplied declarations, not independently attested captures.
This tool records no audio, operates no app, uploads nothing and promotes nothing.
HTTP cleanup timings are incompatible with its native insertion protocol.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import statistics

from export_flow_runs import canonical, digest, write_private
from flow_hillclimb import aggregate, load_dataset, parse_jsonl, positive_number, score, sign_test

SHA256 = re.compile(r"[0-9a-f]{64}\Z")
POLICY = {"minIndependentFamilies": 50, "minRepetitions": 3, "minRelativeImprovement": 0.02,
          "maxOneSidedSignP": 0.05, "maxP95LatencyRatio": 1.10}
BINDINGS = ("matchID", "caseHash", "audioSHA256", "contextSHA256", "vocabularySHA256")
CAPTURE_SUMMARY = ("systemID", "captureSHA256", "manifestSHA256", "modelAttribution", "canto2Claimed")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def timestamp(value):
    require(nonempty(value), "review/capture timestamp missing")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.tzinfo is not None and result.utcoffset() is not None, "timestamp must include timezone")
    return result


def stable_file(path, keep=False):
    """Hash actual regular-file bytes, refusing a replacement or edit during read."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode), "capture inputs must be regular files")
        hasher, chunks = hashlib.sha256(), []
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
            if keep:
                chunks.append(chunk)
        signature = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        require(signature(before) == signature(os.fstat(handle.fileno())) == signature(os.stat(path, follow_symlinks=False)),
                "input changed while reading; freeze a stable snapshot")
    return hasher.hexdigest(), b"".join(chunks), before.st_size


def json_file(path):
    return json.loads(stable_file(path, keep=True)[1])


def validate_protocol(protocol):
    require(isinstance(protocol, dict) and protocol.get("schemaVersion") == 1, "unsupported native protocol")
    require(protocol.get("measurement") == "key-release-to-verified-insertion"
            and protocol.get("clock") == "monotonic_ns" and nonempty(protocol.get("clockSessionID")),
            "native end-to-end monotonic event timing required; HTTP cleanup timing is not accepted")
    require(protocol.get("order") == "paired-alternating-rounds" and protocol.get("initialState") in ("ready", "cold"),
            "declare paired alternating rounds and the shared initial application state")
    require(type(protocol.get("repetitions")) is int and 3 <= protocol["repetitions"] <= 50,
            "native captures require 3 to 50 complete repetitions")
    require(positive_number(protocol.get("timeoutMs")) and positive_number(protocol.get("maxP95Ms")),
            "finite positive timeout and absolute p95 budget required")
    environment = protocol.get("environment")
    require(isinstance(environment, dict) and all(nonempty(environment.get(key)) for key in
            ("hardware", "os", "power", "targetApp", "targetAppVersion", "audioRoute", "network")),
            "pin hardware, OS, power, target application, audio route and network condition")


def dictation_cases(manifest, cases):
    selected = sorted((case for case in cases if case.get("kind") == "dictation"), key=lambda item: item["id"])
    require(selected and all(nonempty(case.get("groupID")) for case in selected), "reviewed dictation families are required")
    return selected


def freeze(manifest, cases, split, audio_map, protocol, base=Path(".")):
    validate_protocol(protocol)
    require(split in ("valid", "test"), "use held-out validation or test cases")
    cases = dictation_cases(manifest, cases)
    expected, supplied = {case["id"]: case for case in cases}, {}
    for row in audio_map:
        identifier = row.get("id")
        require(isinstance(identifier, str) and identifier in expected and identifier not in supplied,
                "audio map has missing, unknown or duplicate case id")
        supplied[identifier] = row
    require(supplied.keys() == expected.keys(), "audio map must cover the complete held-out dictation subset")
    frozen, slice_names = [], {}
    for case in cases:
        row = supplied[case["id"]]
        require(row.get("caseHash") == case["caseHash"], "audio map uses a stale reviewed target")
        hashes = {}
        for name in ("audio", "context", "vocabulary"):
            require(nonempty(row.get(name + "Path")), "audio, context and vocabulary files must be explicit")
            fingerprint, _, size = stable_file(Path(base) / row[name + "Path"])
            require(name != "audio" or size > 0, "audio cannot be empty")
            hashes[name + "SHA256"] = fingerprint
        review = row.get("audioReview")
        require(isinstance(review, dict) and review.get("source") == "audio-human-reviewed"
                and review.get("targetMatchesAudio") is True and review.get("independentOfSystems") is True
                and nonempty(review.get("reviewerID")) and review.get("caseHash") == case["caseHash"]
                and review.get("audioSHA256") == hashes["audioSHA256"], "independent human audio/target review required")
        timestamp(review.get("reviewedAt"))
        slices = row.get("slices", [])
        require(isinstance(slices, list) and all(nonempty(value) for value in slices), "slice labels must be strings")
        slices = slices + ["kind:dictation", "app:" + (case.get("app") or "unknown")]
        if case.get("mustContain") or case.get("mustNotContain"):
            slices.append("protected-literals")
        slice_names.update({digest(value): value for value in slices})
        frozen.append({"id": case["id"], "caseHash": case["caseHash"], **hashes,
                       "textFamilyID": digest(case["groupID"]), "sliceIDs": sorted({digest(value) for value in slices}),
                       "audioReviewSHA256": digest(canonical(review))})
    match = {"schemaVersion": 1, "datasetID": manifest["datasetID"], "split": split,
             "protocol": protocol, "protocolID": digest(canonical(protocol)), "cases": frozen,
             "sliceDefinitions": slice_names}
    match["matchID"] = digest(canonical(match))
    return match


def validate_match(match, manifest, cases):
    require(isinstance(match, dict) and match.get("schemaVersion") == 1, "unsupported frozen match")
    require(match.get("matchID") == digest(canonical({key: value for key, value in match.items() if key != "matchID"})),
            "frozen match hash mismatch")
    validate_protocol(match.get("protocol"))
    require(match.get("protocolID") == digest(canonical(match["protocol"]))
            and match.get("datasetID") == manifest["datasetID"] and match.get("split") in ("valid", "test"),
            "match does not identify the current dataset and native protocol")
    cases = dictation_cases(manifest, cases)
    frozen = match.get("cases")
    require(isinstance(frozen, list) and len(frozen) == len(cases), "match must cover every dictation case")
    definitions = match.get("sliceDefinitions")
    require(isinstance(definitions, dict) and all(isinstance(key, str) and SHA256.fullmatch(key) and nonempty(value)
                                               for key, value in definitions.items()), "match slice definitions invalid")
    for case, binding in zip(cases, frozen):
        require(isinstance(binding, dict) and binding.get("id") == case["id"] and binding.get("caseHash") == case["caseHash"]
                and binding.get("textFamilyID") == digest(case["groupID"]), "match case/family identity changed")
        require(all(isinstance(binding.get(key), str) and SHA256.fullmatch(binding[key]) for key in
                    ("audioSHA256", "contextSHA256", "vocabularySHA256", "audioReviewSHA256")), "match evidence hash missing")
        require(isinstance(binding.get("sliceIDs"), list) and binding["sliceIDs"]
                and all(isinstance(value, str) and value in definitions for value in binding["sliceIDs"]), "match slices missing")
    return cases


def human_review(sample, row, match):
    review = sample.get("humanReview")
    if review is None:
        return None
    require(isinstance(review, dict) and review.get("source") == "blind-human" and review.get("blindToSystem") is True
            and nonempty(review.get("reviewerID")) and review.get("matchID") == match["matchID"]
            and review.get("caseHash") == row["caseHash"] and review.get("outputSHA256") == sample["outputSHA256"]
            and type(review.get("readyToSend")) is bool and type(review.get("meaningPreserved")) is bool,
            "blind review must bind this exact match, case and output")
    timestamp(review.get("reviewedAt"))
    return review


def load_capture(path, match, product):
    content_hash, contents, _ = stable_file(path, keep=True)
    manifest_path = Path(str(path) + ".manifest.json")
    metadata_hash, data, _ = stable_file(manifest_path, keep=True)
    metadata = json.loads(data)
    require(isinstance(metadata, dict) and metadata.get("schemaVersion") == 1
            and metadata.get("capturesSHA256") == content_hash, "complete capture manifest/hash required")
    identity = metadata.get("identity")
    require(isinstance(identity, dict) and identity.get("product") == product
            and all(nonempty(identity.get(key)) for key in ("version", "build", "collectorID"))
            and isinstance(identity.get("configuration"), dict) and identity["configuration"]
            and (identity.get("modelName") is None or isinstance(identity["modelName"], str))
            and metadata.get("systemID") == digest(canonical(identity)), "immutable native product/version/configuration identity required")
    protocol = match["protocol"]
    require(metadata.get("matchID") == match["matchID"] and metadata.get("protocolID") == match["protocolID"]
            and metadata.get("environmentID") == digest(canonical(protocol["environment"]))
            and metadata.get("clockSessionID") == protocol["clockSessionID"]
            and metadata.get("captureType") == "native-dictation" and metadata.get("retainedAllAttempts") is True,
            "capture must declare the frozen native environment, clock and complete attempted workload")
    start, end = timestamp(metadata.get("startedAt")), timestamp(metadata.get("completedAt"))
    require(end > start, "capture completion must follow its start")
    attribution = "unverified"
    protected_inputs = [Path(path), manifest_path]
    evidence_hash = identity.get("modelEvidenceSHA256")
    if evidence_hash is not None:
        require(isinstance(evidence_hash, str) and SHA256.fullmatch(evidence_hash)
                and nonempty(metadata.get("modelEvidencePath")), "model attribution requires its retained evidence file")
        evidence_path = manifest_path.parent / metadata["modelEvidencePath"]
        require(stable_file(evidence_path)[0] == evidence_hash,
                "model evidence file does not match its declared hash")
        protected_inputs.append(evidence_path)
        attribution = "evidence-supplied"
    expected, captures = {row["id"]: row for row in match["cases"]}, {}
    for row in parse_jsonl(contents.decode("utf-8"), "native captures"):
        identifier = row.get("id")
        require(isinstance(identifier, str) and identifier in expected and identifier not in captures, "unknown or duplicate capture case")
        binding = {**expected[identifier], "matchID": match["matchID"]}
        require(all(row.get(key) == binding[key] for key in BINDINGS)
                and row.get("systemID") == metadata["systemID"] and row.get("protocolID") == match["protocolID"],
                "capture audio/context/vocabulary/case/system binding mismatch")
        samples = row.get("attempts")
        require(isinstance(samples, list) and len(samples) == protocol["repetitions"], "retain every repetition, including failures")
        for index, sample in enumerate(samples):
            require(isinstance(sample, dict) and type(sample.get("sampleIndex")) is int and sample["sampleIndex"] == index,
                    "missing, duplicate or reordered sample index")
            released, completed = sample.get("keyReleasedNs"), sample.get("completedNs")
            require(type(released) is int and released >= 0 and type(completed) is int and completed > released
                    and positive_number(sample.get("elapsedMs"))
                    and math.isclose(sample["elapsedMs"], (completed - released) / 1_000_000, rel_tol=1e-9, abs_tol=1e-6),
                    "elapsed time must match retained monotonic key-release/completion events")
            require(isinstance(sample.get("output"), str) and sample.get("outputSHA256") == digest(sample["output"]),
                    "capture must retain and hash the actual output, including failed output")
            outcome = sample.get("outcome")
            require(outcome in ("inserted", "failed", "timeout") and type(sample.get("insertionVerified")) is bool
                    and sample["insertionVerified"] == (outcome == "inserted"), "outcome/verified insertion disagreement")
            require(outcome != "timeout" or sample["elapsedMs"] >= protocol["timeoutMs"], "timeout sample is shorter than its deadline")
            require(outcome == "timeout" or sample["elapsedMs"] <= protocol["timeoutMs"], "late completion must retain a timeout outcome")
            human_review(sample, row, match)
        captures[identifier] = row
    require(captures.keys() == expected.keys() and metadata.get("cases") == len(expected)
            and metadata.get("attempts") == len(expected) * protocol["repetitions"], "capture workload is incomplete")
    attempts = [sample for row in captures.values() for sample in row["attempts"]]
    total_ms = sum(sample["elapsedMs"] for sample in attempts)
    span_ms = (max(sample["completedNs"] for sample in attempts) - min(sample["keyReleasedNs"] for sample in attempts)) / 1000000
    require(max(total_ms, span_ms) <= (end - start).total_seconds() * 1000 + 1, "event durations/span exceed declared capture wall time")
    return {"rows": captures, "systemID": metadata["systemID"], "captureSHA256": content_hash,
            "manifestSHA256": metadata_hash, "modelAttribution": attribution,
            "canto2Claimed": re.sub(r"[\s_-]+", "", (identity.get("modelName") or "").casefold()) == "canto2",
            "protectedInputs": protected_inputs}


def independent_families(bindings):
    parent, owners = list(range(len(bindings))), {}
    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index
    for index, row in enumerate(bindings):
        for key in ("audioSHA256", "textFamilyID"):
            token = (key, row[key])
            if token in owners:
                parent[find(index)] = find(owners[token])
            owners[token] = index
    groups = defaultdict(list)
    for index in range(len(bindings)):
        groups[find(index)].append(index)
    return list(groups.values())


def scored(case, row, match):
    samples = [{"output": item["output"], "latencyMs": item["elapsedMs"],
                "finish_reason": "stop" if item["outcome"] == "inserted" else item["outcome"]}
               for item in row["attempts"]]
    result = score(case, {"attempts": samples, "latencyMs": statistics.median(item["latencyMs"] for item in samples)})
    result["reviews"] = [human_review(item, row, match) for item in row["attempts"]]
    return result


def metrics(rows):
    result = aggregate(rows)
    reviews = [review for row in rows for review in row["reviews"] if review is not None]
    result.update(reviewedAttempts=len(reviews),
                  readyToSendReviewedRate=sum(review["readyToSend"] for review in reviews) / len(reviews) if reviews else None,
                  meaningPreservedReviewedRate=sum(review["meaningPreserved"] for review in reviews) / len(reviews) if reviews else None)
    return result


def compare(match, cases, baseline, candidate):
    protocol, bindings = match["protocol"], match["cases"]
    require(baseline["systemID"] != candidate["systemID"], "systems require distinct immutable identities")
    # Both products share one clock session. Enforce actual alternating paired
    # order, not merely an asserted order or independent morning/evening runs.
    previous_end = -1
    for repetition in range(protocol["repetitions"]):
        for binding in bindings:
            for run in (baseline, candidate) if repetition % 2 == 0 else (candidate, baseline):
                attempt = run["rows"][binding["id"]]["attempts"][repetition]
                require(attempt["keyReleasedNs"] >= previous_end, "captures overlap or violate frozen paired round order")
                previous_end = attempt["completedNs"]
    before = [scored(case, baseline["rows"][case["id"]], match) for case in cases]
    after = [scored(case, candidate["rows"][case["id"]], match) for case in cases]
    a, b = metrics(before), metrics(after)
    families = independent_families(bindings)
    differences = [sum(before[index]["edits"] - after[index]["edits"] for index in group) for group in families]
    wins, losses = sum(value > 0 for value in differences), sum(value < 0 for value in differences)
    probability = sign_test(wins, losses)
    improvement = (a["tokenErrorRate"] - b["tokenErrorRate"]) / a["tokenErrorRate"] if a["tokenErrorRate"] else 0
    reviewed = all(review is not None for row in before + after for review in row["reviews"])
    preserves_exact = all(old["output"] != case["target"] or new["output"] == case["target"]
                          for case in cases for old, new in zip(baseline["rows"][case["id"]]["attempts"],
                                                               candidate["rows"][case["id"]]["attempts"]))
    human_safe = reviewed and all(new["meaningPreserved"] and (not old["readyToSend"] or new["readyToSend"])
                                 for old_row, new_row in zip(before, after) for old, new in zip(old_row["reviews"], new_row["reviews"]))
    slices = {}
    for identifier in sorted({value for row in bindings for value in row["sliceIDs"]}):
        indices = [index for index, row in enumerate(bindings) if identifier in row["sliceIDs"]]
        slices[identifier] = {"baseline": metrics([before[index] for index in indices]),
                              "candidate": metrics([after[index] for index in indices])}
    gates = {"enoughIndependentFamilies": len(families) >= POLICY["minIndependentFamilies"],
             "completeBlindHumanReview": reviewed, "qualityImproved": improvement >= POLICY["minRelativeImprovement"],
             "pairedEvidence": probability <= POLICY["maxOneSidedSignP"], "noCriticalFailures": b["criticalCases"] == 0,
             "preservesPreviousExactOutputs": preserves_exact, "noHumanRegression": human_safe,
             "noSliceRegression": all(item["candidate"]["tokenErrorRate"] <= item["baseline"]["tokenErrorRate"] for item in slices.values()),
             "p95WithinBudget": b["p95Ms"] <= protocol["maxP95Ms"] and b["p95Ms"] <= a["p95Ms"] * POLICY["maxP95LatencyRatio"]}
    root = Path(__file__).resolve().parents[1]
    evaluator_sources = {name: stable_file(root / name)[0] for name in (
        "scripts/flow_competition.py", "scripts/flow_hillclimb.py", "scripts/export_flow_runs.py", "bench/text_metrics.py")}
    report = {"schemaVersion": 1, "matchID": match["matchID"], "datasetID": match["datasetID"], "split": match["split"],
              "evaluatorSources": evaluator_sources, "evaluatorSHA256": digest(canonical(evaluator_sources)),
              "eligibleForReview": all(gates.values()), "status": "screened" if reviewed else "descriptive-only",
              "promoted": False, "beatsCompetitor": False, "policy": POLICY, "gates": gates,
              "baseline": a, "candidate": b, "relativeImprovement": improvement,
              "independentFamilies": len(families), "familyWins": wins, "familyLosses": losses, "pairedSignP": probability,
              "baselineIdentity": {key: baseline[key] for key in CAPTURE_SUMMARY},
              "candidateIdentity": {key: candidate[key] for key in CAPTURE_SUMMARY}, "slices": slices,
              "limitation": "Manual capture, configuration, audio review and blinding declarations are not attested. No general superiority, model attribution or release claim follows from this screening."}
    report["comparisonID"] = digest(canonical(report))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    freeze_parser, compare_parser = commands.add_parser("freeze"), commands.add_parser("compare")
    for command in (freeze_parser, compare_parser):
        command.add_argument("--dataset-dir", required=True)
        command.add_argument("--out", required=True)
    freeze_parser.add_argument("--split", choices=("valid", "test"), default="valid")
    for argument in ("audio-map", "protocol"):
        freeze_parser.add_argument("--" + argument, required=True)
    for argument in ("match", "baseline", "candidate"):
        compare_parser.add_argument("--" + argument, required=True)
    args = parser.parse_args()
    try:
        protected = [Path(args.dataset_dir) / name for name in ("manifest.json", "train.jsonl", "valid.jsonl", "test.jsonl", "split-lock.json")]
        if args.command == "freeze":
            manifest, cases = load_dataset(args.dataset_dir, args.split)
            rows = parse_jsonl(stable_file(args.audio_map, keep=True)[1].decode("utf-8"), "audio map")
            base = Path(args.audio_map).parent
            protected += [Path(args.audio_map), Path(args.protocol)]
            protected += [base / row[name + "Path"] for row in rows for name in ("audio", "context", "vocabulary")]
            report = freeze(manifest, cases, args.split, rows, json_file(args.protocol), base)
        else:
            match = json_file(args.match)
            manifest, cases = load_dataset(args.dataset_dir, match["split"])
            cases = validate_match(match, manifest, cases)
            baseline, candidate = load_capture(args.baseline, match, "wispr"), load_capture(args.candidate, match, "flow")
            protected += [Path(args.match), *baseline["protectedInputs"], *candidate["protectedInputs"]]
            report = compare(match, cases, baseline, candidate)
        require(Path(args.out).resolve() not in {path.resolve() for path in protected}, "output must not overwrite any input")
        write_private(args.out, canonical(report) + "\n")
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        parser.exit(2, f"Native comparison refused: {error}\n")
    print("Frozen native comparison" if args.command == "freeze" else
          ("Eligible for human review; no promotion" if report["eligibleForReview"] else "Not eligible for review"))
    return 0 if args.command == "freeze" or report["eligibleForReview"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
