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
Metrics are defined in bench/METRICS.md. Scorer version: SCORER_VERSION below.
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
import socket
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve().parent
SCORER_VERSION = "flow_bench-1.0 (score-polish-eval check_case + wn_metrics.score_row, cloud check removed)"
PRIVATE_RUNS = Path.home() / "Library/Application Support/VOICE/bench/runs"
PRIVATE_SUITES = {"heldout-typed"}
LLAMA_SERVER = "llama-server"
SUITES = {"smoke28": BENCH / "cases/smoke28.json", "polish88": BENCH / "cases/polish88.json",
          "typo20": BENCH / "cases/typo20.json",
          "heldout-typed": Path.home() / "Library/Application Support/VOICE/bench/private/heldout-typed.json"}
HASH_CACHE = BENCH / ".hash_cache.json"


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
    path = Path(path)
    st = path.stat()
    cache = json.loads(HASH_CACHE.read_text()) if HASH_CACHE.exists() else {}
    key = f"{path}|{st.st_size}|{int(st.st_mtime)}"
    if key in cache:
        return cache[key]
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    cache[key] = h.hexdigest()
    HASH_CACHE.write_text(json.dumps(cache, indent=1))
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
        rec["weights_sha256_first_file"] = sha256_file(files[0])
        rec["weights_files"] = len(files)
        rec["system_prompt_sha256"] = hashlib.sha256(cfg["system"].encode()).hexdigest()
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
        t = time.time()
        out.append({"id": c["id"], "output": rules_approx(c["raw"]), "seconds": round(time.time() - t, 6),
                    "error": None, "finish_reason": "stop"})
    return out


