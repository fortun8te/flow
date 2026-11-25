#!/usr/bin/env python3
"""E1: is the runtime adapter route fast enough? (MASTER-PLAN-v3 section 6.8, brief E1).

Two llama-server processes, both built the way Flow starts its model (`-c 8192 -np 1 -ngl 99`, greedy, the
request sends cache_prompt false, repeat_penalty 1.05):
  plain : DOSE1 T1 Q8 (the shipped file), no adapter.
  lora  : the same file with a rank-16 LoRA loaded unmerged (--lora ... --lora-init-without-apply).
Per request the lora server gets the scale in the request's `lora` field (0 = off, 1 = on).

The LoRA is a RANDOM STAND-IN (training/t2/make_standin_lora.py, converted to GGUF): no trained adapter exists on disk.
Its speed cost depends on shape, not values. Its B matrix is small, so outputs stay close to the plain model.

Inputs are real dictation text from the held-out Parakeet set, kept under VOICE (never in the repo). Only timings,
hashes and counts are written out.

  python3 bench/e1_adapter_speed.py check                 # correctness gate: scale 0 == plain, scale 1 changes output
  python3 bench/e1_adapter_speed.py time --lengths 20 60 150 --runs 10
  python3 bench/e1_adapter_speed.py summary --run <run_json>
"""
import argparse
import hashlib
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

LLAMA = "llama-server"
MODEL = Path.home() / "Library/Application Support/VOICE/Models/DOSE1/model-Q8_0.gguf"
TEMPLATE = Path.home() / "Library/Application Support/VOICE/Models/DOSE1/chat_template.jinja"
LORA = Path(os.environ.get("E1_LORA", str(Path.home() / "flow-train/e1/standin-r16-f16.gguf")))
SOURCE = Path.home() / "Library/Application Support/VOICE/WhisperNowTuning-parakeet/test.jsonl"
E1_DIR = Path.home() / "Library/Application Support/VOICE/bench/e1"
E1_DIR.mkdir(parents=True, exist_ok=True)
os.chmod(E1_DIR, 0o700)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_server(name, log_path, lora):
    port = free_port()
    log = open(log_path, "w")
    args = [LLAMA, "-m", str(MODEL), "--jinja", "--chat-template-file", str(TEMPLATE), "--host", "127.0.0.1",
            "--port", str(port), "-c", "8192", "-np", "1", "-ngl", "99", "--no-webui"]
    if lora:
        args += ["--lora", str(LORA), "--lora-init-without-apply"]
    proc = subprocess.Popen(args, stdout=log, stderr=log)
    t0 = time.time()
    while time.time() - t0 < 240:
        try:
            if urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2).status == 200:
                return {"name": name, "port": port, "proc": proc, "load_s": round(time.time() - t0, 2)}
        except Exception:
            pass
        if proc.poll() is not None:
            break
        time.sleep(1)
    raise RuntimeError(f"{name}: server not ready, see {log_path}")


def stop_server(srv):
    srv["proc"].terminate()
    try:
        srv["proc"].wait(timeout=20)
    except subprocess.TimeoutExpired:
        srv["proc"].kill()


def max_tokens_for(text):
    return max(64, math.ceil(2.5 * len(text.split())))


