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
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
from pathlib import Path
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request

from export_flow_runs import canonical, digest, write_private
from flow_hillclimb import empty_output, load_dataset


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("local benchmark endpoint attempted an HTTP redirect")


def validate_endpoint(endpoint):
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("endpoint must be an HTTP(S) loopback address; private dictation is never sent remotely")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("endpoint must not contain credentials, query parameters or a fragment")
    if not parsed.path.endswith("/chat/completions"):
        raise ValueError("endpoint must be the full /v1/chat/completions URL")
    return endpoint


def artifact_hash(path):
    path = Path(path)
    before = path.stat()
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
    after = path.stat()
    signature = lambda stat: (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
    if signature(before) != signature(after):
        raise ValueError("model artifact changed while hashing; use a frozen artifact")
    return hasher.hexdigest()


def benchmark_protocol(warmup_requests=1, timeout=30, max_tokens=2048, repetitions=1):
    return {"schemaVersion": 2, "warmupRequests": warmup_requests, "concurrency": 1, "order": "dataset-rounds",
            "timeoutSeconds": timeout, "maxTokens": max_tokens, "repetitions": repetitions}


def request_case(case, endpoint, model, prompt, timeout, max_tokens, opener=None, user_prefix="", template_kwargs=None,
                 cache_prompt="server-default"):
    body = {"model": model, "messages": [{"role": "system", "content": prompt},
                                         {"role": "user", "content": user_prefix + case["input"]}],
            "temperature": 0, "max_tokens": max_tokens, "stream": False}
    if template_kwargs is not None:
        body["chat_template_kwargs"] = template_kwargs
    if cache_prompt != "server-default":
        if cache_prompt not in {"on", "off"}:
            raise ValueError("cache-prompt must be on, off or server-default")
        body["cache_prompt"] = cache_prompt == "on"
    request = urllib.request.Request(validate_endpoint(endpoint), data=canonical(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    # Do not honor proxy environment variables for a private loopback replay.
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    started = time.perf_counter()
    output, error, reason = "", None, "error"
    prompt_tokens = completion_tokens = None
    try:
        with opener.open(request, timeout=timeout) as response:
            payload = response.read(2 * 1024 * 1024 + 1)
        if len(payload) > 2 * 1024 * 1024:
            raise ValueError("response exceeds the benchmark size limit")
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise ValueError("response must be a JSON object")
        usage = value.get("usage") or {}
        if isinstance(usage, dict):
            for key, destination in (("prompt_tokens", "prompt"), ("completion_tokens", "completion")):
                count = usage.get(key)
                if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
                    if destination == "prompt":
                        prompt_tokens = count
                    else:
                        completion_tokens = count
        choice = value["choices"][0]
        output = choice["message"]["content"]
        reason = choice.get("finish_reason") or "unknown"
        if not isinstance(output, str):
            raise ValueError("response content is not text")
        if reason != "stop":
            error = "incomplete-response"
        elif empty_output(case, output):
            error = "empty-output"
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, IndexError) as failure:
        # Exception messages can contain server output; the record only needs the class.
        error, output, reason = type(failure).__name__, "", "error"
    latency = (time.perf_counter() - started) * 1000
    if latency > timeout * 1000:
        error, reason = "deadline-exceeded", "timeout"
    return {"id": case["id"], "caseHash": case["caseHash"], "output": output, "error": error,
            "finish_reason": reason, "latencyMs": latency, "promptTokens": prompt_tokens, "completionTokens": completion_tokens}


def replay_cases(cases, invoke, protocol, model_id, dataset_id, progress=None):
    """Run whole-workload rounds; preserve every attempt instead of selecting a fast/best result."""
    attempts = {case["id"]: [] for case in cases}
    total = len(cases) * protocol["repetitions"]
    completed = 0
    for repetition in range(protocol["repetitions"]):
        for case in cases:
            row = invoke(case)
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
    parser.add_argument("--artifact", required=True, help="exact model file served, or a manifest hashing all model shards")
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
        prompt = Path(args.prompt).read_text(encoding="utf-8")
        if not prompt.strip():
            raise ValueError("system prompt must be nonempty")
        user_prefix = Path(args.user_prefix_file).read_bytes().decode("utf-8") if args.user_prefix_file else ""
        template_kwargs = json.loads(Path(args.chat_template_kwargs).read_text()) if args.chat_template_kwargs else None
        if template_kwargs is not None and not isinstance(template_kwargs, dict):
            raise ValueError("chat-template-kwargs must contain a JSON object")
        identity = {"model": args.model, "artifactSHA256": artifact_hash(args.artifact), "promptSHA256": digest(prompt),
                    "runnerSHA256": artifact_hash(__file__),
                    "userPrefixSHA256": digest(user_prefix), "chatTemplateKwargs": template_kwargs,
                    "runtimeID": args.runtime_id, "environmentID": args.environment_id,
                    "temperature": 0, "maxTokens": args.max_tokens, "timeoutSeconds": args.timeout,
                    "cachePrompt": args.cache_prompt}
        model_id = digest(canonical(identity))
        protocol = benchmark_protocol(args.warmup_requests, args.timeout, args.max_tokens, args.repetitions)
        protocol_id = digest(canonical(protocol))
        started_at = datetime.now(timezone.utc).isoformat()
        # One opener keeps setup out of each request's measured work and prevents proxy/redirect forwarding.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        warmups = []
        for index in range(args.warmup_requests):
            sample = {"id": f"authored-warmup-{index}", "input": "the violet kettle sits on the second shelf", "caseHash": "authored-warmup"}
            row = request_case(sample, args.endpoint, args.model, prompt, args.timeout, args.max_tokens,
                               opener, user_prefix, template_kwargs, args.cache_prompt)
            warmups.append({key: row[key] for key in ("error", "finish_reason", "latencyMs")})
            if row["error"]:
                write_private(args.out, "")
                write_private(str(args.out) + ".manifest.json", canonical({"schemaVersion": 2, "status": "warmup-failed",
                    "modelID": model_id, "datasetID": manifest["datasetID"], "benchmarkProtocol": protocol,
                    "warmups": warmups, "cases": 0, "predictionsSHA256": digest("")}) + "\n")
                raise ValueError("authored warmup failed; no benchmark cases were scored and previous prediction output was cleared")
        def invoke(case):
            return request_case(case, args.endpoint, args.model, prompt, args.timeout, args.max_tokens,
                                opener, user_prefix, template_kwargs, args.cache_prompt)

        def progress(index, total, row):
            print(f"{index}/{total}: {'failed' if row['error'] else 'completed'} ({row['latencyMs']:.0f} ms)", flush=True)

        predictions = replay_cases(cases, invoke, protocol, model_id, manifest["datasetID"], progress)
        completed_at = datetime.now(timezone.utc).isoformat()
        write_private(args.out, "".join(canonical(row) + "\n" for row in predictions))
        write_private(str(args.out) + ".manifest.json", canonical({
            "schemaVersion": 3, "createdAt": completed_at, "startedAt": started_at, "completedAt": completed_at, "identity": identity,
            "benchmarkProtocol": protocol, "benchmarkProtocolID": protocol_id, "warmups": warmups,
            "coverage": "Standalone HTTP cleanup with explicit request template. Native Flow guards, dynamic S1 token budget, pipeline and paste are not replayed.",
            "modelID": model_id, "datasetID": manifest["datasetID"], "split": args.split, "cases": len(cases),
            "failures": sum(bool(row["error"]) for row in predictions),
            "attempts": len(cases) * args.repetitions,
            "predictionsSHA256": digest("".join(canonical(row) + "\n" for row in predictions))}) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Replay refused: {error}\n")
    return 1 if any(row["error"] for row in predictions) else 0


if __name__ == "__main__":
    raise SystemExit(main())
