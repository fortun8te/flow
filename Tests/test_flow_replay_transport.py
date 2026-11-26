"""Invented loopback HTTP workloads; no model or device speed claims."""
from contextlib import contextmanager
import http.server
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import export_flow_runs as export
import flow_engine_tune as engine
import run_flow_candidate as replay


def case(identifier="violet"):
    row = {"id": identifier, "input": "the violet ketle", "target": "The violet kettle.", "kind": "dictation"}
    row["caseHash"] = export.case_hash(row)
    return row


def completion(output="The violet kettle."):
    return {"model": "invented-cleanup", "choices": [{"index": 0, "message": {"role": "assistant", "content": output},
                                                     "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5}}


def respond(handler, payload=None):
    payload = json.dumps(completion()).encode() if payload is None else payload
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)
    handler.wfile.flush()


@contextmanager
def local_server(callback=respond):
    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            connection, address = super().get_request()
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.connections += 1
            return connection, address

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            self.server.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            try:
                callback(self)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = Server(("127.0.0.1", 0), Handler)
    server.connections = 0
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1/chat/completions", server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


class ReplayTransportTests(unittest.TestCase):
    def request(self, endpoint, client=None, timeout=1):
        return replay.request_case(case(), endpoint, "invented-cleanup", "Edit the invented dictation.", timeout, 64, client)

    def test_one_connection_handles_all_successful_attempts_without_proxy_routing(self):
        with local_server() as (endpoint, server):
            client = replay.LocalChatClient(endpoint)
            self.addCleanup(client.close)
            with patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "no_proxy": ""}):
                rows = [self.request(endpoint, client) for _ in range(6)]
            self.assertTrue(all(row["error"] is None for row in rows))
            self.assertEqual(server.connections, 1)
            self.assertEqual(len(server.requests), 6)
            self.assertEqual(rows[0]["serverModel"], "invented-cleanup")
            self.assertFalse(any(isinstance(thread, threading.Timer) for thread in threading.enumerate()))

    def test_slow_drip_body_cannot_extend_absolute_deadline_and_next_request_recovers(self):
        def drip_once(handler):
            if len(handler.server.requests) != 1:
                respond(handler)
                return
            payload = json.dumps(completion()).encode()
            handler.send_response(200)
            handler.send_header("Content-Length", str(len(payload)))
            handler.end_headers()
            for index in range(0, len(payload), 2):
                handler.wfile.write(payload[index:index + 2])
                handler.wfile.flush()
                time.sleep(0.02)

        with local_server(drip_once) as (endpoint, server):
            client = replay.LocalChatClient(endpoint)
            self.addCleanup(client.close)
            started = time.monotonic()
            row = self.request(endpoint, client, timeout=0.08)
            elapsed = time.monotonic() - started
            self.assertEqual((row["error"], row["finish_reason"]), ("deadline-exceeded", "timeout"))
            self.assertLess(elapsed, 0.4)
            self.assertIsNone(client.connection)
            self.assertIsNone(self.request(endpoint, client)["error"])
            self.assertEqual(len(server.requests), 2)  # No invisible retry of the failed sample.
            self.assertEqual(server.connections, 2)
            self.assertFalse(any(isinstance(thread, threading.Timer) for thread in threading.enumerate()))

    def test_slow_drip_headers_cannot_extend_deadline(self):
        def drip_headers(handler):
            handler.wfile.write(b"HTTP/1.1 200 OK\r\nX-Invented: ")
            for _ in range(60):
                handler.wfile.write(b"x")
                handler.wfile.flush()
                time.sleep(0.02)

        with local_server(drip_headers) as (endpoint, server):
            started = time.monotonic()
            row = self.request(endpoint, timeout=0.08)
            self.assertLess(time.monotonic() - started, 0.4)
            self.assertEqual(row["error"], "deadline-exceeded")
            self.assertEqual(len(server.requests), 1)

    def test_redirect_does_not_resend_private_input(self):
        def redirect(handler):
            handler.send_response(307)
            handler.send_header("Location", "http://127.0.0.1:1/collect")
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        with local_server(redirect) as (endpoint, server):
            self.assertEqual(self.request(endpoint)["error"], "ValueError")
            self.assertEqual(len(server.requests), 1)

    def test_oversized_declared_response_is_rejected_before_waiting_for_body(self):
        def oversized(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", str(replay.MAX_RESPONSE_BYTES + 1))
            handler.end_headers()

        with local_server(oversized) as (endpoint, _):
            row = self.request(endpoint)
            self.assertEqual(row["error"], "ValueError")
            self.assertLess(row["latencyMs"], 400)

    def test_ambiguous_framing_is_refused(self):
        def ambiguous(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "0")
            handler.send_header("Transfer-Encoding", "chunked")
            handler.end_headers()

        with local_server(ambiguous) as (endpoint, _):
            self.assertEqual(self.request(endpoint)["error"], "ValueError")

    def test_valid_json_inside_truncated_http_body_is_still_a_failure(self):
        def truncated(handler):
            payload = json.dumps(completion()).encode()
            handler.send_response(200)
            handler.send_header("Content-Length", str(len(payload) + 100))
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(payload)
            handler.close_connection = True

        with local_server(truncated) as (endpoint, _):
            self.assertEqual(self.request(endpoint)["error"], "ValueError")

    def test_malformed_or_ambiguous_json_is_a_failed_attempt_not_a_crash(self):
        invalid = [b"[" * 2000 + b"0" + b"]" * 2000,
                   b'{"choices": [], "choices": []}', b'{"choices": [], "invented": NaN}']
        wrong_role = completion()
        wrong_role["choices"][0]["message"]["role"] = "user"
        tool_call = completion()
        tool_call["choices"][0]["message"]["tool_calls"] = [{"id": "invented-call"}]
        multiple = completion()
        multiple["choices"] *= 2
        wrong_index = completion()
        wrong_index["choices"][0]["index"] = True
        embedded_error = completion()
        embedded_error["error"] = {"message": "invented private diagnostic"}
        invalid += [json.dumps(value).encode() for value in (wrong_role, tool_call, multiple, wrong_index, embedded_error)]
        for payload in invalid:
            class Opener:
                def open(self, request, timeout):
                    return io.BytesIO(payload)

            with self.subTest(payload=payload[:30]):
                row = self.request("http://localhost/v1/chat/completions", Opener())
                self.assertEqual(row["error"], "ValueError")
                self.assertEqual(row["output"], "")
                self.assertNotIn("invented private diagnostic", json.dumps(row))

    def test_reported_completion_over_requested_cap_is_a_failure(self):
        value = completion()
        value["usage"]["completion_tokens"] = 65
        with local_server(lambda handler: respond(handler, json.dumps(value).encode())) as (endpoint, _):
            self.assertEqual(self.request(endpoint)["error"], "output-token-limit-exceeded")

    def test_oversized_input_never_reaches_http_adapter(self):
        class Opener:
            def open(self, *_args, **_kwargs):
                raise AssertionError("oversized request must not be sent")

        row = case()
        row["input"] = "x" * replay.MAX_REQUEST_BYTES
        result = replay.request_case(row, "http://localhost/v1/chat/completions", "local", "Edit.", 1, 64, Opener())
        self.assertEqual(result["error"], "ValueError")

    def test_invalid_ports_empty_userinfo_and_control_characters_are_refused(self):
        for endpoint in ("http://localhost:0/v1/chat/completions", "http://localhost:bad/v1/chat/completions",
                         "http://@localhost/v1/chat/completions", "http://localhost/v1/chat/completions?",
                         "http://local\thost/v1/chat/completions"):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                replay.validate_endpoint(endpoint)


class ReplayEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_reused_adapter_dictionary_does_not_rewrite_earlier_samples(self):
        observed = {"id": case()["id"], "caseHash": case()["caseHash"], "output": "The violet kettle.",
                    "finish_reason": "stop", "error": None, "latencyMs": 10}
        count = 0

        def invoke(_):
            nonlocal count
            count += 1
            observed["latencyMs"] = count * 10
            return observed

        rows = replay.replay_cases([case()], invoke, replay.benchmark_protocol(repetitions=3), "model", "dataset")
        self.assertEqual([sample["sampleIndex"] for sample in rows[0]["attempts"]], [0, 1, 2])
        self.assertEqual([sample["latencyMs"] for sample in rows[0]["attempts"]], [10, 20, 30])

    def test_prompt_and_prefix_preserve_exact_crlf_bytes(self):
        source = self.root / "prompt.txt"
        source.write_bytes(b"Edit.\r\nKeep layout.\r\n")
        self.assertEqual(replay.read_config(source), "Edit.\r\nKeep layout.\r\n")

    def test_artifact_manifest_verifies_each_shard_and_detects_midrun_changes(self):
        shard = self.root / "invented-weights.bin"
        shard.write_bytes(b"invented weight fixture")
        manifest = self.root / "artifact.json"
        manifest.write_text(json.dumps({"schemaVersion": 1, "files": [{"path": shard.name, "sha256": replay.artifact_hash(shard)}]}))
        identity, snapshots = replay.load_artifact(manifest=manifest)
        self.assertEqual(identity["artifactFormat"], "sha256-manifest-v1")
        replay.verify_artifact_snapshot(snapshots)
        shard.write_bytes(b"changed invented weights")
        with self.assertRaisesRegex(ValueError, "during replay"):
            replay.verify_artifact_snapshot(snapshots)
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            replay.load_artifact(manifest=manifest)

    def test_artifact_and_config_refuse_fifos_without_opening_them(self):
        fifo = self.root / "named-pipe"
        os.mkfifo(fifo)
        for call in (replay.artifact_hash, replay.read_config):
            with self.assertRaisesRegex(ValueError, "regular file"):
                call(fifo)

    def test_retargeted_shard_symlink_invalidates_the_artifact_snapshot(self):
        first, second = self.root / "first.bin", self.root / "second.bin"
        first.write_bytes(b"invented first shard")
        second.write_bytes(b"invented second shard")
        link = self.root / "active.bin"
        link.symlink_to(first)
        manifest = self.root / "artifact.json"
        manifest.write_text(json.dumps({"schemaVersion": 1, "files": [{"path": link.name, "sha256": replay.artifact_hash(first)}]}))
        _, snapshots = replay.load_artifact(manifest=manifest)
        link.unlink()
        link.symlink_to(second)
        with self.assertRaisesRegex(ValueError, "during replay"):
            replay.verify_artifact_snapshot(snapshots)

    def test_output_cannot_replace_input_or_run_concurrently(self):
        source = self.root / "weights.bin"
        source.write_bytes(b"invented frozen weights")
        with self.assertRaisesRegex(ValueError, "overwrite an input"):
            with replay.replay_output(source, [source]):
                pass
        self.assertEqual(source.read_bytes(), b"invented frozen weights")
        output = self.root / "run.jsonl"
        with replay.replay_output(output, [source]):
            with self.assertRaisesRegex(ValueError, "another replay"):
                with replay.replay_output(self.root / "candidate.jsonl", [source]):
                    pass

    def test_aborted_replay_clears_stale_prediction_and_manifest_evidence(self):
        output = self.root / "run.jsonl"
        output.write_text("previous successful output")
        with self.assertRaisesRegex(RuntimeError, "invented abort"):
            with replay.replay_output(output, []):
                self.assertEqual(output.read_text(), "")
                raise RuntimeError("invented abort")
        self.assertEqual(output.read_text(), "")
        self.assertEqual(json.loads(Path(str(output) + ".manifest.json").read_text())["status"], "aborted")

    def test_cli_cannot_overwrite_dataset_split_history_or_export_lock(self):
        artifact = self.root / "weights.bin"
        artifact.write_bytes(b"invented weights")
        prompt = self.root / "prompt.txt"
        prompt.write_text("Edit the invented text.")
        dataset = self.root / "dataset"
        dataset.mkdir()
        for filename in ("split-lock.json", ".export.lock", "additional-review.jsonl"):
            protected = dataset / filename
            protected.write_bytes(b"invented preserved dataset state")
            argv = ["run_flow_candidate.py", "--dataset-dir", str(dataset), "--model", "invented-cleanup",
                    "--artifact", str(artifact), "--prompt", str(prompt), "--runtime-id", "invented-control", "--out", str(protected)]
            metadata = {"datasetID": "dataset", "files": {"additional-review.jsonl": {}}}
            with patch.object(sys, "argv", argv), patch.object(replay, "load_dataset", return_value=(metadata, [case()])), \
                 patch.object(replay, "LocalChatClient") as client, patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit):
                replay.main()
            client.assert_not_called()
            self.assertEqual(protected.read_bytes(), b"invented preserved dataset state")

    def test_real_loopback_cli_writes_complete_hash_bound_engine_evidence(self):
        artifact = self.root / "weights.bin"
        artifact.write_bytes(b"invented weights")
        prompt = self.root / "prompt.txt"
        prompt.write_bytes(b"Edit.\r\nPreserve layout.")
        output = self.root / "predictions.jsonl"
        with local_server() as (endpoint, server):
            argv = ["run_flow_candidate.py", "--dataset-dir", str(self.root / "dataset"), "--endpoint", endpoint,
                    "--model", "invented-cleanup", "--artifact", str(artifact), "--prompt", str(prompt),
                    "--runtime-id", "invented-control", "--environment-id", "invented-machine",
                    "--repetitions", "6", "--out", str(output)]
            with patch.object(sys, "argv", argv), patch.object(replay, "load_dataset", return_value=({"datasetID": "dataset"}, [case()])), patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(replay.main(), 0)
            self.assertEqual(len(server.requests), 7)
            self.assertEqual(server.connections, 1)
            self.assertTrue(all(request["messages"][0]["content"] == "Edit.\r\nPreserve layout." for request in server.requests))
        run = engine.load_run(output, [case()], "dataset", "valid")
        self.assertEqual(run["metadata"]["status"], "complete")
        self.assertEqual(engine.metrics(run)["failedAttempts"], 0)
        self.assertEqual(run["serverModels"], {"invented-cleanup"})
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
