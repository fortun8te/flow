#!/usr/bin/env python3
"""Replay frozen reviewed cases through an already-running local cleanup server.

Uses an OpenAI-compatible /v1/chat/completions endpoint on loopback only. Sends
the raw input with an explicit optional prefix and system prompt, never the human target. Writes private
predictions for flow_hillclimb.py; no downloads, model swaps, or retries occur.
The supplied artifact must be the one loaded by the server. HTTP cannot prove
that relationship; declare the engine build/flags in --runtime-id and the machine,
OS and power regime in --environment-id for engine tuning.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import http.client
import math
import os
from pathlib import Path
import socket
import stat
import statistics
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from export_flow_runs import canonical, digest, strict_json_loads, write_private, write_private_jsonl
from flow_hillclimb import empty_output, load_dataset, validate_protocol

MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_CONFIG_BYTES = 256 * 1024


class DeadlineExceeded(TimeoutError):
    """The whole HTTP request, including a slow-drip response, used its budget."""


class _RequestDeadline:
    def __init__(self, connection, timeout):
        self.connection = connection
        self.socket = connection.sock
        self.expired = False
        self.finished = False
        self.lock = threading.Lock()
        self.timer = threading.Timer(timeout, self._expire)
        self.timer.daemon = True
        self.timer.start()

    @staticmethod
    def _shutdown(sock):
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

    def _expire(self):
        with self.lock:
            if self.finished:
                return
            self.expired = True
            sock = self.socket or self.connection.sock
        # shutdown wakes a blocking buffered read; close alone does not reliably
        # interrupt it. The request stays on the caller, so no worker is orphaned.
        self._shutdown(sock)

    def attach(self, sock):
        with self.lock:
            self.socket = sock
            expired = self.expired
        if expired:
            self._shutdown(sock)
            raise DeadlineExceeded()

    def finish(self):
        with self.lock:
            self.finished = True
        self.timer.cancel()
        self.timer.join()
        self.connection.deadline = None
        self.connection = self.socket = self.timer = None


class _DeadlineConnection:
    def connect(self):
        super().connect()
        self.deadline.attach(self.sock)


class _HTTPConnection(_DeadlineConnection, http.client.HTTPConnection):
    pass


class _HTTPSConnection(_DeadlineConnection, http.client.HTTPSConnection):
    pass


class LocalChatClient:
    """One sequential, reusable loopback connection; never proxy, redirect or retry."""

    def __init__(self, endpoint):
        self.endpoint = validate_endpoint(endpoint)
        self.url = urllib.parse.urlsplit(endpoint)
        self.connection = None

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    @contextmanager
    def open(self, request, timeout):
        if request.full_url != self.endpoint or request.get_method() != "POST":
            raise ValueError("client is bound to one loopback POST endpoint")
        if self.connection is None:
            connection_type = _HTTPSConnection if self.url.scheme == "https" else _HTTPConnection
            self.connection = connection_type(self.url.hostname, self.url.port, timeout=timeout)
            # localhost must stay local even with an unexpected hosts/DNS entry.
            # An IPv6-only server can be addressed explicitly with [::1].
            connect_host = "127.0.0.1" if self.url.hostname == "localhost" else self.url.hostname
            self.connection._create_connection = lambda address, timeout, source_address: socket.create_connection(
                (connect_host, address[1]), timeout, source_address)
        connection = self.connection
        connection.timeout = timeout
        if connection.sock is not None:
            connection.sock.settimeout(timeout)
        deadline = _RequestDeadline(connection, timeout)
        connection.deadline = deadline
        response = None
        try:
            connection.request("POST", self.url.path, body=request.data,
                               headers={"Content-Type": "application/json", "Accept": "application/json",
                                        "Accept-Encoding": "identity"})
            response = connection.getresponse()
            if 300 <= response.status < 400:
                raise ValueError("local benchmark endpoint attempted an HTTP redirect")
            if response.status != 200:
                raise ValueError("local benchmark endpoint returned an unsuccessful HTTP status")
            if response.getheader("Content-Encoding", "identity").lower() != "identity":
                raise ValueError("compressed benchmark responses are unsupported")
            lengths = response.headers.get_all("Content-Length", [])
            if len(lengths) > 1 or (lengths and (not lengths[0].isdigit() or int(lengths[0]) > MAX_RESPONSE_BYTES)):
                raise ValueError("response exceeds the benchmark size limit or has ambiguous framing")
            if lengths and response.getheader("Transfer-Encoding"):
                raise ValueError("response has ambiguous HTTP framing")
            yield response
            if deadline.expired:
                raise DeadlineExceeded()
            if response.length is not None and response.length != 0:
                raise ValueError("response ended before its declared HTTP body length")
        except BaseException as error:
            self.close()
            if deadline.expired and isinstance(error, Exception):
                raise DeadlineExceeded() from None
            raise
        finally:
            deadline.finish()
            if response is not None:
                if not response.isclosed():
                    # A size-limited read may leave bytes behind. Never reuse
                    # that connection for the next independent sample.
                    self.close()
                response.close()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("local benchmark endpoint attempted an HTTP redirect")


def validate_endpoint(endpoint):
    if not isinstance(endpoint, str) or any(ord(char) <= 32 or ord(char) == 127 for char in endpoint):
        raise ValueError("endpoint must not contain whitespace or control characters")
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("endpoint must be an HTTP(S) loopback address; private dictation is never sent remotely")
    if parsed.username is not None or parsed.password is not None or "?" in endpoint or "#" in endpoint:
        raise ValueError("endpoint must not contain credentials, query parameters or a fragment")
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError("endpoint port must be between 1 and 65535")
    if not parsed.path.endswith("/chat/completions"):
        raise ValueError("endpoint must be the full /v1/chat/completions URL")
    return endpoint


def file_signature(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def artifact_snapshot(path):
    path = Path(path)
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("model artifact must be a regular file")
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        if file_signature(os.fstat(handle.fileno())) != file_signature(before):
            raise ValueError("model artifact changed before hashing")
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
        if file_signature(os.fstat(handle.fileno())) != file_signature(before):
            raise ValueError("model artifact changed while hashing; use a frozen artifact")
    after = path.stat()
    if file_signature(before) != file_signature(after):
        raise ValueError("model artifact changed while hashing; use a frozen artifact")
    return hasher.hexdigest(), file_signature(after)


def artifact_hash(path):
    return artifact_snapshot(path)[0]


def read_config(path):
    if not stat.S_ISREG(Path(path).stat().st_mode):
        raise ValueError("request configuration must be a regular file")
    with open(path, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError("request configuration must be a regular file")
        contents = handle.read(MAX_CONFIG_BYTES + 1)
    if len(contents) > MAX_CONFIG_BYTES:
        raise ValueError("request configuration exceeds the size limit")
    # read_text uses universal newlines and changes exact CRLF prompts/prefixes.
    return contents.decode("utf-8")


def load_artifact(artifact=None, manifest=None):
    """Verify actual shard bytes, not just a manifest that claims their hashes."""
    if (artifact is None) == (manifest is None):
        raise ValueError("supply one model artifact or one artifact manifest")
    path = Path(artifact or manifest)
    artifact_digest, signature = artifact_snapshot(path)
    snapshots = [(path, signature, path.resolve())]
    if artifact is not None:
        return {"artifactSHA256": artifact_digest, "artifactFormat": "single-file"}, snapshots
    contents = read_config(path)
    if digest(contents) != artifact_digest:
        raise ValueError("artifact manifest changed while reading")
    value = strict_json_loads(contents)
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise ValueError("artifact manifest requires schemaVersion 1")
    entries = value.get("files")
    if not isinstance(entries, list) or not entries or len(entries) > 4096:
        raise ValueError("artifact manifest requires 1..4096 model/tokenizer/template files")
    seen = set()
    root = path.resolve().parent
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ValueError("artifact manifest entries require a relative file path and sha256")
        relative = Path(entry["path"])
        if not entry["path"] or relative.is_absolute() or ".." in relative.parts:
            raise ValueError("artifact manifest paths must stay inside its directory")
        member = (root / relative).resolve()
        if not member.is_relative_to(root) or member == path.resolve() or member in seen:
            raise ValueError("artifact manifest paths must be unique files inside its directory")
        seen.add(member)
        member_digest, member_signature = artifact_snapshot(member)
        if member_digest != entry.get("sha256"):
            raise ValueError("artifact manifest file hash mismatch")
        # Retain the declared binding too: checking only the resolved target
        # misses a symlink being redirected to another shard during the run.
        snapshots.append((root / relative, member_signature, member))
    return {"artifactSHA256": artifact_digest, "artifactFormat": "sha256-manifest-v1"}, snapshots


def verify_artifact_snapshot(snapshots):
    if any(path.resolve() != resolved or file_signature(path.stat()) != signature for path, signature, resolved in snapshots):
        raise ValueError("model artifact changed during replay; no result can identify a frozen model")


@contextmanager
def replay_output(path, inputs):
    """Reserve both output files and invalidate old evidence before sending requests."""
    import fcntl

    path = Path(path)
    sidecar = Path(str(path) + ".manifest.json")
    outputs = {path.resolve(), sidecar.resolve()}
    if outputs.intersection(Path(source).resolve() for source in inputs if source is not None):
        raise ValueError("prediction output or manifest would overwrite an input file")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = path.parent / ".flow-replay.lock"
    if lock_path.resolve() in outputs or lock_path.resolve() in {Path(source).resolve() for source in inputs if source is not None}:
        raise ValueError("replay lock path overlaps an input or output")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("another replay is writing this output directory") from error
        os.fchmod(fd, 0o600)
        write_private(path, "")
        write_private(sidecar, canonical({"schemaVersion": 3, "status": "running"}) + "\n")
        try:
            yield
        except BaseException:
            write_private(path, "")
            write_private(sidecar, canonical({"schemaVersion": 3, "status": "aborted"}) + "\n")
            raise
    finally:
        # Keep the lock inode in place so future writers lock the same object.
        os.close(fd)


def benchmark_protocol(warmup_requests=1, timeout=30, max_tokens=2048, repetitions=1):
    protocol = {"schemaVersion": 2, "warmupRequests": warmup_requests, "concurrency": 1, "order": "dataset-rounds",
            "timeoutSeconds": timeout, "maxTokens": max_tokens, "repetitions": repetitions}
    validate_protocol(protocol, digest(canonical(protocol)))
    return protocol


def request_case(case, endpoint, model, prompt, timeout, max_tokens, opener=None, user_prefix="", template_kwargs=None,
                 cache_prompt="server-default"):
    benchmark_protocol(timeout=timeout, max_tokens=max_tokens)
    validate_endpoint(endpoint)
    if not isinstance(model, str) or not model.strip() or not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("model and system prompt must be nonempty strings")
    if template_kwargs is not None and not isinstance(template_kwargs, dict):
        raise ValueError("chat template options must be a JSON object")
    if cache_prompt not in {"on", "off", "server-default"}:
        raise ValueError("cache-prompt must be on, off or server-default")
    started = time.perf_counter()
    deadline_at = time.monotonic() + timeout
    body = {"model": model, "messages": [{"role": "system", "content": prompt},
                                         {"role": "user", "content": user_prefix + case["input"]}],
            "temperature": 0, "max_tokens": max_tokens, "stream": False}
    if template_kwargs is not None:
        body["chat_template_kwargs"] = template_kwargs
    if cache_prompt != "server-default":
        body["cache_prompt"] = cache_prompt == "on"
    output, error, reason = "", None, "error"
    prompt_tokens = completion_tokens = None
    server_model = None
    owned_client = None
    try:
        payload = canonical(body).encode("utf-8")
        if len(payload) > MAX_REQUEST_BYTES:
            raise ValueError("request exceeds the benchmark size limit")
        request = urllib.request.Request(endpoint, data=payload, headers={"Content-Type": "application/json"}, method="POST")
        if opener is None:
            owned_client = opener = LocalChatClient(endpoint)
        remaining = deadline_at - time.monotonic()
        if remaining <= 0:
            raise DeadlineExceeded()
        with opener.open(request, timeout=remaining) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
        if len(payload) > MAX_RESPONSE_BYTES:
            raise ValueError("response exceeds the benchmark size limit")
        value = strict_json_loads(payload)
        if not isinstance(value, dict):
            raise ValueError("response must be a JSON object")
        if value.get("error") is not None:
            raise ValueError("response declares a server error")
        server_model = value.get("model")
        if server_model is not None and (not isinstance(server_model, str) or not server_model.strip() or len(server_model) > 1024):
            raise ValueError("response model identity must be a bounded nonempty string")
        usage = value.get("usage") or {}
        if isinstance(usage, dict):
            for key, destination in (("prompt_tokens", "prompt"), ("completion_tokens", "completion")):
                count = usage.get(key)
                if type(count) is int and 0 <= count <= 2**31 - 1:
                    if destination == "prompt":
                        prompt_tokens = count
                    else:
                        completion_tokens = count
        choices = value.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise ValueError("response must contain exactly one completion choice")
        choice = choices[0]
        if "index" in choice and (type(choice["index"]) is not int or choice["index"] != 0):
            raise ValueError("response choice index must be zero")
        message = choice.get("message")
        if not isinstance(message, dict) or message.get("role", "assistant") != "assistant":
            raise ValueError("response must contain an assistant message")
        if any(message.get(key) for key in ("tool_calls", "function_call", "refusal")):
            raise ValueError("response is not a completed text-only cleanup")
        output = message.get("content")
        reason = choice.get("finish_reason")
        if not isinstance(output, str):
            raise ValueError("response content is not text")
        if reason is not None and not isinstance(reason, str):
            raise ValueError("response finish reason must be text")
        reason = reason or "unknown"
        if reason != "stop":
            error = "incomplete-response"
        elif empty_output(case, output):
            error = "empty-output"
        elif completion_tokens is not None and completion_tokens > max_tokens:
            error = "output-token-limit-exceeded"
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, IndexError) as failure:
        # Exception messages can contain server output; the record only needs the class.
        error, output, reason = type(failure).__name__, "", "error"
    finally:
        if owned_client is not None:
            owned_client.close()
    latency = (time.perf_counter() - started) * 1000
    if latency > timeout * 1000 or error == "DeadlineExceeded":
        error, output, reason = "deadline-exceeded", "", "timeout"
    return {"id": case["id"], "caseHash": case["caseHash"], "output": output, "error": error,
            "finish_reason": reason, "latencyMs": latency, "promptTokens": prompt_tokens, "completionTokens": completion_tokens,
            "serverModel": server_model}


def replay_cases(cases, invoke, protocol, model_id, dataset_id, progress=None):
    """Run whole-workload rounds; preserve every attempt instead of selecting a fast/best result."""
    validate_protocol(protocol, digest(canonical(protocol)))
    attempts = {case["id"]: [] for case in cases}
    if not cases or len(attempts) != len(cases):
        raise ValueError("replay requires a nonempty workload with distinct case IDs")
    retained_outputs = {identifier: {} for identifier in attempts}
    total = len(cases) * protocol["repetitions"]
    completed = 0
    for repetition in range(protocol["repetitions"]):
        for case in cases:
            # Some adapters reuse a response dictionary. Retain each observed
            # sample independently instead of rewriting previous repetitions.
            row = dict(invoke(case))
            if row.get("id") != case["id"] or row.get("caseHash") != case["caseHash"]:
                raise ValueError("replay adapter returned a different case")
            if not isinstance(row.get("output"), str):
                raise ValueError("replay adapter must retain text output, including failed attempts")
            # Keep every attempt while sharing identical immutable text. A warm
            # deterministic workload need not retain N separate output buffers.
            row["output"] = retained_outputs[case["id"]].setdefault(row["output"], row["output"])
            row["sampleIndex"] = repetition
            attempts[case["id"]].append(row)
            completed += 1
            if progress:
                progress(completed, total, row)
    protocol_id = digest(canonical(protocol))
    predictions = []
    for case in cases:
        samples = attempts[case["id"]]
        first = samples[0]
        failed = any(sample.get("error") or sample.get("finish_reason") != "stop" or empty_output(case, sample["output"])
                     or sample["latencyMs"] > protocol["timeoutSeconds"] * 1000
                     for sample in samples)
        unstable = any(sample["output"] != first["output"] for sample in samples)
        predictions.append({"id": case["id"], "caseHash": case["caseHash"], "output": first["output"],
            "finish_reason": first["finish_reason"], "error": "attempt-failed" if failed else "unstable-output" if unstable else None,
            "latencyMs": statistics.median(sample["latencyMs"] for sample in samples),
            "attempts": samples, "modelID": model_id, "datasetID": dataset_id,
            "benchmarkProtocol": protocol, "benchmarkProtocolID": protocol_id,
            "warmupSucceeded": protocol["warmupRequests"] > 0})
    return predictions


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--split", choices=("valid", "test"), default="valid")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080/v1/chat/completions")
    parser.add_argument("--model", required=True, help="API model name served by the local server")
    artifacts = parser.add_mutually_exclusive_group(required=True)
    artifacts.add_argument("--artifact", help="exact single model file served")
    artifacts.add_argument("--artifact-manifest", help="schemaVersion 1 JSON manifest of relative file paths and sha256 hashes")
    parser.add_argument("--prompt", required=True, help="UTF-8 system prompt file")
    parser.add_argument("--user-prefix-file", help="exact UTF-8 prefix prepended to each user input, including any newline")
    parser.add_argument("--chat-template-kwargs", help="UTF-8 JSON object file for servers supporting chat_template_kwargs; support must be verified")
    parser.add_argument("--runtime-id", required=True, help="server version, quantization and relevant engine flags")
    parser.add_argument("--environment-id", help="hardware, OS and power regime; required and held constant for engine tuning")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--warmup-requests", type=int, default=1, help="0..5 authored warmup calls, stored separately from scored cases")
    parser.add_argument("--repetitions", type=int, default=1, help="1..50 complete workload rounds; engine tuning requires at least 6")
    parser.add_argument("--cache-prompt", choices=("on", "off", "server-default"), default="server-default",
                        help="explicit server cache_prompt request option; verify support for the chosen engine")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        validate_endpoint(args.endpoint)
        if not math.isfinite(args.timeout) or args.timeout <= 0 or args.max_tokens < 1 or not 0 <= args.warmup_requests <= 5 or not 1 <= args.repetitions <= 50:
            raise ValueError("positive finite timeout and positive max-tokens required")
        if not args.runtime_id.strip() or not args.model.strip():
            raise ValueError("model and runtime-id must be nonempty")
        if args.environment_id is not None and not args.environment_id.strip():
            raise ValueError("environment-id must be nonempty when supplied")
        manifest, cases = load_dataset(args.dataset_dir, args.split)
        if not cases:
            raise ValueError("no reviewed held-out cases to replay")
        prompt = read_config(args.prompt)
        if not prompt.strip():
            raise ValueError("system prompt must be nonempty")
        user_prefix = read_config(args.user_prefix_file) if args.user_prefix_file else ""
        template_kwargs = strict_json_loads(read_config(args.chat_template_kwargs)) if args.chat_template_kwargs else None
        if template_kwargs is not None and not isinstance(template_kwargs, dict):
            raise ValueError("chat-template-kwargs must contain a JSON object")
        artifact_identity, artifact_files = load_artifact(args.artifact, args.artifact_manifest)
        scripts = Path(__file__).resolve().parent
        harness_files = [Path(__file__), scripts / "export_flow_runs.py", scripts / "flow_hillclimb.py",
                         scripts.parent / "bench/text_metrics.py"]
        identity = {"model": args.model, **artifact_identity, "promptSHA256": digest(prompt),
                    "runnerSHA256": artifact_hash(__file__),
                    "harnessSHA256": digest(canonical({path.name: artifact_hash(path) for path in harness_files})),
                    "userPrefixSHA256": digest(user_prefix), "chatTemplateKwargs": template_kwargs,
                    "runtimeID": args.runtime_id, "environmentID": args.environment_id,
                    "temperature": 0, "maxTokens": args.max_tokens, "timeoutSeconds": args.timeout,
                    "cachePrompt": args.cache_prompt, "httpTransport": "persistent-loopback-deadline-v1"}
        model_id = digest(canonical(identity))
        protocol = benchmark_protocol(args.warmup_requests, args.timeout, args.max_tokens, args.repetitions)
        protocol_id = digest(canonical(protocol))
        inputs = [path for path, _, _ in artifact_files] + harness_files + [args.prompt, args.user_prefix_file, args.chat_template_kwargs]
        dataset_files = {"manifest.json", "train.jsonl", "valid.jsonl", "test.jsonl", "split-lock.json", ".export.lock"}
        dataset_files.update(manifest.get("files", {}))
        inputs += [Path(args.dataset_dir) / name for name in dataset_files]
        with replay_output(args.out, inputs):
            started_at = datetime.now(timezone.utc).isoformat()
            # Reuse the real socket; urllib openers normally send Connection: close.
            opener = LocalChatClient(args.endpoint)
            warmups = []
            try:
                for index in range(args.warmup_requests):
                    sample = {"id": f"authored-warmup-{index}", "input": "the violet kettle sits on the second shelf", "caseHash": "authored-warmup"}
                    row = request_case(sample, args.endpoint, args.model, prompt, args.timeout, args.max_tokens,
                                       opener, user_prefix, template_kwargs, args.cache_prompt)
                    warmups.append({key: row[key] for key in ("error", "finish_reason", "latencyMs", "serverModel")})
                    if row["error"]:
                        raise ValueError("authored warmup failed; no benchmark cases were scored and previous prediction output was cleared")

                def invoke(case):
                    return request_case(case, args.endpoint, args.model, prompt, args.timeout, args.max_tokens,
                                        opener, user_prefix, template_kwargs, args.cache_prompt)

                def progress(index, total, row):
                    print(f"{index}/{total}: {'failed' if row['error'] else 'completed'} ({row['latencyMs']:.0f} ms)", flush=True)

                predictions = replay_cases(cases, invoke, protocol, model_id, manifest["datasetID"], progress)
            finally:
                opener.close()
            completed_at = datetime.now(timezone.utc).isoformat()
            verify_artifact_snapshot(artifact_files)
            output_info = write_private_jsonl(args.out, predictions)
            write_private(str(args.out) + ".manifest.json", canonical({
                "schemaVersion": 3, "status": "complete", "createdAt": completed_at, "startedAt": started_at, "completedAt": completed_at, "identity": identity,
                "benchmarkProtocol": protocol, "benchmarkProtocolID": protocol_id, "warmups": warmups,
                "coverage": "Standalone HTTP cleanup with explicit request template. Native Flow guards, dynamic S1 token budget, pipeline and paste are not replayed.",
                "modelID": model_id, "datasetID": manifest["datasetID"], "split": args.split, "cases": len(cases),
                "failures": sum(bool(row["error"]) for row in predictions),
                "attempts": len(cases) * args.repetitions,
                "predictionsSHA256": output_info["sha256"]}) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Replay refused: {error}\n")
    return 1 if any(row["error"] for row in predictions) else 0


if __name__ == "__main__":
    raise SystemExit(main())
