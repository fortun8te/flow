#!/usr/bin/env python3
"""Score a cloud polish eval run.

Inputs:
  CASES      Tests/PolishEval/polish-eval-cases.json (keep/drop tokens, expected output)
  RESULTS    JSON written by `Flow --polish-eval CASES OUT`
  --meaning  optional JSON {case_id: {"meaning": 0|1|2, "note": "..."}} from a human/model read:
             2 = meaning, facts, names and numbers intact; 1 = small drift; 0 = changed or lost meaning

Mechanical checks per case:
  cloud      output came from the cloud route (engine starts with "cloud:"), or the
             deterministic non-English path for dutch-english cases
  keep       every must-keep token is present
  drop       no must-drop token is present
  dash       no em dash, en dash or horizontal bar in the output (hard rule)
  emoji      no pictograph the speaker did not say
  preamble   no "Here is", "Sure", code fence or wrapping quotes
  casing     first letter capitalised (not checked for casual or Dutch)
  ending     ends with . ? ! or a closing quote/bracket (not checked for casual or Dutch)
  length     output word count within a sane band of the raw input
  nonempty   output is not empty or None

A case passes when every mechanical check passes and, if a meaning judgment exists, meaning == 2.
"""
import argparse
import json
import re
import sys
from pathlib import Path

DASHES = ("—", "–", "―")
PREAMBLE = re.compile(r"^(here('|’)s|here is|sure[,!. ]|certainly[,!. ]|okay, here|cleaned up:)", re.I)
PICTO = re.compile("[\U0001F300-\U0001FAFF☀-➿\U0001F1E6-\U0001F1FF]")
CASUAL_LIKE = {"casual", "dutch-english"}


def words(s):
    return re.findall(r"[A-Za-z0-9À-ɏ']+", s or "")


def has_token(text, token):
    """Plain words match whole-word. Case-sensitive if the token has a capital (names, acronyms), else case-insensitive."""
    if not token:
        return True
    flags = 0 if re.search(r"[A-Z]", token) else re.I
    if re.fullmatch(r"[A-Za-z][A-Za-z ']*", token):
        return re.search(r"(?<![A-Za-z])" + re.escape(token) + r"(?![A-Za-z])", text, flags) is not None
    if flags:
        return token.lower() in text.lower()
    return token in text


def drop_hit(text, token):
    """Plain words are whole-word, case-insensitive. Symbols (dashes, emoji) match as plain substrings."""
    if re.fullmatch(r"[A-Za-z][A-Za-z' ]*", token):
        return re.search(r"(?<![A-Za-z])" + re.escape(token) + r"(?![A-Za-z])", text, re.I) is not None
    return token in text


def trigrams(s):
    t = re.sub(r"\s+", " ", (s or "").lower()).strip()
    return {t[i:i + 3] for i in range(max(0, len(t) - 2))}


def similarity(a, b):
    ta, tb = trigrams(a), trigrams(b)
    if not ta and not tb:
        return 1.0
    return len(ta & tb) / max(1, len(ta | tb))


