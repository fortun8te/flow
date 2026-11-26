"""Invented fixtures for reviewed-label export and paired hillclimb gates."""
from collections import Counter
import copy
import io
import json
import math
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import export_flow_runs as export
import flow_hillclimb as hill
import run_flow_candidate as replay


def run(identifier="r1", text="the violet kettle is on shelf 2", output="The violet kettle is on shelf 2."):
    return {"id": identifier, "kind": "dictation", "recordedAt": "2026-01-01T12:00:00Z", "input": text,
            "output": output, "outcome": "verified", "stages": [], "followups": []}


def reviewed(record, target=None):
    record = copy.deepcopy(record)
    record["reviewedLabel"] = {"id": record["id"], "inputHash": export.digest(record["input"]),
                               "target": target or record["output"], "source": "human-reviewed", "scope": "pasted-span"}
    return record


def lock():
    return {"schemaVersion": 1, "policy": export.SPLIT_POLICY, "assignments": {}}


def case(identifier, text="The violet kettle is on shelf 2.", kind="dictation"):
    row = {"id": identifier, "input": text.lower(), "target": text, "kind": kind, "groupID": identifier,
           "trainingEligible": True, "label": "human-reviewed", "split": "valid"}
    row["caseHash"] = export.case_hash(row)
    return row


def prediction(row, model="baseline-sha+prompt-v1", output=None, latency=100):
    protocol = replay.benchmark_protocol()
    return {"id": row["id"], "caseHash": row["caseHash"], "modelID": model,
            "output": row["target"] if output is None else output, "latencyMs": latency, "finish_reason": "stop",
            "benchmarkProtocol": protocol, "benchmarkProtocolID": export.digest(export.canonical(protocol)), "warmupSucceeded": True}


