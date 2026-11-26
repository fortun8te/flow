"""Invented layout contracts: reviewed whitespace cannot hide behind word gains."""
from collections import Counter
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "Tests")]
import export_flow_runs as export
import flow_hillclimb as hill
import run_flow_candidate as replay
from test_flow_learning import case, lock, prediction, reviewed, run


class LayoutMetricTests(unittest.TestCase):
    def strict_case(self, target="Header\n  - Carry the violet kettle.  \n\nDone."):
        row = case("layout", target)
        row["requireExactLayout"] = True
        row["caseHash"] = export.case_hash(row)
        return row

    def test_structural_layout_detects_removed_indentation_and_hard_breaks(self):
        row = self.strict_case()
        for output in (row["target"].replace("\n  -", "\n-"), row["target"].replace(".  \n", ".\n")):
            scored = hill.score(row, prediction(row, output=output))
            self.assertEqual(scored["edits"], 0)
            self.assertIn("changed_layout", scored["critical"])
            self.assertFalse(scored["layoutExact"])

    def test_layout_does_not_require_same_word_spelling_or_case(self):
        row = self.strict_case()
        output = row["target"].replace("violet kettle", "Violet ketle")
        scored = hill.score(row, prediction(row, output=output))
        self.assertGreater(scored["edits"], 0)
        self.assertTrue(scored["layoutExact"])
        self.assertNotIn("changed_layout", scored["critical"])

    def test_ordinary_interior_word_spacing_is_separate_from_layout(self):
        row = self.strict_case()
        scored = hill.score(row, prediction(row, output=row["target"].replace("violet kettle", "violet   kettle")))
        self.assertTrue(scored["layoutExact"])
        self.assertEqual(scored["edits"], 0)
        self.assertFalse(scored["exact"])

    def test_existing_and_added_breaks_are_exact_including_outer_breaks(self):
        row = self.strict_case("\nA short note.\n\nNext sentence.\n")
        for output in (row["target"].strip(), row["target"].replace("\n\n", "\n"),
                       row["target"].replace("A short", "A\nshort"), row["target"] + "\n"):
            self.assertIn("changed_layout", hill.score(row, prediction(row, output=output))["critical"])

    def test_moving_a_break_between_words_is_detected(self):
        row = self.strict_case("The small\nblue kettle.")
        scored = hill.score(row, prediction(row, output="The small blue\nkettle."))
        self.assertIn("changed_layout", scored["critical"])

    def test_crlf_and_unicode_separators_remain_distinct(self):
        for separator in ("\r\n", "\r", "\v", "\f", "\x85", "\u2028", "\u2029"):
            row = self.strict_case("First line." + separator + "Next line.")
            self.assertTrue(hill.score(row, prediction(row))["layoutExact"])
            output = row["target"].replace(separator, "\n")
            self.assertIn("changed_layout", hill.score(row, prediction(row, output=output))["critical"])

    def test_jsonl_keeps_unicode_line_separators_inside_reviewed_text(self):
        rows = [{"output": "First" + separator + "Next"} for separator in ("\r\n", "\x85", "\u2028", "\u2029")]
        for delimiter in ("\n", "\r\n"):
            contents = delimiter.join(export.canonical(row) for row in rows) + delimiter
            self.assertEqual(hill.parse_jsonl(contents), rows)

    def test_list_heading_checkbox_quote_and_fence_prefixes_are_preserved(self):
        for target, output in (("- Item", "* Item"), ("1. Item", "1) Item"),
                               ("## Heading", "# Heading"), ("- [ ] Item", "- [x] Item"),
                               ("> Quote", ">> Quote"), ("```swift\ncode\n```", "~~~swift\ncode\n~~~")):
            row = self.strict_case(target)
            self.assertIn("changed_layout", hill.score(row, prediction(row, output=output))["critical"])

    def test_every_retained_attempt_must_preserve_reviewed_layout(self):
        row = self.strict_case()
        observed = prediction(row)
        observed["attempts"] = [prediction(row), prediction(row, output=row["target"].replace("\n  -", "\n-")), prediction(row)]
        scored = hill.score(row, observed)
        self.assertIn("changed_layout", scored["critical"])
        self.assertEqual(hill.aggregate([scored])["exactLayoutRate"], 0)

    def test_explicitly_reviewed_newline_only_command_is_not_empty_speech(self):
        row = self.strict_case("\n")
        row["input"] = "new line"
        row["caseHash"] = export.case_hash(row)
        exact = hill.score(row, prediction(row))
        self.assertTrue(exact["exact"])
        self.assertTrue(exact["layoutExact"])
        self.assertEqual(exact["critical"], [])
        wrong_break = hill.score(row, prediction(row, output="\n\n"))
        self.assertIn("changed_layout", wrong_break["critical"])
        self.assertNotIn("empty_output", wrong_break["critical"])
        for output in ("", " ", "\t"):
            self.assertIn("empty_output", hill.score(row, prediction(row, output=output))["critical"])

    def test_layout_only_output_cannot_replace_reviewed_text(self):
        row = self.strict_case("A line.\nAnother line.")
        self.assertIn("empty_output", hill.score(row, prediction(row, output="\n"))["critical"])

    def test_local_http_replay_retains_reviewed_newline_without_leaking_target(self):
        row = self.strict_case("\n")
        row["input"] = "new line"
        row["caseHash"] = export.case_hash(row)
        requests = []

        class Opener:
            def open(self, request, timeout):
                requests.append(json.loads(request.data))
                return io.BytesIO(json.dumps({"choices": [{"message": {"content": "\n"}, "finish_reason": "stop"}]}).encode())

        def invoke(case):
            return replay.request_case(case, "http://localhost/v1/chat/completions", "synthetic-model",
                                       "Edit the dictation.", 1, 64, opener=Opener())

        observed = replay.replay_cases([row], invoke, replay.benchmark_protocol(repetitions=3), "synthetic-model", "dataset")
        hill.predictions_by_id(observed, [row], "dataset")
        self.assertIsNone(observed[0]["error"])
        self.assertEqual(observed[0]["output"], "\n")
        self.assertTrue(hill.score(row, observed[0])["exact"])
        self.assertTrue(all(request["messages"][1]["content"] == "new line" for request in requests))
        self.assertTrue(all("target" not in request and "requireExactLayout" not in request for request in requests))
        ordinary = case("ordinary")
        self.assertEqual(invoke(ordinary)["error"], "empty-output")

    def test_layout_requirement_is_never_implicitly_enabled(self):
        row = case("ordinary", "Header\n  - Item")
        scored = hill.score(row, prediction(row, output="Header\n- Item"))
        self.assertIsNone(scored["layoutExact"])
        self.assertNotIn("changed_layout", scored["critical"])
        self.assertEqual(hill.aggregate([scored])["reviewedLayoutCases"], 0)
        self.assertIsNone(hill.aggregate([scored])["exactLayoutRate"])

    def test_quality_gain_cannot_promote_broken_reviewed_layout(self):
        cases = [self.strict_case(f"The violet kettle number {i} is ready.\n  - Carry it carefully.  \nDone.")
                 for i in range(50)]
        for index, row in enumerate(cases):
            row["id"] = row["groupID"] = str(index)
        baseline = [prediction(row, output=row["target"].replace("kettle", "ketle")) for row in cases]
        candidate = [prediction(row, model="candidate-config", output=row["target"].replace("\n  -", "\n-")) for row in cases]
        report = hill.compare(cases, baseline, candidate)
        self.assertTrue(report["gates"]["qualityImproved"])
        self.assertFalse(report["gates"]["noCriticalFailures"])
        self.assertFalse(report["eligibleForReview"])
        self.assertEqual(report["candidate"]["tokenErrorRate"], 0)
        self.assertEqual(report["candidate"]["criticalCounts"]["changed_layout"], 50)
        self.assertEqual(report["baseline"]["exactLayoutRate"], 1)
        self.assertEqual(report["candidate"]["exactLayoutRate"], 0)


