"""Invented benchmark cases and local subprocesses; no model weights or inference."""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("flow_bench_integrity", HERE / "flow_bench.py")
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)


def case(identifier="one", text="The violet kettle is on shelf 2."):
    return {"id": identifier, "raw": text, "expect": text, "kind": "dictation", "category": "invented"}


def result(identifier="one", text="The violet kettle is on shelf 2.", seconds=0.1, error=None, finish="stop"):
    return {"id": identifier, "output": text, "seconds": seconds, "error": error, "finish_reason": finish}


def reference_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, token in enumerate(left, 1):
        row = [i]
        for j, other in enumerate(right, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (token != other)))
        previous = row
    return previous[-1]


class ScoringIntegrityTests(unittest.TestCase):
    def test_matching_text_with_error_or_truncation_is_not_a_pass(self):
        for output in (result(error="timeout"), result(finish="length"), result(finish=None), result(finish="unknown")):
            row = fb.evaluate(case(), output)
            self.assertFalse(row["fully_right"])
            self.assertFalse(row["zero_edit"])
            self.assertFalse(row["unchanged"])
            self.assertTrue(row["call_failed"])

    def test_invalid_timing_cannot_be_counted_as_success(self):
        for value in (None, math.nan, math.inf, -0.1, True):
            row = fb.evaluate(case(), result(seconds=value))
            self.assertFalse(row["fully_right"])
            self.assertFalse(row["timing_valid"])

    def test_failed_and_empty_calls_stay_in_latency_distribution(self):
        rows = [fb.evaluate(case(), result(seconds=1)), fb.evaluate(case(), result(text="", seconds=30, error="timeout"))]
        summary = fb.summarise(rows)
        self.assertEqual(summary["lat_median"], 15.5)
        self.assertEqual(summary["lat_p95"], 30)
        self.assertEqual(summary["successful_lat_median"], 1)
        self.assertEqual(summary["failed_calls"], 1)
        self.assertEqual(summary["latency_n"], 2)

    def test_prediction_alignment_rejects_duplicate_extra_and_missing(self):
        for outputs in ([result(), result()], [result(), result("extra")], []):
            with self.assertRaises(RuntimeError):
                fb.score_outputs("fixture", [case()], outputs, "fixture-engine")

    def test_duplicate_suite_ids_are_rejected(self):
        with self.assertRaises(ValueError):
            fb.score_outputs("fixture", [case(), case()], [result()], "fixture-engine")

    def test_added_word_rate_does_not_use_truncated_display_list(self):
        text = "copper bronze silver golden crimson scarlet lavender emerald azure ochre beige ivory magenta"
        row = fb.evaluate(case(text="violet kettle"), result(text=text))
        row["out_words"] = len(text.split())
        self.assertGreater(row["invented_count"], 8)
        self.assertEqual(len(row["invented_list"]), 8)
        self.assertEqual(fb.summarise([row])["added_per_100"], round(100 * row["invented_count"] / row["out_words"], 2))

    def test_case_fingerprint_changes_with_expected_contract(self):
        before = [case()]
        after = [dict(case(), expect="The violet kettle is on shelf 3.")]
        self.assertNotEqual(fb.suite_fingerprint(before), fb.suite_fingerprint(after))