def chat(srv, text, scale=None, cache_prompt=False):
    """One streamed request. Returns TTFT (first content delta), total time, the server's timings and the output."""
    body = {"messages": [{"role": "user", "content": text}], "temperature": 0, "repeat_penalty": 1.05,
            "repeat_last_n": 4096, "max_tokens": max_tokens_for(text), "cache_prompt": cache_prompt, "stream": True}
    if scale is not None:
        body["lora"] = [{"id": 0, "scale": float(scale)}]
    req = urllib.request.Request(f"http://127.0.0.1:{srv['port']}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    load_before = os.getloadavg()[0]
    t0 = time.perf_counter()
    ttft, pieces, timings, finish = None, [], None, None
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            obj = json.loads(payload)
            if obj.get("timings"):
                timings = obj["timings"]
            for ch in obj.get("choices") or []:
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
                content = (ch.get("delta") or {}).get("content")
                if content:
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    pieces.append(content)
    total = time.perf_counter() - t0
    out = "".join(pieces)
    return {"ttft_s": ttft, "total_s": total, "timings": timings, "finish": finish, "output": out,
            "out_sha1": hashlib.sha1(out.encode("utf-8")).hexdigest()[:12], "load_before": round(load_before, 2),
            "load_after": round(os.getloadavg()[0], 2)}


def build_inputs():
    raws = [json.loads(line)["messages"][0]["content"] for line in SOURCE.read_text(encoding="utf-8").splitlines()]
    inputs = {}
    for n in (20, 60, 150):
        items = []
        for i in range(10):
            words, j = [], (i * 37) % len(raws)
            while len(words) < n:
                words += raws[j].split()
                j = (j + 1) % len(raws)
            items.append(" ".join(words[:n]))
        inputs[str(n)] = items
    return inputs


def cmd_check(args):
    inputs = build_inputs()
    plain = start_server("plain", E1_DIR / "server-plain.log", lora=False)
    lora = start_server("lora", E1_DIR / "server-lora.log", lora=True)
    result = {"plain_load_s": plain["load_s"], "lora_load_s": lora["load_s"]}
    try:
        adapters = urllib.request.urlopen(f"http://127.0.0.1:{lora['port']}/lora-adapters", timeout=10).read().decode()
        result["lora_adapters_listing"] = adapters[:400]
        same, differ, errors = 0, 0, 0
        for n in ("20", "60"):
            for text in inputs[n]:
                a = chat(plain, text)
                b0 = chat(lora, text, scale=0)
                b1 = chat(lora, text, scale=1)
                if a["out_sha1"] == b0["out_sha1"]:
                    same += 1
                else:
                    errors += 1
                differ += a["out_sha1"] != b1["out_sha1"]
        result.update({"prompts": 20, "scale0_identical_to_plain": same, "scale0_mismatch": errors,
                       "scale1_differs_from_plain": differ})
    finally:
        stop_server(plain)
        stop_server(lora)
    out = E1_DIR / f"check-{LORA.stem}.json"
    out.write_text(json.dumps(result, indent=1))
    print(json.dumps(result, indent=1))
    return 0


def cmd_time(args):
    inputs = build_inputs()
    plain = start_server("plain", E1_DIR / "server-plain.log", lora=False)
    lora = start_server("lora", E1_DIR / "server-lora.log", lora=True)
    run_id = time.strftime("%Y%m%d-%H%M%S")
    records = []
    lora_state = None  # the scale the lora server was last asked for, kept across runs and lengths
    try:
        for n in args.lengths:
            items = inputs[str(n)]
            # warm both servers on this length, both lora states
            for text in items[:2]:
                chat(plain, text)
                chat(lora, text, scale=0)
                chat(lora, text, scale=1)
            lora_state = 1
            for run in range(args.runs):
                text = items[run]
                # lora block is always off, on, on-again; whether the plain request goes before or after it alternates
                lora_block = [("B_off", 0), ("B_on", 1), ("B_on_steady", 1)]
                plain_first = (run % 2 == 0)
                seq = []
                if plain_first:
                    seq.append(("A", plain, None))
                    seq += [(lab, lora, sc) for lab, sc in lora_block]
                else:
                    seq += [(lab, lora, sc) for lab, sc in lora_block]
                    seq.append(("A", plain, None))
                for label, srv, sc in seq:
                    r = chat(srv, text, scale=sc)
                    if srv is lora:
                        switched = lora_state != sc
                        lora_state = sc
                    else:
                        switched = None
                    t = r["timings"] or {}
                    records.append({
                        "length": n, "run": run, "label": label, "server": srv["name"], "scale": sc,
                        "switched": switched, "ttft_s": r["ttft_s"], "total_s": r["total_s"],
                        "predicted_n": t.get("predicted_n"), "predicted_per_second": t.get("predicted_per_second"),
                        "prompt_n": t.get("prompt_n"), "prompt_ms": t.get("prompt_ms"),
                        "prompt_per_second": t.get("prompt_per_second"), "cache_n": t.get("cache_n"),
                        "finish": r["finish"], "out_sha1": r["out_sha1"], "out_chars": len(r["output"]),
                        "load_before": r["load_before"], "load_after": r["load_after"],
                    })
                    print(f"len {n} run {run} {label:12} ttft {r['ttft_s']:.3f} total {r['total_s']:.3f} "
                          f"tok/s {t.get('predicted_per_second') or 0:.1f} load {r['load_before']}", flush=True)
    finally:
        stop_server(plain)
        stop_server(lora)
    out = E1_DIR / f"time-{run_id}.json"
    out.write_text(json.dumps({"run": run_id, "lengths": args.lengths, "runs": args.runs,
                               "plain_load_s": plain["load_s"], "lora_load_s": lora["load_s"],
                               "adapter": str(LORA), "records": records}, indent=1))
    os.chmod(out, 0o600)
    print(f"wrote {out}")
    return 0


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def cmd_summary(args):
    recs, lengths = [], []
    for f in args.run:
        data = json.loads(Path(f).read_text())
        recs += data["records"]
        lengths += [n for n in data["lengths"] if n not in lengths]
    rows = []
    for n in lengths:
        for label in ("A", "B_off", "B_on", "B_on_steady"):
            sub = [r for r in recs if r["length"] == n and r["label"] == label]
            if not sub:
                continue
            rows.append({
                "length": n, "label": label, "n": len(sub),
                "ttft_med": med([r["ttft_s"] for r in sub]), "total_med": med([r["total_s"] for r in sub]),
                "total_min": min(r["total_s"] for r in sub), "total_max": max(r["total_s"] for r in sub),
                "tok_s_med": med([r["predicted_per_second"] for r in sub]),
                "out_tokens_med": med([r["predicted_n"] for r in sub]),
                "prompt_tok_s_med": med([r["prompt_per_second"] for r in sub]),
                "cache_n_max": max((r["cache_n"] or 0) for r in sub),
                "load_med": med([r["load_before"] for r in sub]),
            })
        # switching cost: lora requests split by whether the scale changed since the previous lora request
        for scale in (0, 1):
            for sw_flag, name in ((True, "switched"), (False, "same as previous")):
                sub = [r for r in recs if r["length"] == n and r["server"] == "lora" and r["scale"] == scale
                       and r["switched"] is sw_flag]
                rows.append({"length": n, "label": f"lora scale {scale}, {name}", "n": len(sub),
                             "ttft_med": med([r["ttft_s"] for r in sub]), "total_med": med([r["total_s"] for r in sub]),
                             "cache_n_max": max((r["cache_n"] or 0) for r in sub) if sub else None})
    print(json.dumps(rows, indent=1))
    return 0


def cmd_cache(args):
    """Does switching the adapter drop the prompt cache? cache_prompt true, same prompt, scale changed in between."""
    inputs = build_inputs()
    lora = start_server("lora", E1_DIR / "server-lora-cache.log", lora=True)
    steps = [("on", 1), ("on again", 1), ("off (switch)", 0), ("off again", 0), ("on (switch back)", 1)]
    rows = []
    try:
        for text in inputs["60"][:args.prompts]:
            chat(lora, "warm " + text, scale=1)  # not measured: warm the server on a different prompt
            for name, sc in steps:
                r = chat(lora, text, scale=sc, cache_prompt=True)
                t = r["timings"] or {}
                rows.append({"step": name, "scale": sc, "prompt_n": t.get("prompt_n"), "cache_n": t.get("cache_n"),
                             "ttft_s": round(r["ttft_s"], 4), "total_s": round(r["total_s"], 4)})
    finally:
        stop_server(lora)
    out = E1_DIR / "cache-test.json"
    out.write_text(json.dumps(rows, indent=1))
    for name, _ in steps:
        sub = [r for r in rows if r["step"] == name]
        print(f"{name:20} prompt_n med {med([r['prompt_n'] for r in sub])}  cache_n med {med([r['cache_n'] for r in sub])}  "
              f"ttft med {med([r['ttft_s'] for r in sub])}  total med {med([r['total_s'] for r in sub])}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    t = sub.add_parser("time")
    t.add_argument("--lengths", type=int, nargs="+", default=[20, 60, 150])
    t.add_argument("--runs", type=int, default=10)
    c = sub.add_parser("cache")
    c.add_argument("--prompts", type=int, default=5)
    s = sub.add_parser("summary")
    s.add_argument("--run", required=True, nargs="+", help="one or more time-*.json files, merged")
    args = p.parse_args(argv)
    return {"check": cmd_check, "time": cmd_time, "summary": cmd_summary, "cache": cmd_cache}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