class LearningExportTests(unittest.TestCase):
    def test_readback_never_approves_a_target(self):
        for outcome in ("verified", "applied", "unconfirmed", "unchanged", "readback-failed", "readback-mismatch"):
            record = run()
            record["outcome"] = outcome
            self.assertIsNone(export.target(record))
            self.assertFalse(export.make_pair(record)["trainingEligible"])

    def test_scoped_observation_is_a_proposal_not_truth(self):
        record = run()
        record["followups"] = [{"followup": "edited", "editedText": "The violet kettle is on shelf 3.",
                                "feedbackSource": "observed-edit", "targetScope": "pasted-span"}]
        row = export.make_pair(record)
        self.assertEqual(row["label"], "correction-candidate")
        self.assertEqual(row["proposedTarget"], "The violet kettle is on shelf 3.")
        self.assertIsNone(row["target"])

    def test_legacy_whole_field_edit_never_becomes_target(self):
        record = run()
        record["followups"] = [{"followup": "edited", "editedText": "Earlier note. The violet kettle is on shelf 3."}]
        row = export.make_pair(record)
        self.assertEqual(row["label"], "edited-unscoped")
        self.assertIsNone(row["proposedTarget"])
        self.assertIsNone(row["target"])

    def test_undo_invalidates_even_a_reviewed_label(self):
        record = reviewed(run())
        record["followups"] = [{"followup": "edited", "editedText": "old observation"}, {"followup": "undo-paste"}]
        self.assertEqual(export.label(record), "undone")
        self.assertIsNone(export.target(record))

    def test_join_recovers_diff_link_and_orders_feedback(self):
        record = run()
        record["kind"] = "opt1"
        record["settings"] = {"diffID": "d1"}
        records = [record, {"kind": "followup", "id": "d1", "recordedAt": "2026-01-01T12:00:02Z", "followup": "undo"},
                   {"kind": "followup", "id": "d1", "recordedAt": "2026-01-01T12:00:01Z", "followup": "edited"}]
        result = export.join(records)[0]
        self.assertEqual([f["followup"] for f in result["followups"]], ["edited", "undo"])

    def test_conflicting_duplicate_run_ids_cannot_be_labelled(self):
        first, second = run(), run(text="a completely different invented phrase")
        result = export.join([first, second])[0]
        self.assertEqual(export.label(reviewed(result)), "conflicting-run-id")

    def test_duplicate_diff_ids_do_not_guess_feedback_owner(self):
        one, two = run("one"), run("two")
        one["settings"] = two["settings"] = {"diffID": "same"}
        diagnostics = Counter()
        rows = export.join([one, two, {"kind": "followup", "id": "same", "followup": "undo"}], diagnostics)
        self.assertTrue(all(not r["followups"] for r in rows))
        self.assertEqual(diagnostics["unmatchedFollowup"], 1)
        self.assertTrue(all(export.target(reviewed(r)) is None for r in rows))

    def test_normalized_duplicates_do_not_cross_splits_or_gain_weight(self):
        one = reviewed(run("one", "violet kettle"), "Violet kettle.")
        two = reviewed(run("two", "VIOLET   kettle!"), "Violet kettle.")
        rows, registry = export.split_examples([export.make_pair(one), export.make_pair(two)], lock())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["sourceRunIDs"], ["one", "two"])
        self.assertEqual(len(set(registry["assignments"].values())), 1)

    def test_distinct_error_variants_with_identical_target_stay_together(self):
        records = [reviewed(run("one", "violet ketle"), "Violet kettle."),
                   reviewed(run("two", "vilet kettle"), "Violet kettle.")]
        rows, _ = export.split_examples([export.make_pair(r) for r in records], lock())
        self.assertEqual(len(rows), 2)
        self.assertEqual(len({r["split"] for r in rows}), 1)
        self.assertEqual(len({r["groupID"] for r in rows}), 1)

    def test_one_recording_with_different_asr_and_targets_is_one_family(self):
        one = reviewed(run("one", "a violet ketle", "A violet kettle."))
        two = reviewed(run("two", "the copper lamp", "The copper lamp."))
        one["audioPath"] = two["audioPath"] = "/Users/example/audio/recording-example.caf"
        rows, _ = export.split_examples([export.make_pair(one), export.make_pair(two)], lock())
        self.assertEqual(len(rows), 2)
        self.assertEqual(len({r["groupID"] for r in rows}), 1)
        self.assertEqual(len({r["split"] for r in rows}), 1)

    def test_audio_content_identity_groups_copies_with_different_paths(self):
        one = reviewed(run("one", "a violet ketle", "A violet kettle."))
        two = reviewed(run("two", "the copper lamp", "The copper lamp."))
        one["audioPath"], two["audioPath"] = "/Users/example/audio/one.caf", "/Users/example/audio/copy.caf"
        one["audioSHA256"] = two["audioSHA256"] = "a" * 64
        rows, _ = export.split_examples([export.make_pair(one), export.make_pair(two)], lock())
        self.assertEqual(len({r["groupID"] for r in rows}), 1)

    def test_duplicate_labels_combine_protected_literals(self):
        one, two = reviewed(run("one")), reviewed(run("two"))
        one["reviewedLabel"]["mustContain"] = ["violet"]
        two["reviewedLabel"]["mustContain"] = ["shelf 2"]
        rows, _ = export.split_examples([export.make_pair(one), export.make_pair(two)], lock())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["mustContain"], ["shelf 2", "violet"])

    def test_conflicting_targets_go_to_review(self):
        records = [reviewed(run("one"), "Violet kettle."), reviewed(run("two"), "Copper kettle.")]
        pairs = [export.make_pair(r) for r in records]
        rows, _ = export.split_examples(pairs, lock())
        self.assertEqual(rows, [])
        self.assertTrue(all(r["label"] == "conflicting-human-targets" for r in pairs))

    def test_new_data_preserves_locked_assignments(self):
        pair = export.make_pair(reviewed(run()))
        rows, registry = export.split_examples([pair], lock())
        old_split = rows[0]["split"]
        another = export.make_pair(reviewed(run("other", "a copper lantern", "A copper lantern.")))
        rows, _ = export.split_examples([copy.deepcopy(pair), another], registry)
        self.assertEqual(next(r["split"] for r in rows if r["id"] == "r1"), old_split)

    def test_linking_previously_separate_splits_quarantines_the_component(self):
        registry = lock()
        registry["assignments"] = {export.fingerprint("violet kettle"): "train", export.fingerprint("copper kettle"): "test"}
        pair = export.make_pair(reviewed(run(text="violet kettle"), "copper kettle"))
        rows, registry = export.split_examples([pair], registry)
        self.assertEqual(rows, [])
        self.assertEqual(pair["label"], "split-contamination")
        self.assertEqual(set(registry["assignments"].values()), {"quarantine"})

    def test_quarantine_reaches_historical_family_members_after_rotation(self):
        registry = lock()
        old = export.fingerprint("violet ketle")
        target = export.fingerprint("violet kettle")
        other = export.fingerprint("copper kettle")
        registry["assignments"] = {old: "train", target: "train", other: "test"}
        registry["groups"] = {old: old, target: old, other: other}
        # The old typo has rotated away; only its corrected target is now visible.
        pair = export.make_pair(reviewed(run(text="violet kettle"), "copper kettle"))
        _, updated = export.split_examples([pair], registry)
        self.assertEqual(updated["assignments"][old], "quarantine")

    def test_export_drops_later_undo_and_writes_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            record = run()
            path = source / "runs.jsonl"
            path.write_text(json.dumps(record) + "\n")
            labels = Path(directory) / "labels.jsonl"
            labels.write_text(json.dumps(reviewed(record)["reviewedLabel"]) + "\n")
            result = export.export(source, out, labels=labels)
            self.assertEqual(result["supervisedExamples"], 1)
            self.assertEqual(os.stat(out / "train.jsonl").st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(out).st_mode & 0o777, 0o700)
            with path.open("a") as handle:
                handle.write(json.dumps({"id": "r1", "kind": "followup", "followup": "undo"}) + "\n")
            result = export.export(source, out, labels=labels)
            self.assertEqual(result["supervisedExamples"], 0)
            self.assertEqual(result["labels"], {"undone": 1})

    def test_labels_must_match_exact_input_and_explicit_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "labels.jsonl"
            entry = reviewed(run())["reviewedLabel"]
            entry["inputHash"] = "wrong"
            path.write_text(json.dumps(entry) + "\n")
            with self.assertRaisesRegex(ValueError, "inputHash"):
                export.apply_labels([run()], path, Counter())
            entry["inputHash"] = export.digest(run()["input"])
            entry["scope"] = "field"
            path.write_text(json.dumps(entry) + "\n")
            with self.assertRaisesRegex(ValueError, "scope"):
                export.apply_labels([run()], path, Counter())

    def test_corrupt_feedback_clears_previously_supervised_files_and_blocks_gate(self):
        corruptions = [b'{"id":"r1","kind":"followup","followup":"undo"', b'\xff\n',
                       b'{"id":"r1","kind":"followup","followup":[]}\n',
                       b'{"id":"r1","kind":"followup"}\n']
        for corruption in corruptions:
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory() as directory:
                source, out = Path(directory) / "source", Path(directory) / "out"
                source.mkdir()
                record = run()
                source_file = source / "runs.jsonl"
                source_file.write_text(json.dumps(record) + "\n")
                labels = Path(directory) / "labels.jsonl"
                labels.write_text(json.dumps(reviewed(record)["reviewedLabel"]) + "\n")
                self.assertEqual(export.export(source, out, labels=labels)["supervisedExamples"], 1)
                with source_file.open("ab") as handle:
                    handle.write(corruption)
                manifest = export.export(source, out, labels=labels)
                self.assertTrue(manifest["supervisedBlocked"])
                self.assertEqual(manifest["supervisedExamples"], 0)
                for split in ("train", "valid", "test"):
                    self.assertEqual((out / (split + ".jsonl")).read_text(), "")
                with self.assertRaisesRegex(ValueError, "source integrity"):
                    hill.load_dataset(out, "valid")
                completed = subprocess.run([sys.executable, str(SCRIPTS / "export_flow_runs.py"), "--source", str(source),
                                            "--out", str(out), "--labels", str(labels)], capture_output=True, text=True)
                self.assertEqual(completed.returncode, 2)
                self.assertIn("stable source snapshot", completed.stderr)

    def test_appending_during_source_read_marks_snapshot_unstable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runs.jsonl"
            path.write_text(json.dumps(run()) + "\n")
            diagnostics = Counter()
            iterator = export.read_records(directory, diagnostics)
            next(iterator)
            with path.open("a") as handle:
                handle.write(json.dumps({"id": "r1", "kind": "followup", "followup": "undo"}) + "\n")
            list(iterator)
            self.assertEqual(diagnostics["sourceChanged"], 1)

    def test_malformed_lines_are_counted_without_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "runs.jsonl").write_bytes(
                b'{not json}\n[]\n{"kind":"dictation"}\n{"id":"bad","settings":[]}\n'
                b'{"id":"bad-diff","settings":{"diffID":[]}}\n\xff\n'
                + (json.dumps(run()) + "\n").encode())
            diagnostics = Counter()
            rows = list(export.read_records(directory, diagnostics))
            self.assertEqual(len(rows), 1)
            self.assertEqual(diagnostics["invalidJSON"], 2)
            self.assertEqual(diagnostics["invalidRecord"], 4)

    def test_reviewed_literal_constraints_are_retained_and_hashed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "labels.jsonl"
            entry = reviewed(run())["reviewedLabel"]
            entry.update(mustContain=["violet", "shelf 2"], mustNotContain=["copper"])
            path.write_text(json.dumps(entry) + "\n")
            record = run()
            export.apply_labels([record], path, Counter())
            row = export.make_pair(record)
            self.assertEqual(row["mustContain"], ["violet", "shelf 2"])
            original_hash = export.case_hash(row)
            row["mustContain"].append("kettle")
            self.assertNotEqual(original_hash, export.case_hash(row))
            entry["mustContain"] = ["not present"]
            path.write_text(json.dumps(entry) + "\n")
            with self.assertRaisesRegex(ValueError, "contradicts"):
                export.apply_labels([run()], path, Counter())

    def test_missing_split_lock_on_existing_export_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            export.export(source, out)
            (out / "split-lock.json").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                export.export(source, out)

    def test_concurrent_export_process_cannot_overwrite_split_history(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            export.export(source, out)
            prior_lock = (out / "split-lock.json").read_bytes()
            prior_manifest = (out / "manifest.json").read_bytes()
            with export.output_lock(out):
                completed = subprocess.run([sys.executable, str(SCRIPTS / "export_flow_runs.py"), "--source", str(source),
                                            "--out", str(out)], capture_output=True, text=True, timeout=5)
                self.assertEqual(completed.returncode, 2)
                self.assertIn("another Flow export", completed.stderr)
                self.assertEqual((out / "split-lock.json").read_bytes(), prior_lock)
                self.assertEqual((out / "manifest.json").read_bytes(), prior_manifest)
            # The retained lock file does not block a later process after ownership ends.
            self.assertTrue((out / ".export.lock").exists())
            self.assertEqual(export.export(source, out)["supervisedExamples"], 0)

    def test_valid_json_split_lock_reset_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            record = run()
            (source / "runs.jsonl").write_text(json.dumps(record) + "\n")
            labels = Path(directory) / "labels.jsonl"
            labels.write_text(json.dumps(reviewed(record)["reviewedLabel"]) + "\n")
            export.export(source, out, labels=labels)
            manifest_before = (out / "manifest.json").read_bytes()
            (out / "split-lock.json").write_text(export.canonical(lock()) + "\n")
            with self.assertRaisesRegex(ValueError, "split-lock hash mismatch"):
                export.export(source, out, labels=labels)
            self.assertEqual((out / "manifest.json").read_bytes(), manifest_before)

    def test_nonexistent_source_does_not_overwrite_existing_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            export.export(source, out)
            before = (out / "manifest.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "existing directory"):
                export.export(Path(directory) / "typo", out)
            self.assertEqual((out / "manifest.json").read_bytes(), before)


class HillclimbGateTests(unittest.TestCase):
    def dataset(self, count=50):
        return [case(f"case-{i}", f"The violet kettle is on shelf {i + 1}.") for i in range(count)]

    def outputs(self, cases):
        baseline = [prediction(c, output=c["target"].replace("kettle", "ketle")) for c in cases]
        candidate = [prediction(c, model="candidate-sha+prompt-v2") for c in cases]
        return baseline, candidate

    def test_real_paired_improvement_can_pass_but_never_auto_promotes(self):
        cases = self.dataset()
        report = hill.compare(cases, *self.outputs(cases))
        self.assertTrue(report["eligibleForReview"])
        self.assertFalse(report["promoted"])
        self.assertEqual(report["groupWins"], 50)
        self.assertEqual(report["rollbackCandidateID"], "baseline-sha+prompt-v1")

    def test_tiny_sample_cannot_pass_default_gate(self):
        cases = self.dataset(4)
        report = hill.compare(cases, *self.outputs(cases))
        self.assertFalse(report["eligibleForReview"])
        self.assertFalse(report["gates"]["enoughIndependentCases"])

    def test_repeated_family_is_one_independent_case(self):
        cases = self.dataset()
        for c in cases:
            c["groupID"] = "one-family"
        report = hill.compare(cases, *self.outputs(cases))
        self.assertEqual(report["independentGroups"], 1)
        self.assertFalse(report["eligibleForReview"])

    def test_missing_duplicate_and_stale_outputs_fail_closed(self):
        cases = self.dataset(2)
        baseline, candidate = self.outputs(cases)
        with self.assertRaisesRegex(ValueError, "missing predictions"):
            hill.compare(cases, baseline, candidate[:-1])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            hill.compare(cases, baseline, candidate + [candidate[0]])
        candidate[0]["caseHash"] = "old"
        with self.assertRaisesRegex(ValueError, "stale"):
            hill.compare(cases, baseline, candidate)

    def test_complete_dataset_identity_is_required_by_cli_comparison_contract(self):
        cases = self.dataset()
        baseline, candidate = self.outputs(cases)
        for row in baseline + candidate:
            row["datasetID"] = "current-context-and-settings"
        self.assertTrue(hill.compare(cases, baseline, candidate, dataset_id="current-context-and-settings")["eligibleForReview"])
        candidate[0]["datasetID"] = "old-context-and-settings"
        with self.assertRaisesRegex(ValueError, "datasetID"):
            hill.compare(cases, baseline, candidate, dataset_id="current-context-and-settings")

    def test_overall_quality_gain_cannot_damage_previously_exact_output(self):
        cases = self.dataset()
        baseline, candidate = self.outputs(cases)
        baseline[0]["output"] = cases[0]["target"]
        candidate[0]["output"] = cases[0]["target"].replace("kettle", "lantern")
        report = hill.compare(cases, baseline, candidate)
        self.assertTrue(report["gates"]["qualityImproved"])
        self.assertTrue(report["gates"]["noCriticalFailures"])
        self.assertFalse(report["gates"]["preservesBaselineExactCases"])
        self.assertFalse(report["eligibleForReview"])

    def test_nonfinite_missing_and_negative_latency_fail(self):
        cases = self.dataset(1)
        for value in (None, 0, -1, math.nan, math.inf, True):
            baseline, candidate = self.outputs(cases)
            candidate[0]["latencyMs"] = value
            with self.assertRaisesRegex(ValueError, "latencyMs"):
                hill.compare(cases, baseline, candidate)

    def test_quality_win_does_not_hide_changed_number_or_negation(self):
        cases = self.dataset()
        baseline, candidate = self.outputs(cases)
        candidate[0]["output"] = "The violet kettle is not on shelf 300."
        report = hill.compare(cases, baseline, candidate)
        self.assertFalse(report["gates"]["noCriticalFailures"])
        self.assertEqual(report["candidate"]["criticalCounts"]["changed_number"], 1)
        self.assertEqual(report["candidate"]["criticalCounts"]["changed_negation"], 1)
        self.assertFalse(report["eligibleForReview"])

    def test_url_and_repeated_numbers_are_preserved(self):
        c = case("url", "Send 2 then 2 to sample.user@example.com and https://example.com/blue.")
        p = prediction(c, output="Send 2 to sample.user@example.net and https://example.com/red.")
        result = hill.score(c, p)
        self.assertIn("changed_number", result["critical"])
        self.assertIn("changed_literal", result["critical"])

    def test_swapping_numbers_is_a_critical_error(self):
        c = case("swap", "Move the violet kettle from shelf 3 to shelf 5.")
        p = prediction(c, output="Move the violet kettle from shelf 5 to shelf 3.")
        self.assertIn("changed_number", hill.score(c, p)["critical"])

    def test_human_literal_constraints_protect_names_and_identifiers(self):
        c = case("protected", "Keep CopperWidget in bin BLUE-3.")
        c.update(mustContain=["CopperWidget", "BLUE-3"], mustNotContain=["VioletWidget"])
        result = hill.score(c, prediction(c, output="Keep VioletWidget in bin BLUE-3."))
        self.assertIn("missing_required_text", result["critical"])
        self.assertIn("forbidden_text", result["critical"])

    def test_slow_quality_win_is_rejected(self):
        cases = self.dataset()
        baseline, candidate = self.outputs(cases)
        for p in candidate:
            p["latencyMs"] = 200
        report = hill.compare(cases, baseline, candidate)
        self.assertFalse(report["gates"]["latencyWithinBudget"])

    def test_identical_quality_cannot_pass(self):
        cases = self.dataset()
        baseline, candidate = self.outputs(cases)
        for p, b in zip(candidate, baseline):
            p["output"] = b["output"]
        report = hill.compare(cases, baseline, candidate)
        self.assertFalse(report["gates"]["qualityImproved"])
        self.assertFalse(report["gates"]["pairedEvidence"])

    def test_app_regression_cannot_be_hidden_by_other_app(self):
        cases = self.dataset(60)
        baseline, candidate = self.outputs(cases)
        for index, c in enumerate(cases):
            c["app"] = "example.editor" if index < 10 else "example.notes"
            if index < 10:
                baseline[index]["output"] = c["target"]
                candidate[index]["output"] = c["target"].replace("kettle", "ketle")
        report = hill.compare(cases, baseline, candidate)
        self.assertTrue(report["gates"]["qualityImproved"])
        self.assertFalse(report["gates"]["noSliceRegression"])

    def test_dataset_hash_detects_partial_or_modified_export(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            export.export(source, out)
            manifest, rows = hill.load_dataset(out, "valid")
            self.assertEqual(rows, [])
            (out / "train.jsonl").write_text("edited\n")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                hill.load_dataset(out, "valid")

    def test_exported_reviewed_cases_load_with_constraints_and_complete_predictions(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            records = [run(f"run-{i}", f"violet kettle number {i}", f"Violet kettle number {i}.") for i in range(200)]
            (source / "runs.jsonl").write_text("".join(json.dumps(r) + "\n" for r in records))
            labels = Path(directory) / "labels.jsonl"
            reviewed_labels = []
            for r in records:
                entry = reviewed(r)["reviewedLabel"]
                entry["mustContain"] = ["Violet kettle"]
                reviewed_labels.append(entry)
            labels.write_text("".join(json.dumps(entry) + "\n" for entry in reviewed_labels))
            export.export(source, out, labels=labels)
            manifest, cases = hill.load_dataset(out, "valid")
            self.assertGreater(len(cases), 5)
            baseline, candidate = self.outputs(cases)
            result = hill.compare(cases, baseline, candidate, min_cases=5)
            self.assertTrue(result["eligibleForReview"])
            self.assertTrue(all(c["mustContain"] == ["Violet kettle"] for c in cases))

    def test_dataset_parses_the_verified_bytes_when_file_changes_after_read(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            export.export(source, out)
            original_read = Path.read_bytes
            selected_reads = []

            def changing_read(path):
                content = original_read(path)
                if path == out / "valid.jsonl":
                    selected_reads.append(path)
                    path.write_text("replacement after verified read\n")
                return content

            with patch.object(Path, "read_bytes", changing_read):
                _, rows = hill.load_dataset(out, "valid")
            self.assertEqual(rows, [])
            self.assertEqual(len(selected_reads), 1)

    def test_sign_test_uses_independent_wins_and_ignores_ties(self):
        self.assertEqual(hill.sign_test(0, 0), 1.0)
        self.assertEqual(hill.sign_test(2, 4), 1.0)
        self.assertAlmostEqual(hill.sign_test(5, 0), 0.03125)
        self.assertLess(hill.sign_test(1000, 0), 1e-100)


class LocalReplayTests(unittest.TestCase):
    def test_repeated_replay_uses_workload_rounds_and_retains_slow_failed_attempt(self):
        cases = [case("one"), case("two")]
        order = []

        def invoke(row):
            order.append(row["id"])
            failed = len(order) == 3
            return {"id": row["id"], "caseHash": row["caseHash"], "output": row["target"],
                    "error": "timeout" if failed else None, "finish_reason": "timeout" if failed else "stop",
                    "latencyMs": 1000 if failed else 10}

        rows = replay.replay_cases(cases, invoke, replay.benchmark_protocol(repetitions=3), "candidate", "dataset")
        self.assertEqual(order, ["one", "two", "one", "two", "one", "two"])
        self.assertEqual(rows[0]["error"], "attempt-failed")
        self.assertEqual(len(rows[0]["attempts"]), 3)
        hill.predictions_by_id(rows, cases, "dataset")
        result = hill.aggregate([hill.score(case, row) for case, row in zip(cases, rows)])
        self.assertEqual(result["p95Ms"], 1000)
        self.assertEqual(result["latencySamples"], 6)
        self.assertEqual(result["criticalCases"], 1)
        self.assertEqual(result["exactRate"], 0.5)

    def test_prefix_template_options_cache_and_actual_usage_are_preserved(self):
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append(json.loads(request.data))
                return io.BytesIO(json.dumps({"choices": [{"message": {"content": "Violet kettle."}, "finish_reason": "stop"}],
                                              "usage": {"prompt_tokens": 12, "completion_tokens": 4}}).encode())

        c = case("one")
        result = replay.request_case(c, "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100,
                                     Opener(), "[Styling: semi-formal]\n", {"enable_thinking": False}, "off")
        self.assertEqual(requests[0]["messages"][1]["content"], "[Styling: semi-formal]\n" + c["input"])
        self.assertEqual(requests[0]["chat_template_kwargs"], {"enable_thinking": False})
        self.assertIs(requests[0]["cache_prompt"], False)
        self.assertEqual((result["promptTokens"], result["completionTokens"]), (12, 4))

    def test_missing_or_invalid_usage_is_unavailable_and_bad_json_shape_is_failure(self):
        class Opener:
            def __init__(self, value):
                self.value = value

            def open(self, request, timeout):
                return io.BytesIO(json.dumps(self.value).encode())

        for usage in (None, {"completion_tokens": True}, {"completion_tokens": -1}, {"completion_tokens": "4"}):
            result = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100,
                Opener({"choices": [{"message": {"content": "Violet kettle."}, "finish_reason": "stop"}], "usage": usage}))
            self.assertIsNone(result["completionTokens"])
        result = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100, Opener([]))
        self.assertEqual(result["error"], "ValueError")

    def test_unknown_finish_empty_reply_and_overdue_reply_are_failures(self):
        class Opener:
            def __init__(self, output, reason):
                self.output, self.reason = output, reason

            def open(self, request, timeout):
                return io.BytesIO(json.dumps({"choices": [{"message": {"content": self.output}, "finish_reason": self.reason}]}).encode())

        for output, reason in (("Violet kettle.", None), (" ", "stop")):
            row = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100, Opener(output, reason))
            self.assertTrue(row["error"])
        with patch.object(replay.time, "perf_counter", side_effect=[0, 2]):
            row = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100, Opener("Violet kettle.", "stop"))
        self.assertEqual(row["finish_reason"], "timeout")
        self.assertEqual(row["latencyMs"], 2000)

    def test_zero_warmup_cannot_claim_calibrated_timing(self):
        c = case("one")
        p = prediction(c)
        p["benchmarkProtocol"] = replay.benchmark_protocol(warmup_requests=0)
        p["benchmarkProtocolID"] = export.digest(export.canonical(p["benchmarkProtocol"]))
        with self.assertRaisesRegex(ValueError, "warmup calibration"):
            hill.predictions_by_id([p], [c])

    def test_only_explicit_loopback_endpoints_are_allowed(self):
        for url in ("https://example.com/v1/chat/completions", "file:///tmp/example",
                    "http://127.0.0.1.example.com/v1/chat/completions", "http://user:password@localhost/v1/chat/completions",
                    "http://localhost/v1/chat/completions?token=value"):
            with self.assertRaises(ValueError):
                replay.validate_endpoint(url)
        for url in ("http://127.0.0.1:8080/v1/chat/completions", "http://[::1]:8080/v1/chat/completions"):
            self.assertEqual(replay.validate_endpoint(url), url)

    def test_http_redirect_cannot_forward_private_input(self):
        with self.assertRaisesRegex(ValueError, "redirect"):
            replay.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com/")

    def test_request_never_sends_the_reference_target(self):
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append(json.loads(request.data))
                return io.BytesIO(json.dumps({"choices": [{"message": {"content": "Violet kettle."}, "finish_reason": "stop"}]}).encode())

        c = case("one", "Distinct private human reference.")
        c["input"] = "violet ketle"
        row = replay.request_case(c, "http://localhost:8080/v1/chat/completions", "local", "Edit carefully.", 1, 100, Opener())
        self.assertEqual(requests[0]["messages"], [{"role": "system", "content": "Edit carefully."},
                                                  {"role": "user", "content": "violet ketle"}])
        self.assertIsNone(row["error"])
        self.assertEqual(row["output"], "Violet kettle.")
        self.assertGreater(row["latencyMs"], 0)

    def test_server_error_does_not_leak_exception_text(self):
        class Opener:
            def open(self, request, timeout):
                raise OSError("invented private server diagnostic")

        row = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100, Opener())
        self.assertEqual(row["error"], "OSError")
        self.assertEqual(row["output"], "")
        self.assertNotIn("invented private", json.dumps(row))

    def test_truncated_server_output_is_a_failure(self):
        class Opener:
            def open(self, request, timeout):
                return io.BytesIO(json.dumps({"choices": [{"message": {"content": "Violet"}, "finish_reason": "length"}]}).encode())

        row = replay.request_case(case("one"), "http://localhost/v1/chat/completions", "local", "Edit.", 1, 100, Opener())
        self.assertEqual(row["error"], "incomplete-response")


if __name__ == "__main__":
    unittest.main()
