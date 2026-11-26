#!/usr/bin/env python3
"""One benchmark for every cleanup engine (plan task A2 / T11). Standard library only.

  python3 bench/flow_bench.py engines
  python3 bench/flow_bench.py run --suite smoke28 --engine s1mini
  python3 bench/flow_bench.py compare --suite polish88 --engine identity --engine rules --engine stock
  python3 bench/flow_bench.py rescore bench/runs/<run_id>

Suites: smoke28, polish88, typo20 (public, repo) and heldout-typed (private, VOICE only).
Engines come from bench/engines.json. Every engine is one entry: identity (do nothing), rules_approx,
mlx (S1-mini, run through bench/workers/mlx_worker.py in the mlx venv) or llama (any GGUF served by
llama-server). An engine that fails to load is an ERROR and the run stops; it is never scored as a pass.

Output per run, in bench/runs/<run_id>/ (or VOICE/bench/runs/ for private suites):
  run.json (the run record), cases.jsonl (one row per case), table.md (the per-category table).
See docs/TRAINING.md for the benchmark contract and limitations. Scorer version: SCORER_VERSION below.
"""
import argparse
import datetime as dt
import glob
import hashlib
import importlib.util
import json
import math
import os
import re
import selectors
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve().parent
SCORER_VERSION = "flow_bench-2.0 (strict failures, complete alignment, all-call timing)"
PRIVATE_RUNS = Path.home() / "Library/Application Support/VOICE/bench/runs"
PRIVATE_SUITES = {"heldout-typed"}
LLAMA_SERVER = "llama-server"
MLX_WORKER = BENCH / "workers/mlx_worker.py"
SUITES = {"smoke28": BENCH / "cases/smoke28.json", "polish88": BENCH / "cases/polish88.json",
          "typo20": BENCH / "cases/typo20.json",
          "heldout-typed": Path.home() / "Library/Application Support/VOICE/bench/private/heldout-typed.json"}
HASH_CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "flow-bench/hash-cache.json"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PE = load_module("score_polish_eval", ROOT / "scripts/score-polish-eval.py")
WN = load_module("wn_metrics", ROOT / "bench/wn_metrics.py")

CUE_RE = re.compile(r"\b(no wait|no sorry|sorry,? no|scratch that|actually no|no,? actually|no,? i mean|i mean)\b", re.I)
FUNCTION = set("a an the and or but so to of in on at for is are was were be been it its that this with as by from if then than i you he she we they me my our your their is am do does did not no yes".split())
CURRENCY_WORDS = {"euros", "euro", "dollars", "dollar", "bucks", "buck", "pounds", "pound"}
FILLERS = {"um", "umm", "uh", "uhh", "uhm", "erm", "eh", "ehm"}


# ---------- engine config and hashing ----------

def expand(p):
    return os.path.expanduser(p)


def sha256_file(path):
    path = Path(path).resolve()
    st = path.stat()
    try:
        cache = json.loads(HASH_CACHE.read_text()) if HASH_CACHE.exists() else {}
        if not isinstance(cache, dict):
            cache = {}
    except (OSError, ValueError):
        cache = {}
    signature = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    key = json.dumps([str(path), *signature])
    if isinstance(cache.get(key), str) and re.fullmatch(r"[a-f0-9]{64}", cache[key]):
        return cache[key]
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    after = path.stat()
    if signature != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise RuntimeError("model artifact changed while hashing; retry with a stable artifact")
    cache[key] = h.hexdigest()
    try:
        HASH_CACHE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix=".hash-", dir=HASH_CACHE.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(cache, handle)
            os.replace(temporary, HASH_CACHE)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except OSError:
        pass  # Cache persistence is optional; the computed hash remains authoritative.
    return cache[key]


def resolve_one(pattern):
    hits = sorted(glob.glob(expand(pattern)))
    if not hits:
        raise FileNotFoundError(f"engine file not found: {pattern}")
    return hits[-1]


