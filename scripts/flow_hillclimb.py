#!/usr/bin/env python3
"""Compare two local cleanup candidates against the same frozen reviewed cases.

This is an offline promotion gate, not a model downloader or automatic deployment.
Prediction JSONL rows require id, caseHash, datasetID, modelID, output and finite latencyMs.
The case hash binds predictions to input + human target + editing mode. Missing,
duplicate, stale or extra predictions fail closed. Use validation while tuning;
reserve test for the final frozen candidate. No real text is included in reports.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
import importlib.util
import math
from pathlib import Path
import re
import statistics

from export_flow_runs import EXPORT_SCHEMA, SPLIT_POLICY, canonical, case_hash, digest, write_private

_distance_spec = importlib.util.spec_from_file_location("flow_text_metrics", Path(__file__).resolve().parents[1] / "bench/text_metrics.py")
_distance_module = importlib.util.module_from_spec(_distance_spec)
_distance_spec.loader.exec_module(_distance_module)
edit_distance = _distance_module.edit_distance

TOKENS = re.compile(r"\w+|[^\w\s]|\n", re.UNICODE)
NEGATIONS = re.compile(r"\b(?:no|not|never|none|nothing|nobody|neither|nor|without|cannot|\w+n['’]t)\b", re.I)
NUMBERS = re.compile(r"(?<!\w)[+-]?\d+(?:[.,:/]\d+)*(?:%|\b)")
LITERALS = re.compile(r"https?://[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|`[^`\n]+`")


def read_jsonl(path):
    return parse_jsonl(Path(path).read_bytes().decode("utf-8"), Path(path).name)


def parse_jsonl(contents, label="predictions"):
    rows = []
    for number, line in enumerate(contents.splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{label}:{number}: expected an object")
        rows.append(value)
    return rows


def load_dataset(directory, split):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != EXPORT_SCHEMA or manifest.get("splitPolicy") != SPLIT_POLICY:
        raise ValueError("unsupported dataset manifest")
    if manifest.get("supervisedBlocked"):
        raise ValueError("dataset source integrity is unverified; freeze a complete stable source snapshot and re-export")
    name = split + ".jsonl"
    # Validate all supervised files so the identifier really describes this whole snapshot.
    verified = {}
    for filename in ("train.jsonl", "valid.jsonl", "test.jsonl"):
        content = (directory / filename).read_bytes().decode("utf-8")
        if digest(content) != manifest["files"][filename]["sha256"]:
            raise ValueError(f"{filename}: hash mismatch; export may be incomplete or edited")
        verified[filename] = content
    identity = digest(canonical({key: manifest["files"][key] for key in ("train.jsonl", "valid.jsonl", "test.jsonl")}))
    if identity != manifest.get("datasetID"):
        raise ValueError("datasetID does not match manifest")
    rows = parse_jsonl(verified[name], name)
    if len(rows) != manifest["files"][name]["rows"]:
        raise ValueError("dataset row count mismatch")
    seen = set()
    for row in rows:
        if not isinstance(row.get("id"), str) or row["id"] in seen:
            raise ValueError("missing or duplicate case id")
        seen.add(row["id"])
        if not row.get("trainingEligible") or row.get("label") != "human-reviewed" or row.get("split") != split:
            raise ValueError("evaluation requires independently reviewed examples in the requested split")
        if not isinstance(row.get("input"), str) or not isinstance(row.get("target"), str) or not row["target"].strip():
            raise ValueError("evaluation requires nonempty text targets")
        for key in ("mustContain", "mustNotContain"):
            literals = row.get(key, [])
            if not isinstance(literals, list) or any(not isinstance(value, str) or not value for value in literals):
                raise ValueError("literal constraints must be lists of nonempty strings")
            if any((value in row["target"]) != (key == "mustContain") for value in literals):
                raise ValueError("literal constraints contradict the reviewed target")
        expected = case_hash(row)
        if row.get("caseHash") != expected:
            raise ValueError("caseHash does not match the reviewed case")
    return manifest, rows


def positive_number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) and value > 0


def validate_protocol(protocol, protocol_id):
    if not isinstance(protocol, dict) or protocol_id != digest(canonical(protocol)):
        raise ValueError("benchmark protocol hash mismatch")
    count, repetitions = protocol.get("warmupRequests"), protocol.get("repetitions")
    if protocol.get("schemaVersion") != 2 or type(count) is not int or not 0 <= count <= 5:
        raise ValueError("unsupported benchmark warmup protocol")
    if type(repetitions) is not int or not 1 <= repetitions <= 50:
        raise ValueError("benchmark repetitions must be between 1 and 50")
    if protocol.get("concurrency") != 1 or protocol.get("order") != "dataset-rounds":
        raise ValueError("benchmark must use sequential complete-workload rounds")
    if not positive_number(protocol.get("timeoutSeconds")) or type(protocol.get("maxTokens")) is not int or protocol["maxTokens"] < 1:
        raise ValueError("benchmark request limits must be finite and positive")


def prediction_attempts(row):
    # A manually supplied one-shot prediction remains useful for quality inspection.
    # Repeated timing and engine tuning require the actual retained samples.
    return row.get("attempts") if row.get("attempts") is not None else [row]


def predictions_by_id(rows, cases, dataset_id=None):
    expected = {case["id"]: case for case in cases}
    predictions, models, protocols = {}, set(), set()
    for row in rows:
        identifier = row.get("id")
        if not isinstance(identifier, str) or identifier not in expected:
            raise ValueError("prediction has unknown or missing id")
        if identifier in predictions:
            raise ValueError("duplicate prediction id")
        if row.get("caseHash") != expected[identifier]["caseHash"]:
            raise ValueError("stale prediction: caseHash differs from the frozen case")
        if dataset_id is not None and row.get("datasetID") != dataset_id:
            raise ValueError("stale prediction: datasetID differs from the complete snapshot and context")
        if not isinstance(row.get("output"), str):
            raise ValueError("prediction output must be a string, including failures")
        latency = row.get("latencyMs")
        if not positive_number(latency):
            raise ValueError("prediction latencyMs must be finite and positive")
        model = row.get("modelID")
        if not isinstance(model, str) or not model.strip():
            raise ValueError("prediction modelID must identify weights, prompt and configuration")
        models.add(model)
        protocol = row.get("benchmarkProtocol")
        protocol_id = row.get("benchmarkProtocolID")
        if protocol is not None:
            validate_protocol(protocol, protocol_id)
            if row.get("warmupSucceeded") is not (protocol["warmupRequests"] > 0):
                raise ValueError("benchmark warmup calibration disagrees with its protocol")
        elif protocol_id is not None:
            raise ValueError("benchmark protocol content is missing")
        samples = row.get("attempts")
        if samples is not None:
            if protocol is None or not isinstance(samples, list) or len(samples) != protocol["repetitions"]:
                raise ValueError("prediction attempts must match the declared repetition count")
            for index, sample in enumerate(samples):
                if not isinstance(sample, dict) or sample.get("id") != identifier or sample.get("caseHash") != row["caseHash"]:
                    raise ValueError("attempt does not belong to the frozen prediction case")
                if type(sample.get("sampleIndex")) is not int or sample["sampleIndex"] != index:
                    raise ValueError("missing, duplicate or reordered attempt index")
                if not isinstance(sample.get("output"), str) or not positive_number(sample.get("latencyMs")):
                    raise ValueError("every attempted request requires text output and measured positive latency")
                for key in ("promptTokens", "completionTokens"):
                    if sample.get(key) is not None and (type(sample[key]) is not int or sample[key] < 0):
                        raise ValueError("usage token counts must be nonnegative integers or unavailable")
            if row["output"] != samples[0]["output"] or row.get("finish_reason") != samples[0].get("finish_reason"):
                raise ValueError("prediction header must retain the first attempt's output and finish status")
            if not math.isclose(latency, statistics.median(sample["latencyMs"] for sample in samples), rel_tol=1e-12):
                raise ValueError("prediction header latency must be the median of all retained attempts")
        elif protocol is not None and protocol["repetitions"] != 1:
            raise ValueError("repeated predictions require every attempt")
        protocols.add(protocol_id)
        predictions[identifier] = row
    if predictions.keys() != expected.keys():
        raise ValueError("missing predictions: compare exactly the same complete case set")
    if len(models) != 1:
        raise ValueError("each prediction file must identify exactly one candidate configuration")
    if len(protocols) != 1:
        raise ValueError("prediction file mixes different timing protocols")
    return predictions, next(iter(models)), next(iter(protocols))


def score(case, prediction):
    expected = case["target"]
    target_tokens = TOKENS.findall(expected)
    samples = prediction_attempts(prediction)
    faults = []
    if prediction.get("error"):
        faults.append("runtime_failure")
    if any(sample["output"] != samples[0]["output"] for sample in samples):
        faults.append("unstable_output")
    edits = 0
    for sample in samples:
        output = sample["output"]
        edits += edit_distance(target_tokens, TOKENS.findall(output))
        if sample.get("error") or sample.get("finish_reason") != "stop":
            faults.append("runtime_failure")
        if not output.strip():
            faults.append("empty_output")
        # Compare with independent corrected text; a human correction can change raw ASR facts.
        if NUMBERS.findall(expected) != NUMBERS.findall(output):
            faults.append("changed_number")
        if len(NEGATIONS.findall(expected)) != len(NEGATIONS.findall(output)):
            faults.append("changed_negation")
        if LITERALS.findall(expected) != LITERALS.findall(output):
            faults.append("changed_literal")
        for literal in case.get("mustContain", []):
            if literal not in output:
                faults.append("missing_required_text")
        for literal in case.get("mustNotContain", []):
            if literal in output:
                faults.append("forbidden_text")
    return {"id": case["id"], "edits": edits / len(samples),
            "tokens": max(1, len(target_tokens)), "latencyMs": prediction["latencyMs"],
            "latenciesMs": [sample["latencyMs"] for sample in samples],
            "critical": sorted(set(faults)), "exact": not faults and all(sample["output"] == expected for sample in samples)}


def percentile95(values):
    return sorted(values)[max(0, math.ceil(0.95 * len(values)) - 1)]


def aggregate(rows):
    latencies = [latency for row in rows for latency in row["latenciesMs"]]
    return {"cases": len(rows), "tokenErrorRate": sum(row["edits"] for row in rows) / sum(row["tokens"] for row in rows),
            "exactRate": sum(row["exact"] for row in rows) / len(rows),
            "latencySamples": len(latencies), "p50Ms": statistics.median(latencies), "p95Ms": percentile95(latencies),
            "criticalCases": sum(bool(row["critical"]) for row in rows),
            "criticalCounts": dict(Counter(fault for row in rows for fault in row["critical"]))}


def sign_test(wins, losses):
    """Exact one-sided paired sign test. Ties do not count as independent wins."""
    count = wins + losses
    if count == 0 or wins <= losses:
        return 1.0
    # log probabilities avoid overflowing 2**count on large personal datasets.
    return min(1.0, sum(math.exp(math.lgamma(count + 1) - math.lgamma(k + 1)
                                - math.lgamma(count - k + 1) - count * math.log(2))
                        for k in range(wins, count + 1)))


def compare(cases, baseline_rows, candidate_rows, min_cases=50, min_improvement=0.02, max_latency_ratio=1.10, dataset_id=None):
    if not cases:
        raise ValueError("no reviewed held-out cases: collect labels before judging candidates")
    if min_cases < 1 or not math.isfinite(min_improvement) or not 0 < min_improvement < 1:
        raise ValueError("positive case count and an improvement fraction between 0 and 1 required")
    if not math.isfinite(max_latency_ratio) or max_latency_ratio < 1:
        raise ValueError("latency ratio must be finite and at least 1")
    baseline, baseline_id, baseline_protocol = predictions_by_id(baseline_rows, cases, dataset_id)
    candidate, candidate_id, candidate_protocol = predictions_by_id(candidate_rows, cases, dataset_id)
    if baseline_id == candidate_id:
        raise ValueError("candidate and baseline must have distinct immutable configuration identities")
    before, after = [], []
    wins = losses = 0
    groups = defaultdict(lambda: ([], []))
    regressions = []
    for case in cases:
        a, b = score(case, baseline[case["id"]]), score(case, candidate[case["id"]])
        before.append(a)
        after.append(b)
        wins += b["edits"] < a["edits"]
        losses += b["edits"] > a["edits"]
        if b["edits"] > a["edits"] or b["critical"]:
            regressions.append({"id": case["id"], "baselineEdits": a["edits"], "candidateEdits": b["edits"],
                                "critical": b["critical"]})
        # Same target/error family can have multiple variants: only independent groups count toward evidence.
        groups[case.get("groupID") or case["id"]][0].append(a)
        groups[case.get("groupID") or case["id"]][1].append(b)
    grouped_wins = grouped_losses = 0
    for a, b in groups.values():
        ae, be = sum(row["edits"] for row in a), sum(row["edits"] for row in b)
        grouped_wins += be < ae
        grouped_losses += be > ae
    a, b = aggregate(before), aggregate(after)
    improvement = (a["tokenErrorRate"] - b["tokenErrorRate"]) / a["tokenErrorRate"] if a["tokenErrorRate"] else 0.0
    probability = sign_test(grouped_wins, grouped_losses)
    gates = {"enoughIndependentCases": len(groups) >= min_cases,
             "matchedTimingProtocol": baseline_protocol is not None and baseline_protocol == candidate_protocol
                                      and all(row.get("warmupSucceeded") is True for row in baseline.values())
                                      and all(row.get("warmupSucceeded") is True for row in candidate.values()),
             "qualityImproved": improvement >= min_improvement,
             "pairedEvidence": probability <= 0.05,
             "noCriticalFailures": b["criticalCases"] == 0,
             "preservesBaselineExactCases": all(not old["exact"] or new["exact"] for old, new in zip(before, after)),
             "latencyWithinBudget": b["p95Ms"] <= a["p95Ms"] * max_latency_ratio}
    # Avoid averaging away a regression in dictation vs Opt+1 or an app with enough observations.
    slices = {}
    for field in ("kind", "app"):
        values = {case.get(field) for case in cases if case.get(field)}
        for value in sorted(values):
            indices = [i for i, case in enumerate(cases) if case.get(field) == value]
            if len(indices) < 10:
                continue
            sa, sb = aggregate([before[i] for i in indices]), aggregate([after[i] for i in indices])
            # App ids are metadata; dictation text never enters the report.
            slices[field + ":" + value] = {"baseline": sa, "candidate": sb}
    gates["noSliceRegression"] = all(item["candidate"]["tokenErrorRate"] <= item["baseline"]["tokenErrorRate"]
                                    for item in slices.values())
    return {"schemaVersion": 1, "eligibleForReview": all(gates.values()), "promoted": False,
            "baselineID": baseline_id, "candidateID": candidate_id, "rollbackCandidateID": baseline_id,
            "baselineProtocolID": baseline_protocol, "candidateProtocolID": candidate_protocol,
            "policy": {"minIndependentCases": min_cases, "minRelativeImprovement": min_improvement,
                       "maxP95LatencyRatio": max_latency_ratio, "maxOneSidedSignP": 0.05},
            "gates": gates, "baseline": a, "candidate": b, "relativeImprovement": improvement,
            "wins": wins, "losses": losses, "ties": len(cases) - wins - losses,
            "independentGroups": len(groups), "groupWins": grouped_wins, "groupLosses": grouped_losses,
            "pairedSignP": probability, "slices": slices, "reviewCases": regressions,
            "limitation": "Automated screening does not establish semantic equivalence or native app reliability."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--split", choices=("valid", "test"), default="valid")
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--min-cases", type=int, default=50)
    parser.add_argument("--min-improvement", type=float, default=0.02)
    parser.add_argument("--max-latency-ratio", type=float, default=1.10)
    args = parser.parse_args()
    try:
        manifest, cases = load_dataset(args.dataset_dir, args.split)
        baseline_contents = Path(args.baseline).read_bytes().decode("utf-8")
        candidate_contents = Path(args.candidate).read_bytes().decode("utf-8")
        report = compare(cases, parse_jsonl(baseline_contents, "baseline"), parse_jsonl(candidate_contents, "candidate"),
                         args.min_cases, args.min_improvement, args.max_latency_ratio, manifest["datasetID"])
        report.update(datasetID=manifest["datasetID"], split=args.split,
                      createdAt=datetime.now(timezone.utc).isoformat(),
                      baselinePredictionsSHA256=digest(baseline_contents),
                      candidatePredictionsSHA256=digest(candidate_contents))
        report["comparisonID"] = digest(canonical({key: report[key] for key in (
            "datasetID", "split", "baselinePredictionsSHA256", "candidatePredictionsSHA256", "policy")}))
        write_private(args.out, canonical(report) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Comparison refused: {error}\n")
    print("Eligible for review" if report["eligibleForReview"] else "Candidate rejected")
    print("Failed gates: " + ", ".join(key for key, passed in report["gates"].items() if not passed))
    return 0 if report["eligibleForReview"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