def run_mlx(rec, cfg, cases, workdir):
    system = cfg["system"]
    cases_path = workdir / "mlx_cases.json"
    cases_path.write_text(json.dumps(cases, ensure_ascii=False))
    out_path = workdir / "mlx_out.json"
    cmd = [rec["_python"], str(BENCH / "workers/mlx_worker.py"), rec["model_dir"], str(cases_path), str(out_path),
           system, cfg["control_line"]]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    if proc.returncode != 0 or not out_path.exists():
        raise RuntimeError(f"mlx worker failed: {proc.stderr[-800:]}")
    data = json.loads(out_path.read_text())
    rec["load_s"] = data["load_s"]
    return data["results"]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_llama(rec, cfg, cases, workdir):
    port = free_port()
    log = open(workdir / "llama-server.log", "w")
    srv = subprocess.Popen([LLAMA_SERVER, "-m", rec["_gguf"], "--jinja", "--chat-template-file", rec["_template"],
                            "--host", "127.0.0.1", "--port", str(port), "-c", "8192", "-np", "1", "-ngl", "99",
                            "--no-webui"], stdout=log, stderr=log)
    results = []
    try:
        t0 = time.time()
        ready = False
        while time.time() - t0 < 240:
            try:
                if urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2).status == 200:
                    ready = True
                    break
            except Exception:
                pass
            if srv.poll() is not None:
                break
            time.sleep(1)
        if not ready:
            raise RuntimeError(f"{rec['engine']}: llama-server did not become ready (see {workdir}/llama-server.log)")
        rec["load_s"] = round(time.time() - t0, 2)
        for c in cases:
            body = {"messages": [{"role": "user", "content": c["raw"]}], "temperature": 0, "repeat_penalty": 1.05,
                    "repeat_last_n": 4096, "max_tokens": max_tokens_llama(c["raw"]), "cache_prompt": False,
                    "stream": False}
            req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                         data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
            t = time.time()
            text, err, finish = None, None, "stop"
            try:
                r = json.loads(urllib.request.urlopen(req, timeout=180).read())
                text = r["choices"][0]["message"]["content"]
                finish = r["choices"][0].get("finish_reason", "stop")
            except Exception as e:
                err = repr(e)
            results.append({"id": c["id"], "output": text, "seconds": round(time.time() - t, 3), "error": err,
                            "finish_reason": finish})
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=20)
        except subprocess.TimeoutExpired:
            srv.kill()
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
    finish = out_row.get("finish_reason", "stop")
    row = {"id": case["id"], "category": case.get("category", ""), "level": case.get("level"), "kind": case.get("kind"),
           "seconds": out_row.get("seconds"), "error": out_row.get("error")}
    if output is None or not str(output).strip():
        row.update({"empty": True, "fully_right": False, "facts_lost": len(case.get("must_contain", [])) > 0,
                    "facts_missing": list(case.get("must_contain", [])), "invented": False, "invented_list": [],
                    "clean_input": words_eq(raw, expect), "unchanged": False, "zero_edit": False,
                    "fillers_in": len(WN.filler_positions(WN.words(raw))), "fillers_out": None,
                    "fillers_removed": 0, "self_corr_cue": bool(CUE_RE.search(raw)), "self_corr_resolved": False,
                    "unexplained_cut": None, "budget": None, "budget_trip": False, "mech_failed": ["nonempty"],
                    "added_words_per_100": None, "negation_lost": None, "number_invented": None, "checks_failed": ["nonempty"]})
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
    failed = [k for k, v in checks.items() if not v]
    fully = (not failed and not missing and not forb and not invented and m["unexplained_cut"] == 0
             and m["negation_lost"] == 0 and m["number_invented"] == 0 and not trip)
    row.update({
        "empty": False, "fully_right": fully, "checks_failed": failed,
        "facts_missing": missing, "facts_lost": bool(missing) or m["negation_lost"] > 0 or m["number_invented"] > 0,
        "forbidden_hit": forb, "invented": bool(invented) or m["number_invented"] > 0, "invented_list": invented[:8],
        "clean_input": words_eq(raw, expect), "unchanged": words_eq(raw, output),
        "zero_edit": " ".join(output.split()) == " ".join(expect.split()),
        "fillers_in": f_in, "fillers_out": f_out, "fillers_removed": max(0, f_in - f_out),
        "self_corr_cue": cue, "self_corr_resolved": cue and not CUE_RE.search(output) and not missing and not forb,
        "unexplained_cut": m["unexplained_cut"], "budget": budget, "budget_trip": trip,
        "added_words_per_100": round(100 * len(invented) / n_words, 2), "negation_lost": m["negation_lost"],
        "number_invented": m["number_invented"], "mech_failed": failed,
    })
    return row


# ---------- aggregation and tables ----------

def pct(a, b):
    return "-" if not b else f"{100 * a / b:.0f}%"


def summarise(rows):
    lat = sorted(r["seconds"] for r in rows if r.get("seconds") is not None and not r.get("error") and not r.get("empty"))
    def p95(xs):
        return xs[min(len(xs) - 1, math.ceil(0.95 * len(xs)) - 1)] if xs else None
    clean = [r for r in rows if r["clean_input"]]
    dictated_fillers_in = sum(r["fillers_in"] or 0 for r in rows)
    dictated_fillers_removed = sum(r["fillers_removed"] or 0 for r in rows)
    total_added = sum(len(r["invented_list"]) for r in rows)
    total_words = sum(max(1, (r.get("out_words") or 1)) for r in rows)
    return {
        "n": len(rows),
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
    }


