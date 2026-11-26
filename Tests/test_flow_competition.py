"""Invented audio bytes, targets, clocks and declarations; no competitor results."""
import copy
import json
import math
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import export_flow_runs as export
import flow_competition as competition
from flow_hillclimb import load_dataset


class CompetitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cases, self.audio_map = [], []
        for index in range(50):
            row = {"id": f"invented-{index:03}", "input": f"the violet ketle {index}",
                   "target": f"The violet kettle {index}.", "kind": "dictation", "app": "synthetic-private-app",
                   "groupID": f"family-{index}", "split": "valid", "trainingEligible": True, "label": "human-reviewed"}
            row["caseHash"] = export.case_hash(row)
            self.cases.append(row)
            paths = {key + "Path": key + str(index) for key in ("audio", "context", "vocabulary")}
            for key, name in paths.items():
                (self.root / name).write_bytes(f"invented-{key}-{index}".encode())
            self.audio_map.append({"id": row["id"], "caseHash": row["caseHash"], **paths,
                                   "audioReview": {"source": "audio-human-reviewed", "reviewerID": "synthetic-reviewer",
                                                   "reviewedAt": "2026-01-01T00:00:00Z", "caseHash": row["caseHash"],
                                                   "audioSHA256": competition.stable_file(self.root / paths["audioPath"])[0],
                                                   "targetMatchesAudio": True, "independentOfSystems": True}})
        self.protocol = {"schemaVersion": 1, "measurement": "key-release-to-verified-insertion", "clock": "monotonic_ns",
                         "clockSessionID": "synthetic-clock-session", "order": "paired-alternating-rounds", "initialState": "ready",
                         "repetitions": 3, "timeoutMs": 10000, "maxP95Ms": 500,
                         "environment": {key: "synthetic-" + key for key in
                                         ("hardware", "os", "power", "targetApp", "targetAppVersion", "audioRoute", "network")}}
        self.write_dataset()
        self.match = self.freeze()
        self.build_captures()

    def write_dataset(self):
        self.dataset = self.root / "dataset"
        self.dataset.mkdir(exist_ok=True)
        files = {}
        for split in ("train", "valid", "test"):
            rows = self.cases if split == "valid" else []
            contents = "".join(export.canonical(row) + "\n" for row in rows)
            (self.dataset / (split + ".jsonl")).write_text(contents)
            files[split + ".jsonl"] = {"sha256": export.digest(contents), "rows": len(rows)}
        self.manifest = {"schemaVersion": export.EXPORT_SCHEMA, "splitPolicy": export.SPLIT_POLICY, "files": files,
                         "datasetID": export.digest(export.canonical(files)), "supervisedBlocked": False}
        (self.dataset / "manifest.json").write_text(export.canonical(self.manifest))

    def freeze(self):
        return competition.freeze(self.manifest, self.cases, "valid", self.audio_map, self.protocol, self.root)

    def review(self, row, output, ready):
        return {"source": "blind-human", "blindToSystem": True, "reviewerID": "synthetic-blind-reviewer",
                "reviewedAt": "2026-01-02T00:00:00Z", "matchID": self.match["matchID"],
                "caseHash": row["caseHash"], "outputSHA256": export.digest(output), "readyToSend": ready, "meaningPreserved": True}

    def build_captures(self):
        self.rows, self.metadata, self.paths = {}, {}, {}
        for product in ("wispr", "flow"):
            identity = {"product": product, "version": "synthetic-v1", "build": "synthetic-build",
                        "collectorID": "synthetic-collector", "configuration": {"cleanup": "synthetic-mode"},
                        "modelName": "Canto-2" if product == "wispr" else "synthetic-model"}
            system = export.digest(export.canonical(identity))
            rows = []
            for case, binding in zip(self.cases, self.match["cases"]):
                row = {key: binding[key] for key in ("id", "caseHash", "audioSHA256", "contextSHA256", "vocabularySHA256")}
                row.update(matchID=self.match["matchID"], systemID=system, protocolID=self.match["protocolID"], attempts=[])
                output = case["target"] if product == "flow" else case["target"].replace("kettle", "ketle")
                for index in range(self.protocol["repetitions"]):
                    row["attempts"].append({"sampleIndex": index, "output": output, "outputSHA256": export.digest(output),
                                            "elapsedMs": 150 if product == "flow" else 200, "outcome": "inserted",
                                            "insertionVerified": True, "humanReview": self.review(row, output, product == "flow")})
                rows.append(row)
            self.rows[product] = rows
            self.paths[product] = self.root / (product + ".jsonl")
            self.metadata[product] = {"schemaVersion": 1, "identity": identity, "systemID": system, "matchID": self.match["matchID"],
                                      "protocolID": self.match["protocolID"], "environmentID": export.digest(export.canonical(self.protocol["environment"])),
                                      "clockSessionID": self.protocol["clockSessionID"], "captureType": "native-dictation", "retainedAllAttempts": True,
                                      "cases": len(self.cases), "attempts": len(self.cases) * self.protocol["repetitions"],
                                      "startedAt": "2026-01-01T01:00:00Z", "completedAt": "2026-01-01T02:00:00Z"}
        self.reclock()
        self.write_capture("wispr")
        self.write_capture("flow")

    def reclock(self):
        now = 1000000
        for repetition in range(self.protocol["repetitions"]):
            for index in range(len(self.cases)):
                for product in ("wispr", "flow") if repetition % 2 == 0 else ("flow", "wispr"):
                    sample = self.rows[product][index]["attempts"][repetition]
                    sample["keyReleasedNs"] = now
                    now += round(sample["elapsedMs"] * 1000000)
                    sample["completedNs"] = now
                    now += 1000

    def write_capture(self, product):
        contents = "".join(export.canonical(row) + "\n" for row in self.rows[product])
        self.metadata[product]["capturesSHA256"] = export.digest(contents)
        self.paths[product].write_text(contents)
        Path(str(self.paths[product]) + ".manifest.json").write_text(export.canonical(self.metadata[product]))

    def compare(self):
        manifest, cases = load_dataset(self.dataset, "valid")
        cases = competition.validate_match(self.match, manifest, cases)
        return competition.compare(self.match, cases, *(competition.load_capture(self.paths[product], self.match, product)
                                                        for product in ("wispr", "flow")))

    def change_output(self, product, case_index, output, sample_index=None):
        row = self.rows[product][case_index]
        selected = row["attempts"] if sample_index is None else [row["attempts"][sample_index]]
        for sample in selected:
            sample.update(output=output, outputSHA256=export.digest(output), humanReview=self.review(row, output, False))

    def test_complete_synthetic_workload_screens_without_claiming_superiority(self):
        report = self.compare()
        self.assertTrue(report["eligibleForReview"])
        self.assertFalse(report["promoted"])
        self.assertFalse(report["beatsCompetitor"])
        self.assertEqual(report["independentFamilies"], 50)
        self.assertEqual(report["candidate"]["latencySamples"], 150)
        self.assertEqual(report["baselineIdentity"]["modelAttribution"], "unverified")
        self.assertTrue(report["baselineIdentity"]["canto2Claimed"])
        self.assertEqual(report["evaluatorSHA256"], export.digest(export.canonical(report["evaluatorSources"])))
        self.assertIn("bench/text_metrics.py", report["evaluatorSources"])
        serialized = json.dumps(report)
        for private in ("violet", "invented-000", "synthetic-private-app", str(self.root), "synthetic-reviewer"):
            self.assertNotIn(private, serialized)

    def test_missing_blind_review_is_descriptive_only(self):
        del self.rows["flow"][0]["attempts"][0]["humanReview"]
        self.write_capture("flow")
        report = self.compare()
        self.assertEqual(report["status"], "descriptive-only")
        self.assertFalse(report["eligibleForReview"])
        self.assertEqual(report["candidate"]["reviewedAttempts"], 149)

    def test_stale_or_unblinded_or_nontyped_review_is_refused(self):
        review = self.rows["flow"][0]["attempts"][0]["humanReview"]
        original = copy.deepcopy(review)
        for key, value in (("outputSHA256", "0" * 64), ("caseHash", "1" * 64), ("matchID", "2" * 64),
                           ("blindToSystem", False), ("meaningPreserved", "true")):
            with self.subTest(key=key):
                review.clear(); review.update(original); review[key] = value
                self.write_capture("flow")
                with self.assertRaisesRegex(ValueError, "blind review"):
                    self.compare()

    def test_negative_human_meaning_review_blocks_automated_exact_match(self):
        self.rows["flow"][0]["attempts"][0]["humanReview"]["meaningPreserved"] = False
        self.write_capture("flow")
        report = self.compare()
        self.assertEqual(report["candidate"]["exactRate"], 1)
        self.assertFalse(report["gates"]["noHumanRegression"])

    def test_audio_context_and_vocabulary_bytes_are_bound(self):
        old_id = self.match["matchID"]
        for key in ("contextPath", "vocabularyPath"):
            (self.root / self.audio_map[0][key]).write_bytes(b"changed synthetic context")
            self.assertNotEqual(self.freeze()["matchID"], old_id)
        (self.root / self.audio_map[0]["audioPath"]).write_bytes(b"changed synthetic audio")
        with self.assertRaisesRegex(ValueError, "audio/target review"):
            self.freeze()

    def test_missing_duplicate_or_extra_audio_mapping_is_refused(self):
        original = self.audio_map
        for rows in (original[:-1], original + [original[0]], original + [{**original[0], "id": "unknown"}]):
            self.audio_map = rows
            with self.assertRaises(ValueError):
                self.freeze()
        self.audio_map = original

    def test_mismatched_binding_and_configuration_are_refused(self):
        row = self.rows["flow"][0]
        for key in ("audioSHA256", "contextSHA256", "vocabularySHA256", "caseHash", "systemID", "protocolID", "matchID"):
            with self.subTest(key=key):
                previous = row[key]; row[key] = "0" * 64
                self.write_capture("flow")
                with self.assertRaises(ValueError):
                    self.compare()
                row[key] = previous
        self.metadata["flow"]["identity"]["build"] = "changed-build"
        self.write_capture("flow")
        with self.assertRaisesRegex(ValueError, "identity"):
            self.compare()

    def test_missing_or_reordered_attempts_are_refused(self):
        row = self.rows["flow"][0]
        complete = row["attempts"]
        for attempts in (complete[:-1], complete[::-1], [complete[0], complete[0], complete[2]]):
            row["attempts"] = attempts
            self.write_capture("flow")
            with self.assertRaises(ValueError):
                self.compare()

    def test_invalid_timing_and_summarized_http_latency_are_refused(self):
        sample = self.rows["flow"][0]["attempts"][0]
        original = copy.deepcopy(sample)
        for key, value in (("elapsedMs", True), ("elapsedMs", math.nan), ("elapsedMs", 151),
                           ("keyReleasedNs", True), ("completedNs", 0)):
            with self.subTest(key=key, value=value):
                sample.clear(); sample.update(original); sample[key] = value
                self.write_capture("flow")
                with self.assertRaisesRegex(ValueError, "monotonic"):
                    self.compare()
        sample.clear(); sample.update(original); del sample["keyReleasedNs"]; sample["latencyMs"] = 150
        self.write_capture("flow")
        with self.assertRaises(ValueError):
            self.compare()

    def test_timeouts_remain_in_p95_and_quality_denominators(self):
        for index in range(10):
            row = self.rows["flow"][index]
            sample = row["attempts"][0]
            self.change_output("flow", index, "", sample_index=0)
            sample.update(outcome="timeout", insertionVerified=False, elapsedMs=10000)
        self.reclock(); self.write_capture("flow"); self.write_capture("wispr")
        report = self.compare()
        self.assertEqual(report["candidate"]["latencySamples"], 150)
        self.assertEqual(report["candidate"]["p95Ms"], 10000)
        self.assertEqual(report["candidate"]["criticalCounts"]["runtime_failure"], 10)
        self.assertFalse(report["eligibleForReview"])

    def test_repetitions_and_native_protocol_cannot_be_relaxed(self):
        for key, value in (("repetitions", 2), ("repetitions", True), ("measurement", "http-cleanup"),
                           ("clock", "wall-clock"), ("initialState", "unknown"), ("timeoutMs", math.inf)):
            protocol = {**self.protocol, key: value}
            with self.assertRaises(ValueError):
                competition.validate_protocol(protocol)

    def test_repeated_audio_does_not_inflate_independent_evidence(self):
        for row in self.audio_map:
            row["audioPath"] = self.audio_map[0]["audioPath"]
            row["audioReview"]["audioSHA256"] = self.audio_map[0]["audioReview"]["audioSHA256"]
        self.match = self.freeze(); self.build_captures()
        report = self.compare()
        self.assertEqual(report["independentFamilies"], 1)
        self.assertFalse(report["gates"]["enoughIndependentFamilies"])

    def test_family_and_audio_connections_merge_transitively(self):
        rows = [{"audioSHA256": "A", "textFamilyID": "one"}, {"audioSHA256": "B", "textFamilyID": "one"},
                {"audioSHA256": "B", "textFamilyID": "two"}, {"audioSHA256": "C", "textFamilyID": "three"}]
        self.assertEqual(sorted(competition.independent_families(rows)), [[0, 1, 2], [3]])

    def test_one_previously_exact_attempt_cannot_hide_behind_other_repetitions(self):
        self.change_output("wispr", 0, self.cases[0]["target"], sample_index=1)
        self.change_output("flow", 0, self.cases[0]["target"].replace("kettle", "vessel"))
        self.write_capture("wispr"); self.write_capture("flow")
        report = self.compare()
        self.assertFalse(report["gates"]["preservesPreviousExactOutputs"])
        self.assertTrue(report["gates"]["qualityImproved"])

    def test_critical_number_failure_blocks_candidate(self):
        self.change_output("flow", 0, self.cases[0]["target"].replace("0", "9"))
        self.write_capture("flow")
        report = self.compare()
        self.assertFalse(report["gates"]["noCriticalFailures"])
        self.assertEqual(report["candidate"]["criticalCounts"]["changed_number"], 1)

    def test_small_slice_regression_is_not_averaged_away(self):
        self.audio_map[0]["slices"] = ["synthetic-rare-term-slice"]
        self.match = self.freeze(); self.build_captures()
        self.change_output("flow", 0, self.cases[0]["target"].replace("violet kettle", "blue glass vessel"))
        self.write_capture("flow")
        report = self.compare()
        self.assertTrue(report["gates"]["qualityImproved"])
        self.assertFalse(report["gates"]["noSliceRegression"])
        self.assertNotIn("synthetic-rare-term-slice", json.dumps(report))

    def test_slower_candidate_fails_relative_p95_even_within_absolute_budget(self):
        for row in self.rows["flow"]:
            for sample in row["attempts"]:
                sample["elapsedMs"] = 300
        self.reclock(); self.write_capture("wispr"); self.write_capture("flow")
        report = self.compare()
        self.assertLess(report["candidate"]["p95Ms"], self.protocol["maxP95Ms"])
        self.assertFalse(report["gates"]["p95WithinBudget"])

    def test_overlap_or_nonpaired_capture_order_is_refused(self):
        self.rows["flow"][0]["attempts"][0].update(keyReleasedNs=0, completedNs=150000000)
        self.write_capture("flow")
        with self.assertRaisesRegex(ValueError, "paired round order"):
            self.compare()

    def test_event_span_cannot_hide_idle_hours_outside_declared_capture_window(self):
        for product in ("wispr", "flow"):
            for row in self.rows[product]:
                for sample in row["attempts"][1:]:
                    sample["keyReleasedNs"] += 7200 * 1000000000
                    sample["completedNs"] += 7200 * 1000000000
            self.write_capture(product)
        with self.assertRaisesRegex(ValueError, "capture wall time"):
            self.compare()

    def test_late_failed_attempt_cannot_avoid_timeout_classification(self):
        sample = self.rows["flow"][0]["attempts"][0]
        sample.update(outcome="failed", insertionVerified=False, elapsedMs=10001)
        self.reclock(); self.write_capture("wispr"); self.write_capture("flow")
        with self.assertRaisesRegex(ValueError, "timeout outcome"):
            self.compare()

    def test_model_attribution_needs_retained_hash_matching_evidence(self):
        path = self.root / "synthetic-model-evidence.txt"
        path.write_text("invented diagnostic evidence")
        identity = self.metadata["wispr"]["identity"]
        identity["modelEvidenceSHA256"] = competition.stable_file(path)[0]
        self.metadata["wispr"]["modelEvidencePath"] = path.name
        system = export.digest(export.canonical(identity))
        self.metadata["wispr"]["systemID"] = system
        for row in self.rows["wispr"]:
            row["systemID"] = system
        self.write_capture("wispr")
        self.assertEqual(self.compare()["baselineIdentity"]["modelAttribution"], "evidence-supplied")
        path.write_text("changed invented evidence")
        with self.assertRaisesRegex(ValueError, "model evidence"):
            self.compare()

    def test_compare_cannot_overwrite_its_retained_model_evidence(self):
        path = self.root / "synthetic-model-evidence.txt"
        original = "invented diagnostic evidence"
        path.write_text(original)
        identity = self.metadata["wispr"]["identity"]
        identity["modelEvidenceSHA256"] = competition.stable_file(path)[0]
        self.metadata["wispr"]["modelEvidencePath"] = path.name
        system = export.digest(export.canonical(identity))
        self.metadata["wispr"]["systemID"] = system
        for row in self.rows["wispr"]:
            row["systemID"] = system
        self.write_capture("wispr")
        match = self.root / "match.json"
        match.write_text(export.canonical(self.match))
        result = subprocess.run([sys.executable, str(SCRIPTS / "flow_competition.py"), "compare", "--dataset-dir", str(self.dataset),
                                 "--match", str(match), "--baseline", str(self.paths["wispr"]), "--candidate", str(self.paths["flow"]),
                                 "--out", str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("overwrite", result.stderr)
        self.assertEqual(path.read_text(), original)

    def test_malformed_frozen_structures_and_model_name_refuse_cleanly(self):
        original = copy.deepcopy(self.match)
        for key, value in (("cases", [None] * len(self.cases)), ("sliceDefinitions", [])):
            self.match = copy.deepcopy(original)
            self.match[key] = value
            self.match["matchID"] = export.digest(export.canonical({k: v for k, v in self.match.items() if k != "matchID"}))
            with self.assertRaises(ValueError):
                self.compare()
        self.match = original
        self.metadata["wispr"]["identity"]["modelName"] = ["Canto2"]
        self.write_capture("wispr")
        with self.assertRaisesRegex(ValueError, "identity"):
            self.compare()

    def test_changed_frozen_match_or_unreviewed_dataset_is_refused(self):
        self.match["cases"][0]["audioSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "match hash"):
            self.compare()
        self.cases[0]["label"] = "unchanged"
        self.write_dataset()
        with self.assertRaisesRegex(ValueError, "reviewed"):
            load_dataset(self.dataset, "valid")

    def test_cli_freeze_compare_and_private_report(self):
        audio_map = self.root / "audio-map.jsonl"
        protocol = self.root / "protocol.json"
        match = self.root / "match.json"
        report = self.root / "report.json"
        audio_map.write_text("".join(export.canonical(row) + "\n" for row in self.audio_map))
        protocol.write_text(export.canonical(self.protocol))
        frozen = subprocess.run([sys.executable, str(SCRIPTS / "flow_competition.py"), "freeze", "--dataset-dir", str(self.dataset),
                                 "--audio-map", str(audio_map), "--protocol", str(protocol), "--out", str(match)], capture_output=True, text=True)
        self.assertEqual(frozen.returncode, 0, frozen.stderr)
        self.assertEqual(json.loads(match.read_text())["matchID"], self.match["matchID"])
        compared = subprocess.run([sys.executable, str(SCRIPTS / "flow_competition.py"), "compare", "--dataset-dir", str(self.dataset),
                                   "--match", str(match), "--baseline", str(self.paths["wispr"]), "--candidate", str(self.paths["flow"]),
                                   "--out", str(report)], capture_output=True, text=True)
        self.assertEqual(compared.returncode, 0, compared.stderr)
        self.assertTrue(json.loads(report.read_text())["eligibleForReview"])
        self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