def load_engines():
    return json.loads((BENCH / "engines.json").read_text())


def engine_identity(name, cfg):
    """Return a record of what exactly will run (paths, hashes, prompt), or raise if missing."""
    rec = {"engine": name, "kind": cfg["kind"], "label": cfg["label"], "max_tokens_rule": cfg.get("max_tokens_rule"),
           "control_line": cfg.get("control_line"), "decoding": "greedy (temperature 0)"}
    rec["configuration_sha256"] = hashlib.sha256(json.dumps(cfg, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    rec["harness_sha256"] = sha256_file(__file__)
    if cfg["kind"] == "llama":
        gguf = resolve_one(cfg["gguf_glob"])
        template = resolve_one(cfg["template_glob"])
        rec["gguf"] = gguf
        rec["gguf_sha256"] = sha256_file(gguf)
        rec["gguf_bytes"] = Path(gguf).stat().st_size
        rec["template_sha256"] = sha256_file(template)
        rec["repeat_penalty"] = 1.05
        if cfg.get("expected_sha256") and cfg["expected_sha256"] != rec["gguf_sha256"]:
            raise RuntimeError(f"{name}: GGUF hash {rec['gguf_sha256'][:12]} does not match the expected hash; refusing to score a swapped file")
        rec["_gguf"], rec["_template"] = gguf, template
    elif cfg["kind"] == "mlx":
        mdir = expand(cfg["model_dir"])
        if not Path(mdir).exists():
            raise FileNotFoundError(f"{name}: model dir missing: {mdir}")
        files = sorted(Path(mdir).glob("*.safetensors"))
        if not files:
            raise FileNotFoundError(f"{name}: no safetensors in {mdir}")
        rec["model_dir"] = mdir
        artifacts = sorted(set(files + list(Path(mdir).glob("*.json")) + list(Path(mdir).glob("*.model"))
                               + list(Path(mdir).glob("*.jinja")) + list(Path(mdir).glob("*.txt"))))
        rec["artifact_sha256"] = {p.name: sha256_file(p) for p in artifacts}
        rec["model_sha256"] = hashlib.sha256(json.dumps(rec["artifact_sha256"], sort_keys=True).encode()).hexdigest()
        rec["weights_files"] = len(files)
        rec["system_prompt_sha256"] = hashlib.sha256(cfg["system"].encode()).hexdigest()
        rec["worker_sha256"] = sha256_file(MLX_WORKER)
        py = expand(cfg["python"])
        if not Path(py).exists():
            raise FileNotFoundError(f"{name}: python missing: {py}")
        rec["_python"] = py
    return rec


def rules_approx(raw):
    t = raw.strip()
    t = re.sub(r"\b(um+|uh+|erm|uhm|eh)\b,?\s*", "", t, flags=re.I)
    t = re.sub(r"\b(\w+)( \1\b)+", r"\1", t, flags=re.I)
    t = re.sub(r"\bi\b", "I", t)
    if t:
        t = t[0].upper() + t[1:]
    if t and t[-1] not in ".?!":
        t += "."
    return t


def max_tokens_llama(raw):
    return max(64, math.ceil(2.5 * len(raw.split())))


# ---------- engine runs ----------

def run_identity(cases):
    return [{"id": c["id"], "output": c["raw"], "seconds": 0.0, "error": None, "finish_reason": "stop"} for c in cases]


def run_rules(cases):
    out = []
    for c in cases:
        t = time.perf_counter()
        out.append({"id": c["id"], "output": rules_approx(c["raw"]), "seconds": time.perf_counter() - t,
                    "error": None, "finish_reason": "stop"})
    return out


def run_mlx(rec, cfg, cases, workdir):
    system = cfg["system"]
    cases_path = workdir / "mlx_cases.json"
    cases_path.write_text(json.dumps(cases, ensure_ascii=False))
    out_path = workdir / "mlx_out.json"
    cmd = [rec["_python"], str(MLX_WORKER), rec["model_dir"], str(cases_path), str(out_path),
           system, cfg.get("control_line") or ""]
    results, load_s = run_mlx_worker(cmd, cases, workdir, load_timeout=cfg.get("load_timeout_seconds", 240),
                                     case_timeout=cfg.get("case_timeout_seconds", 180))
    rec["load_s"] = load_s
    return results


def stop_process(process, grace=2):
    """Reap the process we started, including the kill path after a stuck shutdown."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=grace)
    else:
        process.wait()


def run_mlx_worker(command, cases, workdir, load_timeout=240, case_timeout=180):
    for value in (load_timeout, case_timeout):
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise ValueError("worker timeouts must be finite and positive")
    started = time.perf_counter()
    deadline = started + load_timeout
    loaded, load_s, results, pending = False, None, [], b""
    failure = None
    request_started = None
    with open(workdir / "mlx-worker.log", "wb") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while len(results) < len(cases):
                    remaining = deadline - time.perf_counter()
                    if remaining <= 0:
                        failure = "worker-case-timeout" if loaded else "worker-load-timeout"
                        break
                    events = selector.select(min(remaining, 0.25))
                    if not events and process.poll() is not None:
                        failure = "worker-exited"
                        break
                    for key, _ in events:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            failure = "worker-exited"
                            break
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            if not line.startswith(b"FLOW_BENCH_EVENT "):
                                continue
                            event = json.loads(line[len(b"FLOW_BENCH_EVENT "):])
                            if event.get("event") == "loaded" and not loaded:
                                loaded = True
                                load_s = time.perf_counter() - started
                                request_started = time.perf_counter()
                                deadline = request_started + case_timeout
                            elif event.get("event") == "case" and loaded:
                                row = event.get("result")
                                if not isinstance(row, dict) or len(results) >= len(cases) or row.get("id") != cases[len(results)]["id"]:
                                    raise RuntimeError("MLX worker returned missing, duplicate or unordered case results")
                                results.append(row)
                                request_started = time.perf_counter()
                                deadline = request_started + case_timeout
                            else:
                                raise RuntimeError("MLX worker returned an invalid progress event")
                        if len(pending) > 2 * 1024 * 1024:
                            raise RuntimeError("MLX worker progress exceeded the bounded message size")
                    if failure:
                        break
        finally:
            stop_process(process)
            if process.stdout is not None:
                process.stdout.close()
    if len(results) < len(cases):
        for index, case in enumerate(cases[len(results):]):
            results.append({"id": case["id"], "output": None,
                            "seconds": time.perf_counter() - request_started if loaded and index == 0 else None,
                            "error": failure if index == 0 else "not-run-after-worker-failure", "finish_reason": "error"})
    return results, load_s if load_s is not None else time.perf_counter() - started


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("a local benchmark server must not redirect private inputs")


def llama_request(raw, cfg):
    messages = []
    if cfg.get("system") is not None:
        if not isinstance(cfg["system"], str):
            raise ValueError("configured system prompt must be text")
        messages.append({"role": "system", "content": cfg["system"]})
    control = cfg.get("control_line")
    if control is not None and not isinstance(control, str):
        raise ValueError("configured control line must be text")
    messages.append({"role": "user", "content": control + "\n" + raw if control else raw})
    body = {"messages": messages, "temperature": 0, "repeat_penalty": 1.05, "repeat_last_n": 4096,
            "max_tokens": max_tokens_llama(raw), "cache_prompt": False, "stream": False}
    if cfg.get("chat_template_kwargs") is not None:
        if not isinstance(cfg["chat_template_kwargs"], dict):
            raise ValueError("chat template options must be an object")
        body["chat_template_kwargs"] = cfg["chat_template_kwargs"]
    return body


def run_llama(rec, cfg, cases, workdir):
    port = free_port()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    log = open(workdir / "llama-server.log", "w")
    try:
        srv = subprocess.Popen([LLAMA_SERVER, "-m", rec["_gguf"], "--jinja", "--chat-template-file", rec["_template"],
                                "--host", "127.0.0.1", "--port", str(port), "-c", "8192", "-np", "1", "-ngl", "99",
                                "--no-webui"], stdout=log, stderr=log)
    except BaseException:
        log.close()
        raise
    results = []
    try:
        t0 = time.perf_counter()
        ready = False
        while time.perf_counter() - t0 < 240:
            try:
                with opener.open(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    if response.status == 200:
                        ready = True
                        break
            except Exception:
                pass
            if srv.poll() is not None:
                break
            time.sleep(1)
        if not ready:
            raise RuntimeError(f"{rec['engine']}: llama-server did not become ready (see {workdir}/llama-server.log)")
        rec["load_s"] = time.perf_counter() - t0
        for c in cases:
            body = llama_request(c["raw"], cfg)
            req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                         data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
            t = time.perf_counter()
            text, err, finish = None, None, "error"
            try:
                with opener.open(req, timeout=180) as response:
                    payload = response.read(2 * 1024 * 1024 + 1)
                if len(payload) > 2 * 1024 * 1024:
                    raise ValueError("model response too large")
                r = json.loads(payload)
                text = r["choices"][0]["message"]["content"]
                finish = r["choices"][0].get("finish_reason")
                if not isinstance(text, str) or finish != "stop":
                    err = "incomplete-or-invalid-response"
            except Exception as e:
                err = type(e).__name__
            elapsed = time.perf_counter() - t
            if elapsed > 180:
                err, finish = "deadline-exceeded", "timeout"
            results.append({"id": c["id"], "output": text, "seconds": elapsed, "error": err,
                            "finish_reason": finish})
    finally:
        try:
            stop_process(srv)
        finally:
            log.close()
    return results


# ---------- scoring ----------

def words_eq(a, b):
    return [w.lower().replace("’", "'") for w in WN.words(a)] == [w.lower().replace("’", "'") for w in WN.words(b)]


def alt_match(output, alt):
    alt = alt.strip()
    if re.fullmatch(r"[A-Za-z][A-Za-z ']*", alt) and alt[:1].isupper():
        return re.search(r"(?<![A-Za-z])" + re.escape(alt) + r"(?![A-Za-z])", output) is not None
    if re.fullmatch(r"[A-Za-z][A-Za-z' ]*", alt):
        return re.search(r"(?<![A-Za-z])" + re.escape(alt) + r"(?![A-Za-z])", output, re.I) is not None
    return alt in output


def item_present(output, item):
    return any(alt_match(output, a) for a in item.split("|"))


def forbidden_hit(output, token):
    return PE.drop_hit(output, token)


def content_words(text):
    """Words for the invented-word check. Digits are left to wn_metrics (which knows spoken numbers),
    and 4,500 counts as one number, not 4 and 500."""
    text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", text or "")
    return [w for w in WN.words(text) if w not in FUNCTION and w not in FILLERS and len(w) > 1 and not w.isdigit()]


def _bare(w):
    return w.replace("'", "")


def invented_words(out_words, raw, expect):
    """Content words in the output that neither the input nor the expected output supports.
    Allowed: apostrophe-free forms (it's = its), same-stem stretches (yeahhh = yeah), and the
    expansions in wn_metrics.EXPANSIONS (ok = okay)."""
    allowed = {_bare(w) for w in WN.words(raw) + WN.words(expect)}  # every word the input or expected output has
    for w in list(allowed):
        allowed |= {_bare(x) for x in WN.EXPANSIONS.get(w, set())}
    out = []
    for w in out_words:
        b = _bare(w)
        if b in allowed:
            continue
        if any(abs(len(a) - len(b)) <= 3 and WN.same_stem(b, a) for a in allowed):
            continue
        out.append(w)
    return out


def evaluate(case, out_row):
    raw, expect = case["raw"], case.get("expect") or ""
    output = out_row.get("output")
    finish = out_row.get("finish_reason")
    seconds = out_row.get("seconds")
    valid_time = isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and math.isfinite(seconds) and seconds >= 0
    runtime_checks = []
    if out_row.get("error"):
        runtime_checks.append("runtime")
    if finish != "stop":
        runtime_checks.append("completion")
    if not valid_time:
        runtime_checks.append("timing")
    if not isinstance(output, str):
        runtime_checks.append("output_type")
    row = {"id": case["id"], "category": case.get("category", ""), "level": case.get("level"), "kind": case.get("kind"),
           "seconds": seconds if valid_time else None, "error": out_row.get("error"), "finish_reason": finish,
           "call_failed": bool(runtime_checks), "timing_valid": valid_time}
    if not isinstance(output, str) or not output.strip():
        row.update({"empty": True, "fully_right": False, "facts_lost": len(case.get("must_contain", [])) > 0,
                    "facts_missing": list(case.get("must_contain", [])), "invented": False, "invented_list": [], "invented_count": 0,
                    "clean_input": words_eq(raw, expect), "unchanged": False, "zero_edit": False,
                    "fillers_in": len(WN.filler_positions(WN.words(raw))), "fillers_out": None,
                    "fillers_removed": 0, "self_corr_cue": bool(CUE_RE.search(raw)), "self_corr_resolved": False,
                    "unexplained_cut": None, "budget": None, "budget_trip": False, "mech_failed": ["nonempty"],
                    "added_words_per_100": None, "negation_lost": None, "number_invented": None,
                    "call_failed": True, "checks_failed": runtime_checks + ["nonempty"]})
        return row
    output = str(output)
    res = {"output": output, "engine": "bench"}
    checks, _ = PE.check_case({"raw": raw, "category": case.get("category", ""), "keep": [], "drop": [], "expect": expect},
                              res, None)
    checks.pop("cloud", None)
    must = case.get("must_contain", [])
    must_not = case.get("must_not_contain", [])
    output_nc = re.sub(r"(?<=\d),(?=\d{3}\b)", "", output)  # 4,500 and 4500 are one number
    missing = [m for m in must if not item_present(output, m) and not item_present(output_nc, m)]
    forb = [t for t in must_not if forbidden_hit(output, t)]
    output_w = re.sub(r"(?<=\d),(?=\d{3}\b)", "", output)  # 4,500 is read as 4500 for the content checks
    m = WN.score_row(raw, output_w, expect, "length" if finish == "length" else None)
    cw_out = content_words(output_w)
    invented = invented_words(cw_out, raw, expect)
    # Unit to symbol is an allowed conversion: "euros" -> "€", "bucks" -> "$".
    if re.search(r"[€$£]", output_w):
        m["unexplained_cut"] = max(0, m["unexplained_cut"] - sum(1 for w in WN.words(raw) if w in CURRENCY_WORDS))
    n_words = max(1, len(WN.words(output)))
    f_in = len(WN.filler_positions(WN.words(raw)))
    f_out = len(WN.filler_positions(WN.words(output)))
    cue = bool(CUE_RE.search(raw))
    n_raw = len(WN.words(raw))
    budget = max(5, n_raw // 3) if cue else max(3, n_raw // 5)
    trip = m["unexplained_cut"] > budget
    failed = runtime_checks + [k for k, v in checks.items() if not v]
    fully = (not failed and not missing and not forb and not invented and m["unexplained_cut"] == 0
             and m["negation_lost"] == 0 and m["number_invented"] == 0 and not trip)
    row.update({
        "empty": False, "fully_right": fully, "checks_failed": failed,
        "facts_missing": missing, "facts_lost": bool(missing) or m["negation_lost"] > 0 or m["number_invented"] > 0,
        "forbidden_hit": forb, "invented": bool(invented) or m["number_invented"] > 0, "invented_list": invented[:8],
        "invented_count": len(invented),
        "clean_input": words_eq(raw, expect), "unchanged": not runtime_checks and words_eq(raw, output),
        "zero_edit": not runtime_checks and " ".join(output.split()) == " ".join(expect.split()),
        "fillers_in": f_in, "fillers_out": f_out, "fillers_removed": max(0, f_in - f_out),
        "self_corr_cue": cue, "self_corr_resolved": not runtime_checks and cue and not CUE_RE.search(output) and not missing and not forb,
        "unexplained_cut": m["unexplained_cut"], "budget": budget, "budget_trip": trip,
        "added_words_per_100": round(100 * len(invented) / n_words, 2), "negation_lost": m["negation_lost"],
        "number_invented": m["number_invented"], "mech_failed": failed,
    })
    return row


# ---------- aggregation and tables ----------

def pct(a, b):
    return "-" if not b else f"{100 * a / b:.0f}%"


def summarise(rows):
    valid_latency = lambda value: isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0
    lat = sorted(r["seconds"] for r in rows if valid_latency(r.get("seconds")))
    success_lat = sorted(r["seconds"] for r in rows if valid_latency(r.get("seconds")) and not r.get("call_failed")
                         and not r.get("error") and not r.get("empty"))
    def p95(xs):
        return xs[min(len(xs) - 1, math.ceil(0.95 * len(xs)) - 1)] if xs else None
    clean = [r for r in rows if r["clean_input"]]
    dictated_fillers_in = sum(r["fillers_in"] or 0 for r in rows)
    dictated_fillers_removed = sum(r["fillers_removed"] or 0 for r in rows)
    total_added = sum(r.get("invented_count", len(r["invented_list"])) for r in rows)
    total_words = sum(max(1, (r.get("out_words") or 1)) for r in rows)
    return {
        "n": len(rows),
        "failed_calls": sum(bool(r.get("call_failed") or r.get("error") or r.get("empty")) for r in rows),
        "latency_n": len(lat),
        "fully_right": sum(1 for r in rows if r["fully_right"]),
        "facts_lost": sum(1 for r in rows if r["facts_lost"]),
        "invented": sum(1 for r in rows if r["invented"]),
        "restraint_ok": sum(1 for r in clean if r["unchanged"]),
        "restraint_n": len(clean),
        "zero_edit": sum(1 for r in rows if r["zero_edit"]),
        "added_per_100": round(100 * total_added / max(1, total_words), 2),
        "fillers_in": dictated_fillers_in,
        "fillers_removed": dictated_fillers_removed,
        "self_corr_n": sum(1 for r in rows if r["self_corr_cue"]),
        "self_corr_ok": sum(1 for r in rows if r["self_corr_resolved"]),
        "budget_trips": sum(1 for r in rows if r["budget_trip"]),
        "lat_median": round(statistics.median(lat), 3) if lat else None,
        "lat_p95": round(p95(lat), 3) if lat else None,
        "successful_lat_median": round(statistics.median(success_lat), 3) if success_lat else None,
        "successful_lat_p95": round(p95(success_lat), 3) if success_lat else None,
    }


def render_table(rows, title):
    cats = sorted({r["category"] for r in rows})
    head = ("| category | n | failed calls | fully right | facts lost | invented words | restraint (clean unchanged) | zero-edit | "
            "added words /100 | fillers removed | self-corr resolved | budget trips | all-call median (s) | all-call p95 (s) | timed calls |")
    sep = "|" + "---|" * 15
    lines = [f"### {title}", "", head, sep]
    def line(name, s):
        return (f"| {name} | {s['n']} | {s['failed_calls']} | {s['fully_right']}/{s['n']} | {s['facts_lost']} | {s['invented']} | "
                f"{s['restraint_ok']}/{s['restraint_n']} | {pct(s['zero_edit'], s['n'])} | {s['added_per_100']} | "
                f"{s['fillers_removed']}/{s['fillers_in']} | {s['self_corr_ok']}/{s['self_corr_n']} | "
                f"{s['budget_trips']} | {s['lat_median']} | {s['lat_p95']} | {s['latency_n']}/{s['n']} |")
    for c in cats:
        lines.append(line(c or "(none)", summarise([r for r in rows if r["category"] == c])))
    lines.append(line("**ALL**", summarise(rows)))
    return "\n".join(lines) + "\n"


# ---------- commands ----------

def load_cases(suite):
    path = SUITES[suite]
    if not path.exists():
        raise FileNotFoundError(f"suite {suite} missing: {path} (run bench/cases/build_cases.py)")
    cases = json.loads(path.read_text())
    validate_cases(cases)
    return cases


def validate_cases(cases):
    if not isinstance(cases, list) or not cases:
        raise ValueError("benchmark suite must be a nonempty list")
    ids = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or not case["id"] or case["id"] in ids:
            raise ValueError("benchmark case ids must be unique nonempty strings")
        ids.add(case["id"])
        if not isinstance(case.get("raw"), str) or not isinstance(case.get("expect"), str):
            raise ValueError("benchmark cases need raw and expected text")
        for key in ("must_contain", "must_not_contain"):
            if not isinstance(case.get(key, []), list) or any(not isinstance(item, str) for item in case.get(key, [])):
                raise ValueError("benchmark constraints must be lists of strings")


def suite_fingerprint(cases):
    return hashlib.sha256(json.dumps(cases, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def run_dir_for(suite, run_id):
    base = PRIVATE_RUNS if suite in PRIVATE_SUITES else BENCH / "runs"
    d = base / run_id
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    if suite in PRIVATE_SUITES:
        os.chmod(d, 0o700)
    return d


def score_outputs(suite, cases, outs, rec_engine):
    validate_cases(cases)
    expected = {case["id"] for case in cases}
    by_id = {}
    for output in outs:
        if not isinstance(output, dict) or not isinstance(output.get("id"), str) or output["id"] not in expected:
            raise RuntimeError(f"{rec_engine}: unknown or malformed output id")
        if output["id"] in by_id:
            raise RuntimeError(f"{rec_engine}: duplicate output id")
        by_id[output["id"]] = output
    rows = []
    for c in cases:
        o = by_id.get(c["id"])
        if o is None:
            raise RuntimeError(f"{rec_engine}: no output for {c['id']}")
        r = evaluate(c, o)
        r["out_words"] = len(WN.words(o["output"])) if isinstance(o.get("output"), str) else 0
        r["output"] = o.get("output")  # kept in cases.jsonl; never printed for private suites
        rows.append(r)
    return rows


def run_engine(name, suite, cases, run_id, engines):
    cfg = engines[name]
    rec = engine_identity(name, cfg)
    d = run_dir_for(suite, run_id) / name
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    if suite in PRIVATE_SUITES:
        os.chmod(d, 0o700)
    load = os.getloadavg()[0]
    t0 = time.perf_counter()
    if cfg["kind"] == "identity":
        outs = run_identity(cases)
    elif cfg["kind"] == "rules_approx":
        outs = run_rules(cases)
    elif cfg["kind"] == "mlx":
        outs = run_mlx(rec, cfg, cases, d)
    elif cfg["kind"] == "llama":
        outs = run_llama(rec, cfg, cases, d)
    else:
        raise ValueError(f"unknown engine kind {cfg['kind']}")
    wall = time.perf_counter() - t0
    rows = score_outputs(suite, cases, outs, name)
    rec_public = {k: v for k, v in rec.items() if not k.startswith("_")}
    rec_public.update({"suite": suite, "cases": len(cases), "suite_sha256": suite_fingerprint(cases),
                       "scorer_version": SCORER_VERSION, "failed_calls": sum(row["call_failed"] for row in rows),
                       "wall_s": wall, "load_avg_start": round(load, 2),
                       "load_avg_end": round(os.getloadavg()[0], 2), "under_load": load > 8.0,
                       "timings_note": "Sequential all-call HTTP/generation time, including failures; model load separate. "
                                       "First generation is not calibrated as warm. Background load is recorded."})
    (d / "run.json").write_text(json.dumps(rec_public, indent=1, ensure_ascii=False))
    private = suite in PRIVATE_SUITES
    with open(d / "cases.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    table = render_table(rows, f"{name} on {suite} ({cfg['label']})")
    (d / "table.md").write_text(table)
    return rec_public, rows, table, private


def make_run_id(tag=""):
    if tag and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", tag) is None:
        raise ValueError("run tag may contain only letters, digits, underscore or hyphen")
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + (f"-{tag}" if tag else "")


def cmd_engines(args):
    eng = load_engines()
    for name, cfg in eng.items():
        try:
            rec = engine_identity(name, cfg)
            print(f"{name:10} OK  {cfg['label']}" + (f"  gguf_sha256={rec['gguf_sha256'][:16]}" if "gguf_sha256" in rec else ""))
        except Exception as e:
            print(f"{name:10} ERROR {e}")
            return 1
    return 0


def cmd_run(args):
    engines = load_engines()
    run_id = make_run_id(args.tag)
    cases = load_cases(args.suite)
    if args.suite in PRIVATE_SUITES:
        print(f"suite {args.suite} is private: per-case rows go to {PRIVATE_RUNS}, only the table is printed")
    print(f"run {run_id}: suite={args.suite} cases={len(cases)} engines={args.engine} load={os.getloadavg()[0]:.1f}")
    tables = []
    failed_calls = 0
    for name in args.engine:
        if name not in engines:
            print(f"ERROR unknown engine {name}")
            return 2
        try:
            rec, rows, table, private = run_engine(name, args.suite, cases, run_id, engines)
        except Exception as e:
            print(f"ERROR {name}: {e}")
            return 1
        tables.append(table)
        failed_calls += rec.get("failed_calls", 0)
        print(table)
    base = run_dir_for(args.suite, run_id)
    (base / "table.md").write_text("\n".join(tables))
    print(f"wrote {base}")
    return 1 if failed_calls else 0


def cmd_compare(args):
    return cmd_run(args)


def cmd_rescore(args):
    run_dir = Path(args.run_dir)
    suite_cases = load_cases(args.suite)
    tables = []
    for eng_dir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        rec = json.loads((eng_dir / "run.json").read_text())
        if rec.get("suite") != args.suite or rec.get("suite_sha256") != suite_fingerprint(suite_cases):
            raise ValueError("saved run does not match the exact current suite; rerun instead of rescoring stale cases")
        outs = [json.loads(line) for line in (eng_dir / "cases.jsonl").read_text().splitlines()]
        rows = score_outputs(args.suite, suite_cases, outs, rec["engine"])
        rec.update(scorer_version=SCORER_VERSION, failed_calls=sum(row["call_failed"] for row in rows))
        (eng_dir / "run.json").write_text(json.dumps(rec, indent=1, ensure_ascii=False))
        with open(eng_dir / "cases.jsonl", "w") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        t = render_table(rows, f"{eng_dir.name} on {args.suite} (rescored, {SCORER_VERSION})")
        (eng_dir / "table.md").write_text(t)
        tables.append(t)
    print("\n".join(tables))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("engines")
    for name in ("run", "compare"):
        p = sub.add_parser(name)
        p.add_argument("--suite", required=True, choices=sorted(SUITES))
        p.add_argument("--engine", action="append", required=True)
        p.add_argument("--tag", default="")
    p = sub.add_parser("rescore")
    p.add_argument("run_dir")
    p.add_argument("--suite", required=True, choices=sorted(SUITES))
    args = ap.parse_args(argv)
    return {"engines": cmd_engines, "run": cmd_run, "compare": cmd_compare, "rescore": cmd_rescore}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