def render_table(rows, title):
    cats = sorted({r["category"] for r in rows})
    head = ("| category | n | fully right | facts lost | invented words | restraint (clean unchanged) | zero-edit | "
            "added words /100 | fillers removed | self-corr resolved | budget trips | latency median | latency p95 |")
    sep = "|" + "---|" * 13
    lines = [f"### {title}", "", head, sep]
    def line(name, s):
        return (f"| {name} | {s['n']} | {s['fully_right']}/{s['n']} | {s['facts_lost']} | {s['invented']} | "
                f"{s['restraint_ok']}/{s['restraint_n']} | {pct(s['zero_edit'], s['n'])} | {s['added_per_100']} | "
                f"{s['fillers_removed']}/{s['fillers_in']} | {s['self_corr_ok']}/{s['self_corr_n']} | "
                f"{s['budget_trips']} | {s['lat_median']} | {s['lat_p95']} |")
    for c in cats:
        lines.append(line(c or "(none)", summarise([r for r in rows if r["category"] == c])))
    lines.append(line("**ALL**", summarise(rows)))
    return "\n".join(lines) + "\n"


# ---------- commands ----------

def load_cases(suite):
    path = SUITES[suite]
    if not path.exists():
        raise FileNotFoundError(f"suite {suite} missing: {path} (run bench/cases/build_cases.py)")
    return json.loads(path.read_text())


def run_dir_for(suite, run_id):
    base = PRIVATE_RUNS if suite in PRIVATE_SUITES else BENCH / "runs"
    d = base / run_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def score_outputs(suite, cases, outs, rec_engine):
    by_id = {o["id"]: o for o in outs}
    rows = []
    for c in cases:
        o = by_id.get(c["id"])
        if o is None:
            raise RuntimeError(f"{rec_engine}: no output for {c['id']}")
        r = evaluate(c, o)
        r["out_words"] = len(WN.words(o.get("output") or ""))
        r["output"] = o.get("output")  # kept in cases.jsonl; never printed for private suites
        rows.append(r)
    return rows


def run_engine(name, suite, cases, run_id, engines):
    cfg = engines[name]
    rec = engine_identity(name, cfg)
    d = run_dir_for(suite, run_id) / name
    d.mkdir(parents=True, exist_ok=True)
    load = os.getloadavg()[0]
    t0 = time.time()
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
    wall = round(time.time() - t0, 1)
    errors = [o["id"] for o in outs if o.get("error")]
    if len(errors) > max(0, len(cases) // 10):
        raise RuntimeError(f"{name}: {len(errors)} call errors; run stopped, not scored: {errors[:5]}")
    rows = score_outputs(suite, cases, outs, name)
    rec_public = {k: v for k, v in rec.items() if not k.startswith("_")}
    rec_public.update({"suite": suite, "cases": len(cases), "wall_s": wall, "load_avg_start": round(load, 2),
                       "load_avg_end": round(os.getloadavg()[0], 2), "under_load": load > 8.0,
                       "timings_note": "accuracy valid; timings taken under load" if load > 8.0 else "timings with low load"})
    (d / "run.json").write_text(json.dumps(rec_public, indent=1, ensure_ascii=False))
    private = suite in PRIVATE_SUITES
    with open(d / "cases.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    table = render_table(rows, f"{name} on {suite} ({cfg['label']})")
    (d / "table.md").write_text(table)
    return rec_public, rows, table, private


def make_run_id(tag=""):
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S") + (f"-{tag}" if tag else "")


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
        print(table)
    base = run_dir_for(args.suite, run_id)
    (base / "table.md").write_text("\n".join(tables))
    print(f"wrote {base}")
    return 0


def cmd_compare(args):
    return cmd_run(args)


def cmd_rescore(args):
    run_dir = Path(args.run_dir)
    cases = {c["id"]: c for c in load_cases(args.suite)}
    tables = []
    for eng_dir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        rec = json.loads((eng_dir / "run.json").read_text())
        outs = [json.loads(line) for line in (eng_dir / "cases.jsonl").read_text().splitlines()]
        rows = []
        for o in outs:
            c = cases[o["id"]]
            r = evaluate(c, {"id": o["id"], "output": o.get("output"), "seconds": o.get("seconds"),
                             "error": o.get("error"), "finish_reason": o.get("finish_reason", "stop")})
            r["out_words"] = len(WN.words(o.get("output") or ""))
            r["output"] = o.get("output")
            rows.append(r)
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
