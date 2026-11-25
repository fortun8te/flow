#!/usr/bin/env python3
"""Run an S1-mini MLX model (stock, or with a LoRA adapter) over the 58 polish eval cases, then score them.

    uv run --with mlx-lm==0.31.3 python training/eval_cases.py --label stock --model ~/Library/Caches/models/mlx-community/S1-mini-MLX-4bit
    uv run --with mlx-lm==0.31.3 python training/eval_cases.py --label tuned --model <merged MLX dir>

Prompt = Flow's exact S1 system prompt + Flow's default control line + the raw case text, greedy,
enable_thinking=False (same as the test-split evaluator). Scoring reuses the checks in
scripts/score-polish-eval.py (keep/drop tokens, dash, emoji, preamble, casing, ending, length).
The `cloud` check is removed: this is a local model, not the cloud route. Meaning is not judged here
(no meaning file); the report says so.
"""
import argparse
import importlib.util
import json
import re
import statistics
import time
from pathlib import Path

from mlx_lm import generate, load

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / 'Tests/PolishEval/polish-eval-cases.json'
SCORER = ROOT / 'scripts/score-polish-eval.py'
OUT = Path.home() / 'Library/Application Support/VOICE/S1Tuning-v1/results'  # private: outputs can echo dictation
CONTROL = '[Styling: semi-formal] [Structure: prose] [Context: general]'
SYSTEM = ('You are a text normalizer for speech-to-text transcripts. The input begins with a control line '
          'specifying the styling, structure, and context settings; clean the transcript to match those '
          'settings and output only the cleaned text.')


def load_scorer():
    spec = importlib.util.spec_from_file_location('score_polish_eval', SCORER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--label', required=True)
    ap.add_argument('--model', required=True, type=Path)
    ap.add_argument('--adapter', type=Path)
    args = ap.parse_args()

    cases = json.loads(CASES.read_text(encoding='utf-8'))
    model, tok = load(str(args.model.expanduser()), adapter_path=str(args.adapter) if args.adapter else None)
    results, lat = [], []
    for case in cases:
        messages = [{'role': 'system', 'content': SYSTEM},
                    {'role': 'user', 'content': CONTROL + '\n' + case['raw']}]
        prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        budget = min(1024, max(64, int(len(tok.encode(case['raw'])) * 1.3) + 32))
        t0 = time.perf_counter()
        text = generate(model, tok, prompt=prompt, max_tokens=budget, verbose=False)
        ms = (time.perf_counter() - t0) * 1000
        text = re.sub(r'<think>.*?</think>', '', text, flags=re.S).strip()
        lat.append(ms)
        results.append({'id': case['id'], 'output': text, 'engine': 'local:' + args.label, 'latencyMs': round(ms, 1)})

    scorer = load_scorer()
    by_id = {c['id']: c for c in cases}
    rows, passed, checks_total, checks_pass = [], 0, 0, 0
    for res in results:
        checks, extra = scorer.check_case(by_id[res['id']], res, None)
        checks.pop('cloud', None)  # local model, not the cloud route
        ok = all(checks.values())
        passed += ok
        checks_total += len(checks)
        checks_pass += sum(checks.values())
        rows.append({'id': res['id'], 'category': by_id[res['id']]['category'], 'pass': ok,
                     'failed': [k for k, v in checks.items() if not v], 'output': res['output'],
                     'latency_ms': res['latencyMs'], **extra})
    summary = {'label': args.label, 'model': str(args.model), 'adapter': str(args.adapter or ''),
               'cases': len(cases), 'cases_pass': passed, 'checks_pass': f'{checks_pass}/{checks_total}',
               'latency_ms_p50': round(statistics.median(lat), 1),
               'latency_ms_p95': round(sorted(lat)[max(0, int(len(lat) * .95) - 1)], 1),
               'meaning': 'not judged (no meaning file)'}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f'cases-{args.label}.json').write_text(json.dumps({'summary': summary, 'rows': rows},
                                                             ensure_ascii=False, indent=1), encoding='utf-8')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