def check_case(case, res, meaning):
    out = res.get("output")
    raw = case["raw"]
    cat = case.get("category", "")
    engine = res.get("engine") or ""
    checks = {}
    if not out or not out.strip():
        checks["nonempty"] = False
        return checks, {"similarity": 0.0}
    checks["nonempty"] = True

    if cat == "dutch-english":
        checks["cloud"] = True  # non-English path is deterministic by design
    else:
        checks["cloud"] = engine.startswith("cloud:")

    keep = case.get("keep") or []
    checks["keep"] = all(has_token(out, k) for k in keep)
    drop = case.get("drop") or []
    checks["drop"] = not any(drop_hit(out, d) for d in drop)
    checks["dash"] = not any(d in out for d in DASHES)
    raw_pict = set(PICTO.findall(raw))
    checks["emoji"] = all(p in raw_pict for p in PICTO.findall(out))
    checks["preamble"] = not (PREAMBLE.match(out.strip()) or out.strip().startswith(("```", '"')))

    if cat in CASUAL_LIKE:
        checks["casing"] = True
        checks["ending"] = True
    else:
        first = next((c for c in out if c.isalpha()), "")
        checks["casing"] = (not first) or first.isupper()
        checks["ending"] = out.rstrip()[-1:] in ".?!\"')]" or "\n" in out.rstrip()  # a sign-off name line ends a letter

    rw, ow = len(words(raw)), len(words(out))
    lo = 0.2 if cat in ("restarts", "high-cleanup", "lists") else 0.4  # restarts and lists legitimately delete words
    hi = 1.3
    ratio = ow / max(1, rw)
    checks["length"] = lo <= ratio <= hi or rw < 4

    if meaning is not None:
        checks["meaning"] = meaning.get("meaning") == 2
    return checks, {"similarity": round(similarity(out, case.get("expect", "")), 2), "ratio": round(ratio, 2)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases")
    ap.add_argument("results")
    ap.add_argument("--meaning", help="JSON with per-case meaning judgments")
    ap.add_argument("--json-out", help="write the summary as JSON here")
    ap.add_argument("--show", action="store_true", help="print raw and output for every case")
    args = ap.parse_args()

    cases = {c["id"]: c for c in json.loads(Path(args.cases).read_text())}
    results = json.loads(Path(args.results).read_text())
    judgments = json.loads(Path(args.meaning).read_text()) if args.meaning else {}

    rows, total_pass, check_total, check_pass = [], 0, 0, 0
    latencies = []
    by_cat = {}
    for res in results:
        cid = res["id"]
        case = cases.get(cid)
        if case is None:
            continue
        m = judgments.get(cid)
        checks, extra = check_case(case, res, m)
        ok = all(checks.values())
        total_pass += ok
        check_total += len(checks)
        check_pass += sum(1 for v in checks.values() if v)
        if res.get("latencyMs") and res.get("engine", "") and str(res.get("engine")).startswith("cloud:"):
            latencies.append(res["latencyMs"])
        bc = by_cat.setdefault(case.get("category", ""), [0, 0])
        bc[0] += ok
        bc[1] += 1
        failed = [k for k, v in checks.items() if not v]
        rows.append({
            "id": cid,
            "category": case.get("category", ""),
            "pass": ok,
            "failed": failed,
            "engine": res.get("engine") or "-",
            "latency_ms": res.get("latencyMs"),
            "meaning": (m or {}).get("meaning"),
            "note": (m or {}).get("note", ""),
            **extra,
        })
        if args.show:
            print(f"--- {cid} [{case.get('category')}] engine={res.get('engine') or '-'} {res.get('latencyMs')}ms")
            print(f"RAW: {res.get('raw')}")
            print(f"OUT: {res.get('output')!r}")
            print(f"    failed={failed} meaning={(m or {}).get('meaning')}")

    n = len(rows)
    lat = sorted(latencies)
    p50 = lat[len(lat) // 2] if lat else None
    p90 = lat[int(len(lat) * 0.9) - 1] if lat else None
    print(f"cases={n} pass={total_pass}/{n} ({100 * total_pass / max(1, n):.0f}%) "
          f"checks={check_pass}/{check_total} ({100 * check_pass / max(1, check_total):.0f}%) "
          f"cloud_latency_p50={p50}ms p90={p90}ms")
    print("| category | pass |")
    print("|---|---|")
    for cat, (p, t) in sorted(by_cat.items()):
        print(f"| {cat} | {p}/{t} |")
    fails = [r for r in rows if not r["pass"]]
    if fails:
        print("\nFailing cases:")
        for r in fails:
            print(f"- {r['id']}: {', '.join(r['failed']) or 'meaning'} {('- ' + r['note']) if r['note'] else ''}")
    summary = {"cases": n, "pass": total_pass, "checks_pass": check_pass, "checks_total": check_total,
               "cloud_latency_p50_ms": p50, "cloud_latency_p90_ms": p90, "rows": rows}
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
