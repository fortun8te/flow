#!/usr/bin/env python3
"""Screen an engine change using complete control/candidate/control local replays.

Reads frozen reviewed cases and three run_flow_candidate.py prediction snapshots
plus their manifests; writes a private report with no transcript text. It never
starts a server, changes Flow settings, or installs a candidate. Run controls
before and after the candidate on the same machine with the same workload.

The repeated-sample, output-equivalence and drift-screening workflow is informed
by https://github.com/sybil-solutions/inference-optimisation-skill . Implementation
is original standard-library Python. These are screening thresholds, not a
confidence interval or evidence about native Flow latency.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import statistics

from export_flow_runs import canonical, digest, write_private
from flow_hillclimb import load_dataset, parse_jsonl, percentile95, positive_number, predictions_by_id, validate_protocol

SHA256 = re.compile(r"[0-9a-f]{64}\Z")
OPTIMIZATION_FIELDS = {"runtimeID", "cachePrompt"}


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("run timestamps are missing")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("run timestamps must include a timezone")
    return parsed


def load_run(path, cases, dataset_id, split):
    contents = Path(path).read_bytes().decode("utf-8")
    metadata_bytes = Path(str(path) + ".manifest.json").read_bytes()
    metadata = json.loads(metadata_bytes)
    if not isinstance(metadata, dict) or metadata.get("schemaVersion") != 3:
        raise ValueError("engine comparison requires a complete replay manifest from the current runner")
    if metadata.get("predictionsSHA256") != digest(contents):
        raise ValueError("prediction hash mismatch; rerun from a stable complete replay snapshot")
    if metadata.get("datasetID") != dataset_id or metadata.get("split") != split:
        raise ValueError("run uses a different frozen dataset or split")
    identity = metadata.get("identity")
    if not isinstance(identity, dict) or metadata.get("modelID") != digest(canonical(identity)):
        raise ValueError("run configuration identity is missing or changed")
    for key in ("artifactSHA256", "promptSHA256", "userPrefixSHA256", "runnerSHA256"):
        if not isinstance(identity.get(key), str) or not SHA256.fullmatch(identity[key]):
            raise ValueError("model and prompt identities must use exact SHA-256 digests")
    if any(not isinstance(identity.get(key), str) or not identity[key].strip() for key in ("model", "runtimeID", "environmentID")):
        raise ValueError("model, engine runtime and environment identity must be nonempty; supply --environment-id when replaying")
    if identity.get("cachePrompt") not in {"on", "off", "server-default"}:
        raise ValueError("run does not declare its prompt cache request policy")
    if identity.get("chatTemplateKwargs") is not None and not isinstance(identity["chatTemplateKwargs"], dict):
        raise ValueError("chat template options must be a JSON object or absent")
    protocol, protocol_id = metadata.get("benchmarkProtocol"), metadata.get("benchmarkProtocolID")
    validate_protocol(protocol, protocol_id)
    if identity.get("temperature") != 0 or identity.get("maxTokens") != protocol["maxTokens"] or identity.get("timeoutSeconds") != protocol["timeoutSeconds"]:
        raise ValueError("request configuration disagrees with its timing protocol")
    rows = parse_jsonl(contents, "engine predictions")
    predictions, model_id, row_protocol_id = predictions_by_id(rows, cases, dataset_id)
    if model_id != metadata["modelID"] or row_protocol_id != protocol_id:
        raise ValueError("manifest and prediction identities disagree")
    if any(not isinstance(row.get("attempts"), list) for row in rows):
        raise ValueError("engine timing requires every actual attempt, not a summarized latency")
    if metadata.get("cases") != len(cases) or metadata.get("attempts") != len(cases) * protocol["repetitions"]:
        raise ValueError("manifest does not describe the complete attempted workload")
    if metadata.get("failures") != sum(bool(row.get("error")) for row in rows):
        raise ValueError("manifest failure count disagrees with predictions")
    warmups = metadata.get("warmups")
    if not isinstance(warmups, list) or len(warmups) != protocol["warmupRequests"]:
        raise ValueError("warmup evidence is incomplete")
    if any(not isinstance(sample, dict) or sample.get("error") or sample.get("finish_reason") != "stop"
           or not positive_number(sample.get("latencyMs")) for sample in warmups):
        raise ValueError("authored warmup failed")
    start, end = timestamp(metadata.get("startedAt")), timestamp(metadata.get("completedAt"))
    if end <= start:
        raise ValueError("run completion must follow its start")
    total_ms = sum(sample["latencyMs"] for row in rows for sample in row["attempts"])
    total_ms += sum(sample["latencyMs"] for sample in warmups)
    if total_ms > (end - start).total_seconds() * 1000 + 1:
        raise ValueError("recorded request durations exceed the sequential run's wall time")
    return {"metadata": metadata, "predictions": predictions, "start": start, "end": end,
            "predictionsSHA256": digest(contents), "manifestSHA256": digest(metadata_bytes.decode("utf-8"))}


def failed_sample(sample):
    return bool(sample.get("error")) or sample.get("finish_reason") != "stop" or not sample["output"].strip()


def metrics(run):
    rows = run["predictions"]
    samples = [sample for row in rows.values() for sample in row["attempts"]]
    latencies = [sample["latencyMs"] for sample in samples]
    failures = [{"id": sample["id"], "sampleIndex": sample["sampleIndex"],
                 "error": sample.get("error") or "incomplete-or-empty-output", "finishReason": sample.get("finish_reason")}
                for sample in samples if failed_sample(sample)]
    counts = [sample["completionTokens"] for sample in samples if sample.get("completionTokens") is not None]
    complete_usage = len(counts) == len(samples)
    # Whole-request time includes prefill, decode, transport and response parsing.
    # This is not decode throughput; nonstreaming calls do not measure TTFT.
    throughput = sum(counts) / (sum(latencies) / 1000) if complete_usage and not failures else None
    return {"cases": len(rows), "attempts": len(samples), "failedAttempts": len(failures), "failures": failures,
            "failedCaseHeaders": sum(bool(row.get("error")) for row in rows.values()),
            "p50Ms": statistics.median(latencies), "p95Ms": percentile95(latencies),
            "totalRequestSeconds": sum(latencies) / 1000,
            "completionTokenSamples": len(counts), "completionTokens": sum(counts) if complete_usage else None,
            "completionTokensPerRequestSecond": throughput,
            "perCase": {identifier: {"samples": len(row["attempts"]),
                        "p50Ms": statistics.median(sample["latencyMs"] for sample in row["attempts"]),
                        "p95Ms": percentile95([sample["latencyMs"] for sample in row["attempts"]])}
                        for identifier, row in rows.items()}}


def ratio_close(left, right, allowance):
    return max(left / right, right / left) <= 1 + allowance


def compare_runs(before, candidate, after, min_improvement=0.05, max_control_drift=0.10, max_case_regression=0.05):
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value < 1
           for value in (min_improvement, max_control_drift, max_case_regression)) or min_improvement == 0:
        raise ValueError("screening thresholds must be finite fractions below 1; improvement must be positive")
    bmeta, cmeta, ameta = (run["metadata"] for run in (before, candidate, after))
    if bmeta["identity"] != ameta["identity"]:
        raise ValueError("before/after controls must use exactly the same model, prompt and engine configuration")
    if bmeta["modelID"] == cmeta["modelID"]:
        raise ValueError("candidate must declare a distinct engine configuration")
    workload = lambda identity: {key: value for key, value in identity.items() if key not in OPTIMIZATION_FIELDS}
    if workload(bmeta["identity"]) != workload(cmeta["identity"]):
        raise ValueError("engine-only tuning requires identical environment, model artifact and request contract; only runtimeID/cachePrompt may change")
    if not bmeta["benchmarkProtocol"] == cmeta["benchmarkProtocol"] == ameta["benchmarkProtocol"]:
        raise ValueError("controls and candidate require the same warmup, repetitions, order and request limits")
    if not before["end"] <= candidate["start"] <= candidate["end"] <= after["start"]:
        raise ValueError("runs must be separate and ordered control-before, candidate, control-after")
    if not before["predictions"].keys() == candidate["predictions"].keys() == after["predictions"].keys():
        raise ValueError("complete workloads differ")
    bm, cm, am = (metrics(run) for run in (before, candidate, after))
    drift_cases = [identifier for identifier in bm["perCase"] if not ratio_close(
        bm["perCase"][identifier]["p50Ms"], am["perCase"][identifier]["p50Ms"], max_control_drift)]
    controls_stable = not drift_cases and all(ratio_close(bm[key], am[key], max_control_drift) for key in ("p50Ms", "p95Ms"))
    changed_cases = []
    for identifier, row in before["predictions"].items():
        reference = row["attempts"][0]["output"]
        if any(sample["output"] != reference for run in (before, candidate, after)
               for sample in run["predictions"][identifier]["attempts"]):
            changed_cases.append(identifier)
    regressed_cases = [identifier for identifier, value in cm["perCase"].items()
                       if value["p50Ms"] > min(bm["perCase"][identifier]["p50Ms"], am["perCase"][identifier]["p50Ms"]) * (1 + max_case_regression)]
    gates = {"repeatedSamples": bmeta["benchmarkProtocol"]["repetitions"] >= 6,
             "successfulWarmup": bmeta["benchmarkProtocol"]["warmupRequests"] > 0,
             "allAttemptsComplete": all(not value["failedAttempts"] and not value["failedCaseHeaders"] for value in (bm, cm, am)),
             "controlsStable": controls_stable,
             "exactOutputEquivalence": not changed_cases,
             "medianImprovedAgainstBothControls": cm["p50Ms"] <= min(bm["p50Ms"], am["p50Ms"]) * (1 - min_improvement),
             "p95NotRegressedAgainstEitherControl": cm["p95Ms"] <= min(bm["p95Ms"], am["p95Ms"]),
             "noCaseMedianRegression": not regressed_cases}
    inconclusive = any(not gates[key] for key in ("repeatedSamples", "successfulWarmup", "allAttemptsComplete", "controlsStable"))
    eligible = all(gates.values())
    return {"schemaVersion": 1, "status": "eligible-for-review" if eligible else "inconclusive" if inconclusive else "candidate-rejected",
            "eligibleForReview": eligible, "promoted": False, "gates": gates,
            "policy": {"minSamplesPerCase": 6, "minMedianImprovement": min_improvement,
                       "maxSymmetricControlDrift": max_control_drift, "maxCaseMedianRegression": max_case_regression,
                       "allowedOptimizationIdentityFields": sorted(OPTIMIZATION_FIELDS)},
            "before": bm, "candidate": cm, "after": am, "controlDriftCaseIDs": drift_cases,
            "outputChangedCaseIDs": changed_cases, "latencyRegressedCaseIDs": regressed_cases,
            "candidateMedianRatioToBefore": cm["p50Ms"] / bm["p50Ms"],
            "candidateMedianRatioToAfter": cm["p50Ms"] / am["p50Ms"],
            "runs": {name: {"configurationID": run["metadata"]["modelID"], "identity": run["metadata"]["identity"],
                             "startedAt": run["metadata"]["startedAt"], "completedAt": run["metadata"]["completedAt"],
                             "predictionsSHA256": run["predictionsSHA256"], "manifestSHA256": run["manifestSHA256"]}
                     for name, run in (("before", before), ("candidate", candidate), ("after", after))},
            "benchmarkProtocol": bmeta["benchmarkProtocol"], "benchmarkProtocolID": bmeta["benchmarkProtocolID"],
            "limitation": "Pilot screening on a frozen standalone HTTP workload. Six samples is a minimum, not strong tail evidence: nearest-rank p95 at n=6 is the maximum. Repeat longer when noisy or near budget. Exact observed outputs do not prove native app equivalence or future determinism. Token throughput uses server-reported usage over whole request time, not decode TPS or TTFT."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--split", choices=("valid", "test"), default="valid")
    parser.add_argument("--before", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--min-improvement", type=float, default=0.05)
    parser.add_argument("--max-control-drift", type=float, default=0.10)
    parser.add_argument("--max-case-regression", type=float, default=0.05)
    args = parser.parse_args()
    try:
        manifest, cases = load_dataset(args.dataset_dir, args.split)
        if not cases:
            raise ValueError("no reviewed held-out workload to compare")
        runs = [load_run(path, cases, manifest["datasetID"], args.split) for path in (args.before, args.candidate, args.after)]
        report = compare_runs(*runs, args.min_improvement, args.max_control_drift, args.max_case_regression)
        report.update(datasetID=manifest["datasetID"], split=args.split, createdAt=datetime.now(timezone.utc).isoformat())
        report["comparisonID"] = digest(canonical({key: report[key] for key in ("datasetID", "split", "runs", "policy", "benchmarkProtocolID")}))
        write_private(args.out, canonical(report) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Engine comparison refused: {error}\n")
    print(report["status"])
    print("Failed gates: " + ", ".join(key for key, passed in report["gates"].items() if not passed))
    return 0 if report["eligibleForReview"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