class ModelIdentityTests(unittest.TestCase):
    def test_llama_request_honors_explicit_system_and_control_contract(self):
        cfg = {"system": "Edit carefully.", "control_line": "[Styling: semi-formal]", "chat_template_kwargs": {"enable_thinking": False}}
        body = fb.llama_request("violet ketle", cfg)
        self.assertEqual(body["messages"], [{"role": "system", "content": "Edit carefully."},
                                           {"role": "user", "content": "[Styling: semi-formal]\nviolet ketle"}])
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        self.assertEqual(fb.llama_request("violet ketle", {})["messages"], [{"role": "user", "content": "violet ketle"}])

    def test_same_size_and_restored_mtime_cannot_reuse_stale_hash(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(fb, "HASH_CACHE", Path(directory) / "cache.json"):
            path = Path(directory) / "model.gguf"
            path.write_bytes(b"first")
            old = path.stat()
            first = fb.sha256_file(path)
            path.write_bytes(b"other")
            os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
            self.assertNotEqual(fb.sha256_file(path), first)
            self.assertEqual(fb.sha256_file(path), hashlib.sha256(b"other").hexdigest())

    def test_corrupt_optional_hash_cache_does_not_break_fingerprinting(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(fb, "HASH_CACHE", Path(directory) / "cache.json"):
            fb.HASH_CACHE.write_text("partial json")
            path = Path(directory) / "model.gguf"
            path.write_bytes(b"invented artifact")
            self.assertEqual(fb.sha256_file(path), hashlib.sha256(b"invented artifact").hexdigest())

    def test_mlx_identity_covers_every_weight_shard_and_tokenizer(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(fb, "HASH_CACHE", Path(directory) / "cache/hash.json"):
            root = Path(directory)
            (root / "model-00001.safetensors").write_bytes(b"first shard")
            second = root / "model-00002.safetensors"
            second.write_bytes(b"second shard")
            (root / "tokenizer.json").write_text('{"invented": true}')
            (root / "merges.txt").write_text("invented tokenizer merge")
            cfg = {"kind": "mlx", "label": "fixture", "model_dir": directory, "python": sys.executable, "system": "Edit carefully."}
            first = fb.engine_identity("fixture", cfg)
            self.assertEqual(first["weights_files"], 2)
            self.assertIn("tokenizer.json", first["artifact_sha256"])
            self.assertIn("merges.txt", first["artifact_sha256"])
            second.write_bytes(b"changed shard")
            self.assertNotEqual(fb.engine_identity("fixture", cfg)["model_sha256"], first["model_sha256"])


class WorkerLifecycleTests(unittest.TestCase):
    def test_hung_case_is_killed_reaped_and_pending_cases_remain_failures(self):
        script = ('import json,time\n'
                  'print("FLOW_BENCH_EVENT " + json.dumps({"event":"loaded"}), flush=True)\n'
                  'print("FLOW_BENCH_EVENT " + json.dumps({"event":"case","result":'
                  + repr(result()) + '}), flush=True)\n'
                  'time.sleep(10)\n')
        owned = []
        original = subprocess.Popen

        def launch(*args, **kwargs):
            process = original(*args, **kwargs)
            owned.append(process)
            return process

        with tempfile.TemporaryDirectory() as directory, patch.object(fb.subprocess, "Popen", side_effect=launch):
            rows, _ = fb.run_mlx_worker([sys.executable, "-u", "-c", script], [case(), case("two"), case("three")],
                                        Path(directory), load_timeout=1, case_timeout=0.05)
        self.assertEqual(len(rows), 3)
        self.assertIsNone(rows[0]["error"])
        self.assertEqual(rows[1]["error"], "worker-case-timeout")
        self.assertGreaterEqual(rows[1]["seconds"], 0.05)
        self.assertIsNone(rows[2]["seconds"])
        self.assertEqual(rows[2]["error"], "not-run-after-worker-failure")
        self.assertIsNotNone(owned[0].returncode)

    def test_worker_exiting_before_ready_never_scores_identity_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            rows, _ = fb.run_mlx_worker([sys.executable, "-c", "raise SystemExit(1)"], [case()], Path(directory), 1, 1)
        self.assertIsNone(rows[0]["output"])
        self.assertIsNone(rows[0]["seconds"])
        self.assertTrue(rows[0]["error"])

    def test_hung_load_has_its_own_short_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            rows, _ = fb.run_mlx_worker([sys.executable, "-c", "import time; time.sleep(10)"], [case()], Path(directory), 0.05, 1)
        self.assertEqual(rows[0]["error"], "worker-load-timeout")
        self.assertIsNone(rows[0]["seconds"])


class ExactDistanceTests(unittest.TestCase):
    def test_bit_distance_matches_reference_on_randomized_and_unicode_cases(self):
        rng = random.Random(301)
        tokens = ["violet", "kettle", "☕", "café", "\n", "2", "."]
        for _ in range(500):
            left = [rng.choice(tokens) for _ in range(rng.randrange(90))]
            right = [rng.choice(tokens) for _ in range(rng.randrange(90))]
            self.assertEqual(fb.WN.edit_distance(left, right), reference_distance(left, right))
            self.assertEqual(fb.WN.edit_distance(left, right), fb.WN.edit_distance(right, left))

    def test_long_equal_edges_keep_exact_single_change_distance(self):
        left = ["violet"] * 1200 + ["kettle"] + ["shelf"] * 1200
        right = ["violet"] * 1200 + ["lantern"] + ["shelf"] * 1200
        self.assertEqual(fb.WN.edit_distance(left, right), 1)


if __name__ == "__main__":
    unittest.main()