class ReviewedLayoutExportTests(unittest.TestCase):
    def test_optional_false_keeps_existing_case_hash_and_true_changes_it(self):
        row = case("layout", "Header\n  - Item")
        old_hash = export.case_hash(row)
        row["requireExactLayout"] = False
        self.assertEqual(export.case_hash(row), old_hash)
        row["requireExactLayout"] = True
        self.assertNotEqual(export.case_hash(row), old_hash)

    def test_malformed_policy_is_rejected_by_hashing_scoring_and_review_loading(self):
        for value in (None, 0, 1, "true", [], {}):
            row = case("layout")
            row["requireExactLayout"] = value
            with self.assertRaisesRegex(ValueError, "requireExactLayout"):
                export.case_hash(row)
            with self.assertRaisesRegex(ValueError, "requireExactLayout"):
                hill.score(row, prediction(row))
            record = reviewed(run())
            record["reviewedLabel"]["requireExactLayout"] = value
            with self.assertRaisesRegex(ValueError, "requireExactLayout"):
                export.make_pair(record)
            with tempfile.TemporaryDirectory() as directory:
                entry = reviewed(run())["reviewedLabel"]
                entry["requireExactLayout"] = value
                path = Path(directory) / "labels.jsonl"
                path.write_text(json.dumps(entry) + "\n")
                with self.assertRaisesRegex(ValueError, "requireExactLayout"):
                    export.apply_labels([run()], path, Counter())

    def test_same_target_different_policy_deduplicates_with_the_stricter_review(self):
        first, second = reviewed(run("first")), reviewed(run("second"))
        first["reviewedLabel"]["requireExactLayout"] = False
        second["reviewedLabel"]["requireExactLayout"] = True
        for records in ((first, second), (second, first)):
            rows, _ = export.split_examples([export.make_pair(record) for record in records], lock())
            self.assertEqual(len(rows), 1)
            self.assertTrue(rows[0]["requireExactLayout"])
            self.assertEqual(rows[0]["caseHash"], export.case_hash(rows[0]))

    def test_newline_only_target_requires_explicit_review_and_survives_export(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            record = run("command", "new line", "\n")
            (source / "runs.jsonl").write_text(json.dumps(record) + "\n")
            labels = Path(directory) / "labels.jsonl"
            entry = reviewed(record)["reviewedLabel"]
            for target, policy in (("\n", False), ("\n", None), ("", True), (" ", True), ("\t", True)):
                rejected = dict(entry, target=target)
                if policy is not None:
                    rejected["requireExactLayout"] = policy
                labels.write_text(json.dumps(rejected) + "\n")
                with self.assertRaisesRegex(ValueError, "target required"):
                    export.apply_labels([record], labels, Counter())
            entry["requireExactLayout"] = True
            labels.write_text(json.dumps(entry) + "\n")
            export.export(source, out, labels=labels)
            exported = [row for split in ("train", "valid", "test") for row in hill.load_dataset(out, split)[1]]
            self.assertEqual(len(exported), 1)
            self.assertEqual(exported[0]["target"], "\n")
            self.assertTrue(hill.score(exported[0], prediction(exported[0]))["exact"])

    def test_same_asr_with_conflicting_target_layout_still_requires_review(self):
        first, second = reviewed(run("first"), "The violet kettle."), reviewed(run("second"), "The violet\nkettle.")
        first["reviewedLabel"]["requireExactLayout"] = True
        pairs = [export.make_pair(record) for record in (first, second)]
        rows, _ = export.split_examples(pairs, lock())
        self.assertEqual(rows, [])
        self.assertTrue(all(row["label"] == "conflicting-human-targets" for row in pairs))

    def test_layout_review_survives_export_and_load_and_binds_predictions(self):
        with tempfile.TemporaryDirectory() as directory:
            source, out = Path(directory) / "source", Path(directory) / "out"
            source.mkdir()
            records = [run(f"run-{i}", f"violet kettle {i}", f"Violet kettle {i}.\n  - Carry it.") for i in range(100)]
            (source / "runs.jsonl").write_text("".join(json.dumps(record) + "\n" for record in records))
            labels = Path(directory) / "labels.jsonl"
            entries = [dict(reviewed(record)["reviewedLabel"], requireExactLayout=True) for record in records]
            labels.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
            export.export(source, out, labels=labels)
            manifest, cases = hill.load_dataset(out, "valid")
            self.assertGreater(len(cases), 0)
            self.assertTrue(all(row["requireExactLayout"] for row in cases))
            row = cases[0]
            stale = prediction(row)
            stale["caseHash"] = export.case_hash({**row, "requireExactLayout": False})
            with self.assertRaisesRegex(ValueError, "stale prediction"):
                hill.predictions_by_id([stale], [row])

    def test_dataset_loader_rejects_a_policy_added_without_rehashing_the_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = case("layout")
            row["requireExactLayout"] = True
            files = {}
            for name in ("train.jsonl", "valid.jsonl", "test.jsonl"):
                contents = export.canonical(row) + "\n" if name == "valid.jsonl" else ""
                (root / name).write_text(contents)
                files[name] = {"sha256": export.digest(contents), "rows": int(bool(contents))}
            manifest = {"schemaVersion": export.EXPORT_SCHEMA, "splitPolicy": export.SPLIT_POLICY,
                        "files": files, "datasetID": export.digest(export.canonical(files))}
            (root / "manifest.json").write_text(export.canonical(manifest))
            with self.assertRaisesRegex(ValueError, "caseHash"):
                hill.load_dataset(root, "valid")


if __name__ == "__main__":
    unittest.main()
