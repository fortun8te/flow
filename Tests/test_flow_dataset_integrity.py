"""Invented regressions for complete snapshots, retractions and repeated scoring."""
from collections import Counter
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "Tests")]
import export_flow_runs as export
import flow_hillclimb as hill
import run_flow_candidate as replay
from test_flow_learning import case, lock, prediction, reviewed, run


def snapshot(directory, splits):
    """A legacy schema-2 fixture; deliberately no invented historical lock."""
    files = {}
    for name in ("train", "valid", "test"):
        rows = splits.get(name, [])
        contents = "".join(export.canonical(row) + "\n" for row in rows)
        (directory / (name + ".jsonl")).write_text(contents, encoding="utf-8")
        files[name + ".jsonl"] = {"sha256": export.digest(contents), "rows": len(rows)}
    manifest = {"schemaVersion": export.EXPORT_SCHEMA, "splitPolicy": export.SPLIT_POLICY,
                "files": files, "datasetID": export.digest(export.canonical(files))}
    (directory / "manifest.json").write_text(export.canonical(manifest), encoding="utf-8")
    return manifest


class StrictEvidenceTests(unittest.TestCase):
    def test_imported_run_cannot_self_approve_without_an_external_review_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, out = root / "source", root / "out"
            source.mkdir()
            record = reviewed(run())
            (source / "runs.jsonl").write_text(export.canonical(record) + "\n")
            manifest = export.export(source, out)
            self.assertEqual(manifest["supervisedExamples"], 0)
            self.assertNotIn("reviewedLabel", hill.read_jsonl(out / "runs-joined.jsonl")[0])
            labels = root / "reviewed-labels.jsonl"
            labels.write_text(export.canonical(record["reviewedLabel"]) + "\n")
            self.assertEqual(export.export(source, out, labels=labels)["supervisedExamples"], 1)

    def test_changed_duplicate_run_identity_cannot_discard_an_undo_alias(self):
        first, second = run(), run()
        first["settings"] = {"diffID": "old-card"}
        second["settings"] = {"diffID": "new-card"}
        feedback = {"id": "old-card", "kind": "followup", "followup": "undo"}
        joined = export.join([first, second, feedback])[0]
        self.assertEqual(export.label(reviewed(joined)), "conflicting-run-id")
        self.assertIsNone(export.target(reviewed(joined)))

    def test_direct_id_collision_with_another_changes_card_cannot_guess_an_undo_owner(self):
        one, two = run("shared-id"), run("two")
        two["settings"] = {"diffID": "shared-id"}
        feedback = {"id": "shared-id", "kind": "followup", "followup": "undo"}
        rows = export.join([one, two, feedback])
        self.assertTrue(all(row.get("ambiguousFeedback") for row in rows))
        self.assertTrue(all(export.target(reviewed(row)) is None for row in rows))

    def test_duplicate_key_cannot_hide_an_undo_in_a_previously_reviewed_corpus(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, out, labels = root / "source", root / "out", root / "labels.jsonl"
            source.mkdir()
            record = run()
            (source / "runs.jsonl").write_text(json.dumps(record) + "\n")
            labels.write_text(json.dumps(reviewed(record)["reviewedLabel"]) + "\n")
            self.assertEqual(export.export(source, out, labels=labels)["supervisedExamples"], 1)
            with (source / "runs.jsonl").open("a") as handle:
                handle.write('{"id":"r1","kind":"followup","followup":"undo","followup":"edited"}\n')
            manifest = export.export(source, out, labels=labels)
            self.assertTrue(manifest["supervisedBlocked"])
            self.assertEqual(manifest["diagnostics"]["invalidJSON"], 1)
            self.assertEqual(manifest["supervisedExamples"], 0)
            for name in ("train", "valid", "test"):
                self.assertEqual((out / (name + ".jsonl")).read_bytes(), b"")

    def test_strict_decoder_rejects_nested_duplicates_and_all_nonfinite_spellings(self):
        for contents in ('{"a":{"followup":"undo","followup":"edited"}}',
                         '{"a":[{"output":"old","output":"new"}]}',
                         '{"a":NaN}', '{"a":Infinity}', '{"a":-Infinity}', '{"a":1e999}'):
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                export.strict_json_loads(contents)
        self.assertEqual(export.strict_json_loads('{"a":1.25,"b":[null,false]}'), {"a": 1.25, "b": [None, False]})

    def test_non_utf8_and_excessive_nesting_are_value_errors(self):
        for contents in ('{"a":1}'.encode("utf-16"), '[' * 10_000 + '0' + ']' * 10_000):
            with self.assertRaises(ValueError):
                export.strict_json_loads(contents)

    def test_prediction_jsonl_rejects_ambiguous_output_and_status(self):
        for contents in ('{"output":"bad","output":"good"}\n', '{"latencyMs":1e999}\n'):
            with self.assertRaises(ValueError):
                hill.parse_jsonl(contents)

    def test_nonfinite_source_metadata_blocks_supervision(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "runs.jsonl"
            path.write_text('{"id":"one","kind":"dictation","input":"invented","timingsMs":{"total":1e999}}\n')
            diagnostics = Counter()
            self.assertEqual(list(export.read_records(temporary, diagnostics)), [])
            self.assertEqual(diagnostics["invalidJSON"], 1)

    def test_malformed_recording_identity_cannot_silently_drop_a_family_link(self):
        for field in ("audioPath", "audioSHA256", "sourceRecordingID", "recordingID"):
            with self.subTest(field=field):
                record = run()
                record["settings"] = {field: 42}
                self.assertFalse(export.valid_record(record))

    def test_rewritten_source_is_detected_even_when_size_and_mtime_are_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "runs.jsonl"
            original = json.dumps(run(text="violet kettle")) + "\n"
            path.write_text(original)
            initial = path.stat()
            original_validator = export.valid_record

            def mutate(record):
                path.write_text(original.replace("violet", "copper"))
                os.utime(path, ns=(initial.st_atime_ns, initial.st_mtime_ns))
                return original_validator(record)

            diagnostics = Counter()
            with patch.object(export, "valid_record", side_effect=mutate):
                list(export.read_records(temporary, diagnostics))
            self.assertEqual(path.stat().st_size, initial.st_size)
            self.assertEqual(path.stat().st_mtime_ns, initial.st_mtime_ns)
            self.assertEqual(diagnostics["sourceChanged"], 1)

    def test_changing_review_file_refuses_export_before_replacing_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, out, labels = root / "source", root / "out", root / "labels.jsonl"
            source.mkdir()
            record = run()
            (source / "runs.jsonl").write_text(json.dumps(record) + "\n")
            labels.write_text(json.dumps(reviewed(record)["reviewedLabel"]) + "\n")
            export.export(source, out, labels=labels)
            previous = (out / "manifest.json").read_bytes()
            check = export.has_reviewed_target

            def mutate(label):
                labels.write_text("")  # A simultaneous human retraction must not be silently retained.
                return check(label)

            with patch.object(export, "has_reviewed_target", side_effect=mutate), self.assertRaisesRegex(ValueError, "label file changed"):
                export.export(source, out, labels=labels)
            self.assertEqual((out / "manifest.json").read_bytes(), previous)


class ObservationFamilyTests(unittest.TestCase):
    def bridge(self, undone=False):
        one = reviewed(run("one", "violet kettle", "Violet kettle."))
        two = reviewed(run("two", "copper lantern", "Copper lantern."))
        one["audioPath"] = "/Users/example/audio/original.caf"
        two["audioSHA256"] = "b" * 64
        bridge = run("bridge", "another recognition of the same recording")
        bridge.update(audioPath=one["audioPath"], audioSHA256=two["audioSHA256"])
        if undone:
            bridge = reviewed(bridge)
            bridge["followups"] = [{"followup": "undo"}]
        registry = lock()
        registry["assignments"] = {export.fingerprint(one["input"]): "train", export.fingerprint(two["input"]): "test"}
        pairs = [export.make_pair(item) for item in (one, two, bridge)]
        return pairs, registry

    def test_unreviewed_recording_bridge_quarantines_train_test_overlap_without_becoming_a_target(self):
        pairs, registry = self.bridge()
        rows, updated = export.split_examples(pairs, registry)
        self.assertEqual(rows, [])
        self.assertEqual({pair["label"] for pair in pairs[:2]}, {"split-contamination"})
        self.assertIsNone(pairs[2]["target"])
        self.assertFalse(pairs[2]["trainingEligible"])
        self.assertEqual(set(updated["assignments"].values()), {"quarantine"})

    def test_undo_retracts_the_target_without_erasing_its_recording_identity(self):
        pairs, registry = self.bridge(undone=True)
        rows, updated = export.split_examples(pairs, registry)
        self.assertEqual(rows, [])
        self.assertEqual(pairs[2]["label"], "undone")
        self.assertIsNone(pairs[2]["target"])
        self.assertEqual(set(updated["assignments"].values()), {"quarantine"})

    def test_conflicting_target_reviews_do_not_erase_a_cross_split_bridge(self):
        one = reviewed(run("one", "violet kettle", "Violet kettle."))
        two = reviewed(run("two", "copper lantern", "Copper lantern."))
        first_bridge = reviewed(run("bridge-a", "an ambiguous invented input"), one["output"])
        second_bridge = reviewed(run("bridge-b", "an ambiguous invented input"), two["output"])
        registry = lock()
        registry["assignments"] = {export.fingerprint(one["input"]): "train", export.fingerprint(two["input"]): "test"}
        pairs = [export.make_pair(item) for item in (one, two, first_bridge, second_bridge)]
        rows, updated = export.split_examples(pairs, registry)
        self.assertEqual(rows, [])
        self.assertEqual({pair["label"] for pair in pairs[2:]}, {"conflicting-human-targets"})
        self.assertEqual(set(updated["assignments"].values()), {"quarantine"})

    def test_unreviewed_runs_without_recording_links_do_not_reserve_held_out_families(self):
        pairs = [export.make_pair(run("one")), export.make_pair(run("two", "unreviewed other input"))]
        rows, registry = export.split_examples(pairs, lock())
        self.assertEqual(rows, [])
        self.assertEqual(registry["assignments"], {})


class CompleteSnapshotTests(unittest.TestCase):
    def test_legacy_snapshot_and_empty_splits_still_load(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot(root, {"valid": [case("one")]})
            self.assertEqual(hill.load_dataset(root, "train")[1], [])
            self.assertEqual(len(hill.load_dataset(root, "valid")[1]), 1)

    def test_unselected_training_rows_and_counts_are_validated(self):
        for mutation in ("unreviewed", "row-count", "non-object"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                train = {**case("train", "A copper lantern."), "split": "train"}
                if mutation == "unreviewed":
                    train["label"] = "model-observation"
                manifest = snapshot(root, {"train": [train], "valid": [case("valid")]})
                if mutation == "row-count":
                    manifest["files"]["train.jsonl"]["rows"] += 1
                if mutation == "non-object":
                    content = '[]\n'
                    (root / "train.jsonl").write_text(content)
                    manifest["files"]["train.jsonl"]["sha256"] = export.digest(content)
                manifest["datasetID"] = export.digest(export.canonical(manifest["files"]))
                (root / "manifest.json").write_text(export.canonical(manifest))
                with self.assertRaises(ValueError):
                    hill.load_dataset(root, "valid")

    def test_family_identity_cannot_be_split_across_train_and_validation(self):
        for overlap in ("input", "target", "recording", "group", "source"):
            with self.subTest(overlap=overlap), tempfile.TemporaryDirectory() as temporary:
                one = {**case("one", "A copper lantern."), "split": "train"}
                two = case("two", "A violet kettle.")
                if overlap == "input":
                    two.update(input=one["input"].upper(), target=one["target"])
                elif overlap == "target":
                    two["target"] = one["target"]
                elif overlap == "recording":
                    one["recordingKeys"] = two["recordingKeys"] = ["recording:" + "a" * 64]
                elif overlap == "group":
                    two["groupID"] = one["groupID"]
                else:
                    one["sourceRunIDs"] = ["one", "shared-source"]
                    two["sourceRunIDs"] = ["two", "shared-source"]
                two["caseHash"] = export.case_hash(two)
                snapshot(Path(temporary), {"train": [one], "valid": [two]})
                with self.assertRaises(ValueError):
                    hill.load_dataset(temporary, "valid")

    def test_one_target_family_cannot_claim_two_independent_validation_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            one, two = case("one"), case("two")
            two["input"] = "a violet ketle is on shelf 2"
            two["caseHash"] = export.case_hash(two)
            snapshot(Path(temporary), {"valid": [one, two]})
            with self.assertRaisesRegex(ValueError, "counted independently"):
                hill.load_dataset(temporary, "valid")

    def test_duplicate_case_ids_across_splits_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            one = {**case("same", "A copper lantern."), "split": "train"}
            snapshot(Path(temporary), {"train": [one], "valid": [case("same")]})
            with self.assertRaisesRegex(ValueError, "duplicate case id"):
                hill.load_dataset(temporary, "valid")

    def test_malformed_review_metadata_fails_without_a_python_type_crash(self):
        for field, value in (("trainingEligible", "true"), ("groupID", None), ("app", []), ("kind", {}),
                             ("inputFingerprint", "stale"), ("inputHash", "stale"),
                             ("schemaVersion", True), ("targetProvenance", None),
                             ("sourceRunIDs", ["one", "one"]), ("recordingKeys", {})):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                row = case("one")
                row[field] = value
                snapshot(Path(temporary), {"valid": [row]})
                with self.assertRaises(ValueError):
                    hill.load_dataset(temporary, "valid")

    def test_boolean_file_counts_are_not_valid_integers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = snapshot(root, {"valid": [case("one")]})
            manifest["files"]["valid.jsonl"]["rows"] = True
            manifest["datasetID"] = export.digest(export.canonical(manifest["files"]))
            (root / "manifest.json").write_text(export.canonical(manifest))
            with self.assertRaisesRegex(ValueError, "row count"):
                hill.load_dataset(root, "valid")

    def test_declared_split_history_cannot_be_omitted_or_modified(self):
        for mutation in ("missing", "modified"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source, out = root / "source", root / "out"
                source.mkdir()
                export.export(source, out)
                if mutation == "missing":
                    (out / "split-lock.json").unlink()
                else:
                    (out / "split-lock.json").write_text("{}\n")
                with self.assertRaises((OSError, ValueError)):
                    hill.load_dataset(out, "valid")

    def test_case_family_must_agree_with_a_declared_matching_history(self):
        for field in ("assignments", "groups"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                row = case("one")
                manifest = snapshot(root, {"valid": [row]})
                keys = {export.fingerprint(row["input"]), export.fingerprint(row["target"])}
                registry = {**lock(), "assignments": {key: "valid" for key in keys},
                            "groups": {key: row["groupID"] for key in keys}}
                registry[field][next(iter(keys))] = "train" if field == "assignments" else "wrong-family"
                content = export.canonical(registry) + "\n"
                (root / "split-lock.json").write_text(content)
                manifest["splitLockSHA256"] = export.digest(content)
                (root / "manifest.json").write_text(export.canonical(manifest))
                with self.assertRaisesRegex(ValueError, "locked family history"):
                    hill.load_dataset(root, "valid")


class RepeatedScoringTests(unittest.TestCase):
    def repeated(self, row, outputs):
        result = prediction(row)
        protocol = replay.benchmark_protocol(repetitions=len(outputs))
        samples = [{"id": row["id"], "caseHash": row["caseHash"], "sampleIndex": index,
                    "output": output, "latencyMs": 100, "finish_reason": "stop"} for index, output in enumerate(outputs)]
        result.update(output=outputs[0], attempts=samples, benchmarkProtocol=protocol,
                      benchmarkProtocolID=export.digest(export.canonical(protocol)))
        return result

    def test_identical_repeats_score_text_once_and_keep_every_latency_and_failure(self):
        row = case("one", "Tasks:\n  - Carry the kettle.")
        row["requireExactLayout"] = True
        row["caseHash"] = export.case_hash(row)
        result = self.repeated(row, [row["target"]] * 6)
        result["attempts"][-1].update(error="deadline-exceeded", latencyMs=31_000)
        with patch.object(hill, "edit_distance", wraps=hill.edit_distance) as distance:
            scored = hill.score(row, result)
        self.assertEqual(distance.call_count, 1)
        self.assertEqual(scored["edits"], 0)
        self.assertEqual(scored["latenciesMs"], [100] * 5 + [31_000])
        self.assertIn("runtime_failure", scored["critical"])
        self.assertFalse(scored["exact"])

    def test_distinct_outputs_keep_frequency_weighting_and_every_guard(self):
        row = case("one", "Do not carry kettle 2.")
        bad = "Do carry kettle 3."
        result = self.repeated(row, [row["target"], bad, bad])
        with patch.object(hill, "edit_distance", wraps=hill.edit_distance) as distance:
            scored = hill.score(row, result)
        self.assertEqual(distance.call_count, 2)
        expected_distance = hill.edit_distance(hill.TOKENS.findall(row["target"]), hill.TOKENS.findall(bad))
        self.assertAlmostEqual(scored["edits"], 2 * expected_distance / 3)
        self.assertEqual(set(scored["critical"]), {"unstable_output", "changed_number", "changed_negation"})

    def test_late_success_is_a_runtime_failure_even_when_its_error_field_is_omitted(self):
        row = case("one")
        result = prediction(row, latency=31_000)
        hill.predictions_by_id([result], [row])
        self.assertIn("runtime_failure", hill.score(row, result)["critical"])

    def test_status_types_and_huge_latency_fail_closed(self):
        row = case("one")
        for field, value in (("error", []), ("error", False), ("finish_reason", {}), ("latencyMs", 10 ** 10_000)):
            with self.subTest(field=field):
                result = prediction(row)
                result[field] = value
                with self.assertRaises(ValueError):
                    hill.predictions_by_id([result], [row])
        self.assertFalse(hill.positive_number(10 ** 10_000))

    def test_repeated_sample_status_type_is_checked_even_when_header_is_clean(self):
        row = case("one")
        result = self.repeated(row, [row["target"]] * 2)
        result["attempts"][1]["error"] = False
        with self.assertRaisesRegex(ValueError, "attempt status"):
            hill.predictions_by_id([result], [row])

    def test_duplicate_case_ids_cannot_multiply_one_prediction_into_independent_evidence(self):
        row = case("one")
        duplicate = {**row, "groupID": "a-different-claimed-family"}
        with self.assertRaisesRegex(ValueError, "unique ids"):
            hill.compare([row, duplicate], [prediction(row)], [prediction(row, model="candidate")])

    def test_boolean_policy_and_concurrency_are_not_valid_counts(self):
        row = case("one")
        with self.assertRaises(ValueError):
            hill.compare([row], [prediction(row)], [prediction(row, model="candidate")], min_cases=True)
        result = prediction(row)
        result["benchmarkProtocol"]["concurrency"] = True
        result["benchmarkProtocolID"] = export.digest(export.canonical(result["benchmarkProtocol"]))
        with self.assertRaisesRegex(ValueError, "sequential"):
            hill.predictions_by_id([result], [row])


class StreamingExportTests(unittest.TestCase):
    def test_streamed_rows_keep_identical_hashes_utf8_and_private_permissions(self):
        rows = [{"id": "one", "text": "Invented café\u2028second line"}, {"id": "two", "text": "\n"}]
        expected = "".join(export.canonical(row) + "\n" for row in rows)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "snapshot.jsonl"
            path.write_text("older content")
            os.chmod(path, 0o644)
            result = export.write_private_jsonl(path, iter(rows))
            self.assertEqual(path.read_bytes(), expected.encode("utf-8"))
            self.assertEqual(result, {"sha256": export.digest(expected), "rows": len(rows)})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_serialization_failure_keeps_prior_file_and_cleans_temporary_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "snapshot.jsonl"
            path.write_bytes(b"previous complete snapshot\n")
            with self.assertRaises(TypeError):
                export.write_private_jsonl(path, [{"id": "good"}, {"not-json": object()}])
            self.assertEqual(path.read_bytes(), b"previous complete snapshot\n")
            self.assertEqual(list(Path(temporary).glob(".flow-export-*")), [])


if __name__ == "__main__":
    unittest.main()
