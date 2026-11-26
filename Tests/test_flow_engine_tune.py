"""Fabricated timing/output fixtures; these tests make no inference speed claim."""
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import export_flow_runs as export
import flow_engine_tune as engine
import flow_hillclimb as hill
import run_flow_candidate as replay


def cases():
    rows = [{"id": "violet", "input": "the violet ketle", "target": "The violet kettle.", "kind": "dictation"},
            {"id": "copper", "input": "the copper lantern", "target": "The copper lantern.", "kind": "dictation"}]
    for row in rows:
        row["caseHash"] = export.case_hash(row)
    return rows


def fixture(root, name, offset, latency=100, repetitions=6, runtime="control", usage=True, workload=None):
    workload = cases() if workload is None else workload
    identity = {"model": "local-cleanup", "artifactSHA256": export.digest("invented weights"), "runnerSHA256": export.digest("invented runner"),
                "promptSHA256": export.digest("invented system prompt"), "userPrefixSHA256": export.digest(""),
                "chatTemplateKwargs": None, "runtimeID": runtime, "environmentID": "invented-machine; same-OS-and-power",
                "temperature": 0, "maxTokens": 2048,
                "timeoutSeconds": 30, "cachePrompt": "server-default"}
    protocol = replay.benchmark_protocol(repetitions=repetitions)
    model_id = export.digest(export.canonical(identity))

    def invoke(row):
        return {"id": row["id"], "caseHash": row["caseHash"], "output": row["target"], "error": None,
                "finish_reason": "stop", "latencyMs": latency,
                "promptTokens": 10 if usage else None, "completionTokens": 5 if usage else None}

    rows = replay.replay_cases(workload, invoke, protocol, model_id, "frozen-dataset")
    start = datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(minutes=offset)
    metadata = {"schemaVersion": 3, "identity": identity, "modelID": model_id, "datasetID": "frozen-dataset", "split": "valid",
                "benchmarkProtocol": protocol, "benchmarkProtocolID": export.digest(export.canonical(protocol)),
                "warmups": [{"error": None, "finish_reason": "stop", "latencyMs": 100}],
                "cases": len(workload), "attempts": len(workload) * repetitions, "failures": 0,
                "startedAt": start.isoformat(), "completedAt": (start + timedelta(seconds=30)).isoformat()}
    path = Path(root) / (name + ".jsonl")
    write_run(path, rows, metadata)
    return path, rows, metadata


def write_run(path, rows, metadata):
    contents = "".join(export.canonical(row) + "\n" for row in rows)
    metadata["predictionsSHA256"] = export.digest(contents)
    Path(path).write_text(contents)
    Path(str(path) + ".manifest.json").write_text(export.canonical(metadata))


def read_run(path):
    return engine.load_run(path, cases(), "frozen-dataset", "valid")


class EngineTuneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.before = fixture(self.temp.name, "before", 0)
        self.candidate = fixture(self.temp.name, "candidate", 1, 80, runtime="candidate")
        self.after = fixture(self.temp.name, "after", 2, 102)

    def compare(self):
        return engine.compare_runs(*(read_run(run[0]) for run in (self.before, self.candidate, self.after)))

    def test_complete_faster_equivalent_candidate_passes_without_promoting(self):
        report = self.compare()
        self.assertTrue(report["eligibleForReview"])
        self.assertFalse(report["promoted"])
        self.assertEqual(report["candidate"]["attempts"], 12)
        self.assertAlmostEqual(report["candidate"]["completionTokensPerRequestSecond"], 62.5)
        self.assertEqual(report["candidate"]["completionTokens"], 60)
        self.assertNotIn("violet kettle", json.dumps(report))

    def test_no_usage_is_unavailable_not_zero_or_estimated(self):
        self.candidate = fixture(self.temp.name, "candidate", 1, 80, runtime="candidate", usage=False)
        report = self.compare()
        self.assertTrue(report["eligibleForReview"])
        self.assertIsNone(report["candidate"]["completionTokens"])
        self.assertIsNone(report["candidate"]["completionTokensPerRequestSecond"])
        self.assertEqual(report["candidate"]["completionTokenSamples"], 0)

    def test_drifting_control_is_inconclusive_not_a_speed_win(self):
        self.after = fixture(self.temp.name, "after", 2, 150)
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertFalse(report["gates"]["controlsStable"])
        self.assertEqual(len(report["controlDriftCaseIDs"]), 2)

    def test_case_drift_cannot_hide_in_unchanged_aggregate_median(self):
        path, rows, metadata = self.after
        for row, latency in zip(rows, (80, 120)):
            row["latencyMs"] = latency
            for sample in row["attempts"]:
                sample["latencyMs"] = latency
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertFalse(report["gates"]["controlsStable"])
        self.assertEqual(report["after"]["p50Ms"], 100)

    def test_one_changed_attempt_rejects_claimed_lossless_optimization(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"][-1]["output"] = "The turquoise lantern."
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertFalse(report["gates"]["exactOutputEquivalence"])
        self.assertFalse(report["eligibleForReview"])
        self.assertEqual(report["outputChangedCaseIDs"], ["violet"])

    def test_late_failure_cannot_hide_behind_successful_header_or_median(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"][-1].update(error="deadline-exceeded", finish_reason="timeout", latencyMs=20000)
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(report["candidate"]["failedAttempts"], 1)
        self.assertEqual(report["candidate"]["p95Ms"], 20000)
        self.assertIsNone(report["candidate"]["completionTokensPerRequestSecond"])

    def test_all_attempt_latencies_not_medians_of_medians_determine_p95(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"][-1]["latencyMs"] = 200
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertEqual(report["candidate"]["p50Ms"], 80)
        self.assertEqual(report["candidate"]["p95Ms"], 200)
        self.assertFalse(report["gates"]["p95NotRegressedAgainstEitherControl"])

    def test_fewer_than_six_attempts_is_inconclusive(self):
        self.before = fixture(self.temp.name, "before", 0, repetitions=5)
        self.candidate = fixture(self.temp.name, "candidate", 1, 80, repetitions=5, runtime="candidate")
        self.after = fixture(self.temp.name, "after", 2, repetitions=5)
        self.assertEqual(self.compare()["status"], "inconclusive")

    def test_changed_prompt_cannot_be_presented_as_engine_only_speedup(self):
        path, rows, metadata = self.candidate
        metadata["identity"]["promptSHA256"] = export.digest("different invented system prompt")
        metadata["modelID"] = export.digest(export.canonical(metadata["identity"]))
        for row in rows:
            row["modelID"] = metadata["modelID"]
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "request contract"):
            self.compare()

    def test_after_control_configuration_must_match_before(self):
        self.after = fixture(self.temp.name, "after", 2, 100, runtime="changed-control")
        with self.assertRaisesRegex(ValueError, "exactly the same"):
            self.compare()

    def test_engine_only_comparison_refuses_changed_or_missing_environment(self):
        path, rows, metadata = self.candidate
        metadata["identity"]["environmentID"] = "different-invented-machine"
        metadata["modelID"] = export.digest(export.canonical(metadata["identity"]))
        for row in rows:
            row["modelID"] = metadata["modelID"]
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "identical environment"):
            self.compare()
        metadata["identity"]["environmentID"] = None
        metadata["modelID"] = export.digest(export.canonical(metadata["identity"]))
        for row in rows:
            row["modelID"] = metadata["modelID"]
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "environment identity"):
            read_run(path)

    def test_explicit_cache_policy_is_an_allowed_optimization_knob(self):
        path, rows, metadata = self.candidate
        metadata["identity"]["cachePrompt"] = "on"
        metadata["modelID"] = export.digest(export.canonical(metadata["identity"]))
        for row in rows:
            row["modelID"] = metadata["modelID"]
        write_run(path, rows, metadata)
        self.assertTrue(self.compare()["eligibleForReview"])

    def test_wrong_chronology_and_overlap_fail(self):
        self.after = fixture(self.temp.name, "after", 1, 100)
        with self.assertRaisesRegex(ValueError, "ordered"):
            self.compare()

    def test_deleted_attempt_and_fabricated_median_fail(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"].pop()
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "repetition count"):
            read_run(path)
        self.candidate = fixture(self.temp.name, "candidate", 1, 80, runtime="candidate")
        path, rows, metadata = self.candidate
        rows[0]["latencyMs"] = 1
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "median"):
            read_run(path)

    def test_hash_mismatch_and_bad_config_identity_fail(self):
        path, rows, metadata = self.candidate
        path.write_text(path.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            read_run(path)
        metadata["identity"]["runtimeID"] = "edited-after-run"
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "configuration identity"):
            read_run(path)

    def test_manifest_and_predictions_are_bound_to_same_snapshot(self):
        path, rows, metadata = self.candidate
        metadata["datasetID"] = "another-dataset"
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "different frozen dataset"):
            read_run(path)

    def test_missing_unmeasured_samples_cannot_be_synthesized_from_header(self):
        path, rows, metadata = self.candidate
        del rows[0]["attempts"]
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "every attempt"):
            read_run(path)

    def test_reviewed_newline_only_output_is_a_complete_engine_attempt(self):
        workload = [{"id": "line", "input": "new line", "target": "\n", "kind": "dictation", "requireExactLayout": True}]
        workload[0]["caseHash"] = export.case_hash(workload[0])
        runs = [fixture(self.temp.name, name, index, latency, runtime=runtime, workload=workload)
                for index, (name, latency, runtime) in enumerate((("before", 100, "control"), ("candidate", 80, "candidate"), ("after", 102, "control")))]
        report = engine.compare_runs(*(engine.load_run(run[0], workload, "frozen-dataset", "valid") for run in runs))
        self.assertTrue(report["eligibleForReview"])
        self.assertEqual(report["candidate"]["failedAttempts"], 0)

    def set_case_latencies(self, run, values):
        path, rows, metadata = run
        for row, latencies in zip(rows, values):
            for sample, latency in zip(row["attempts"], latencies):
                sample["latencyMs"] = latency
            row["latencyMs"] = engine.statistics.median(latencies)
        write_run(path, rows, metadata)

    def test_short_case_tail_regression_cannot_hide_behind_long_cases(self):
        self.set_case_latencies(self.before, ([10] * 6, [1000] * 6))
        self.set_case_latencies(self.after, ([10] * 6, [1000] * 6))
        self.set_case_latencies(self.candidate, ([8] * 5 + [20], [800] * 6))
        report = self.compare()
        self.assertTrue(report["gates"]["medianImprovedAgainstBothControls"])
        self.assertTrue(report["gates"]["p95NotRegressedAgainstEitherControl"])
        self.assertTrue(report["gates"]["noCaseMedianRegression"])
        self.assertFalse(report["gates"]["noCaseP95Regression"])
        self.assertEqual(report["tailLatencyRegressedCaseIDs"], ["violet"])
        self.assertEqual(report["status"], "candidate-rejected")

    def test_short_case_control_tail_drift_is_inconclusive(self):
        self.set_case_latencies(self.before, ([10] * 6, [1000] * 6))
        self.set_case_latencies(self.after, ([10] * 5 + [20], [1000] * 6))
        self.set_case_latencies(self.candidate, ([8] * 6, [800] * 6))
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(report["controlDriftCaseIDs"], ["violet"])

    def test_successful_status_cannot_hide_an_overdue_attempt(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"][-1]["latencyMs"] = 31000
        metadata["completedAt"] = (engine.timestamp(metadata["startedAt"]) + timedelta(seconds=60)).isoformat()
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(report["candidate"]["failures"][0]["error"], "deadline-exceeded")

    def test_successful_status_cannot_hide_an_exceeded_generation_cap(self):
        path, rows, metadata = self.candidate
        rows[0]["attempts"][-1]["completionTokens"] = 2049
        write_run(path, rows, metadata)
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(report["candidate"]["failures"][0]["error"], "output-token-limit-exceeded")

    def test_overdue_warmup_does_not_establish_calibration(self):
        path, rows, metadata = self.candidate
        metadata["warmups"][0]["latencyMs"] = 31000
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "warmup failed"):
            read_run(path)

    def test_model_switch_during_run_invalidates_speed_evidence(self):
        for path, rows, metadata in (self.before, self.candidate, self.after):
            for sample in metadata["warmups"] + [sample for row in rows for sample in row["attempts"]]:
                sample["serverModel"] = "invented-weights-a"
            if metadata["identity"]["runtimeID"] == "candidate":
                rows[0]["attempts"][-1]["serverModel"] = "invented-weights-b"
            write_run(path, rows, metadata)
        report = self.compare()
        self.assertEqual(report["status"], "inconclusive")
        self.assertFalse(report["gates"]["stableReportedServerModel"])

    def test_running_or_aborted_manifest_is_never_a_complete_result(self):
        path, rows, metadata = self.candidate
        for status in ("running", "aborted"):
            metadata["status"] = status
            write_run(path, rows, metadata)
            with self.assertRaisesRegex(ValueError, "completed replay"):
                read_run(path)

    def test_boolean_temperature_or_failure_count_is_not_numeric_evidence(self):
        path, rows, metadata = self.candidate
        metadata["failures"] = False
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "failure count"):
            read_run(path)
        metadata["failures"] = 0
        metadata["identity"]["temperature"] = False
        metadata["modelID"] = export.digest(export.canonical(metadata["identity"]))
        for row in rows:
            row["modelID"] = metadata["modelID"]
        write_run(path, rows, metadata)
        with self.assertRaisesRegex(ValueError, "request configuration"):
            read_run(path)


if __name__ == "__main__":
    unittest.main()
