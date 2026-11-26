#!/usr/bin/env python3
"""Replay frozen reviewed cases through an already-running local cleanup server.

Uses an OpenAI-compatible /v1/chat/completions endpoint on loopback only. Sends
the raw input and supplied system prompt, never the human target. Writes private
predictions for flow_hillclimb.py; no downloads, model swaps, or retries occur.
The supplied artifact must be the one loaded by the server. HTTP cannot prove
that relationship; record the server build/hardware in --runtime-id.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request

from export_flow_runs import canonical, digest, write_private
from flow_hillclimb import load_dataset


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
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def request_case(case, endpoint, model, prompt, timeout, max_tokens, opener=None):
    body = {"model": model, "messages": [{"role": "system", "content": prompt},
                                         {"role": "user", "content": case["input"]}],
            "temperature": 0, "max_tokens": max_tokens, "stream": False}
    request = urllib.request.Request(validate_endpoint(endpoint), data=canonical(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    # Do not honor proxy environment variables for a private loopback replay.
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    started = time.perf_counter()
    output, error, reason = "", None, "error"
    try:
        with opener.open(request, timeout=timeout) as response:
            payload = response.read(2 * 1024 * 1024 + 1)
        if len(payload) > 2 * 1024 * 1024:
            raise ValueError("response exceeds the benchmark size limit")
        value = json.loads(payload)
        choice = value["choices"][0]
        output = choice["message"]["content"]
        reason = choice.get("finish_reason") or "unknown"
        if not isinstance(output, str):
            raise ValueError("response content is not text")
        if reason != "stop":
            error = "incomplete-response"
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, IndexError) as failure:
        # Exception messages can contain server output; the record only needs the class.
        error, output, reason = type(failure).__name__, "", "error"
    return {"id": case["id"], "caseHash": case["caseHash"], "output": output, "error": error,
            "finish_reason": reason, "latencyMs": (time.perf_counter() - started) * 1000}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--split", choices=("valid", "test"), default="valid")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080/v1/chat/completions")
    parser.add_argument("--model", required=True, help="API model name served by the local server")
    parser.add_argument("--artifact", required=True, help="exact model file served, or a manifest hashing all model shards")
    parser.add_argument("--prompt", required=True, help="UTF-8 system prompt file")
    parser.add_argument("--runtime-id", required=True, help="server version, quantization, hardware and relevant engine flags")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--max-tokens", type=int, default=2048)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        validate_endpoint(args.endpoint)
        if not math.isfinite(args.timeout) or args.timeout <= 0 or args.max_tokens < 1:
            raise ValueError("positive finite timeout and positive max-tokens required")
        if not args.runtime_id.strip() or not args.model.strip():
            raise ValueError("model and runtime-id must be nonempty")
        manifest, cases = load_dataset(args.dataset_dir, args.split)
        if not cases:
            raise ValueError("no reviewed held-out cases to replay")
        prompt = Path(args.prompt).read_text(encoding="utf-8")
        if not prompt.strip():
            raise ValueError("system prompt must be nonempty")
        identity = {"model": args.model, "artifactSHA256": artifact_hash(args.artifact), "promptSHA256": digest(prompt),
                    "runtimeID": args.runtime_id, "temperature": 0, "maxTokens": args.max_tokens, "timeoutSeconds": args.timeout}
        model_id = digest(canonical(identity))
        predictions = []
        for index, case in enumerate(cases, 1):
            row = request_case(case, args.endpoint, args.model, prompt, args.timeout, args.max_tokens)
            row.update(modelID=model_id, datasetID=manifest["datasetID"])
            predictions.append(row)
            print(f"{index}/{len(cases)}: {'failed' if row['error'] else 'completed'} ({row['latencyMs']:.0f} ms)", flush=True)
        write_private(args.out, "".join(canonical(row) + "\n" for row in predictions))
        write_private(str(args.out) + ".manifest.json", canonical({
            "schemaVersion": 1, "createdAt": datetime.now(timezone.utc).isoformat(), "identity": identity,
            "modelID": model_id, "datasetID": manifest["datasetID"], "split": args.split, "cases": len(cases),
            "failures": sum(bool(row["error"]) for row in predictions),
            "predictionsSHA256": digest("".join(canonical(row) + "\n" for row in predictions))}) + "\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Replay refused: {error}\n")
    return 1 if any(row["error"] for row in predictions) else 0


if __name__ == "__main__":
    raise SystemExit(main())
