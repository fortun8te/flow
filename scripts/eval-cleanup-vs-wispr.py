#!/usr/bin/env python3
"""Decide ship / no-ship for a tuned S1-mini by scoring Flow's output against Wispr on the held-out test.

The deciding run uses Flow's own production cleanup path (Flow --cleanup-run), once with the
stock model and once with the tuned one. Everything is local.

    # deciding comparison (stock first, candidate second), plus a 20-row side-by-side for Jordan
    python3 scripts/eval-cleanup-vs-wispr.py --flow-results stock.jsonl tuned.jsonl --side-by-side review.md

    # quick checks
    python3 scripts/eval-cleanup-vs-wispr.py --identity                       # paste the input unchanged
    python3 scripts/eval-cleanup-vs-wispr.py --mlx-model <MLX dir>            # model only, no Flow guard/post-steps
    python3 scripts/eval-cleanup-vs-wispr.py --predictions out.jsonl          # {"id" or "index", "output"}

Flow --cleanup-run output, one JSON line per eval-input row:
  {"id", "final", "s1_result": "accepted|unchanged|unavailable:<r>|rejected:<r>|skipped:<r>",
   "guard_refused": bool, "cleanup_ms": float, "model": "stock|wispr-v1"}

Metrics (main test slice; also per hard-slice tag):
  closeness       1 - formatted token error rate vs Wispr (words with case + punctuation). Headline.
  wer             word error rate vs Wispr, ignoring case and punctuation (lower is better)
  exact           share identical to Wispr (whitespace-insensitive)
  drop_recall     of the words Wispr removed (fillers, restarts), share the output also removed
  filler_removed  same, for classic fillers only (um, uh, like, you know, I mean...)
  content_lost    share of words Wispr KEPT that the output deleted (meaning loss; lower is better)
  invented        share of output words in neither input nor Wispr (hallucination; lower is better)
  punct_f1        agreement on , . ? ! after shared words
  case_agree      same capitalisation on shared words
  refusal         share where S1 was rejected/unavailable or Flow's guard refused (production runs only)
  cleanup_ms      p50 / p95 warm cleanup latency (production runs only)
  routing_ok      share of routing rows (Dutch, mixed) left unchanged (must be 1.0)
"""
import argparse
import difflib
import json
from pathlib import Path
import re
import statistics
import sys

DATA = Path.home() / 'Library/Application Support/VOICE/WisprCleanupTuning-v2'
WORD = re.compile(r"[\w'’]+", re.UNICODE)
TOKEN = re.compile(r"[\w'’-]+|[^\w\s]", re.UNICODE)
FILLERS = {'um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'hmm', 'ah', 'like', 'basically', 'literally'}
FILLER_PHRASES = ('you know', 'i mean', 'sort of', 'kind of')
MARKS = ',.?!'
CRITICAL_TAGS = ('number', 'time', 'url_email_path', 'dictionary_name')

# Ship rule: every line must hold for the candidate versus stock on the main test slice.
SHIP_RULES = [
    ('closeness', 'closeness gains at least 0.03', lambda s, c: c >= s + 0.03),
    ('wer', 'word error to Wispr drops by at least 0.02', lambda s, c: c <= s - 0.02),
    ('content_lost', 'meaning loss at most 1.0% and no more than 0.3 pt above stock',
     lambda s, c: c <= 0.010 and c <= s + 0.003),
    ('invented', 'invented words at most 0.5% and no more than 0.2 pt above stock',
     lambda s, c: c <= 0.005 and c <= s + 0.002),
    ('refusal', 'refusal rate no more than 2 pt above stock', lambda s, c: c <= s + 0.02),
    ('cleanup_ms_p95', 'p95 cleanup latency no more than 1.25x stock', lambda s, c: c <= s * 1.25 + 5),
    ('routing_ok', 'every Dutch/mixed routing row unchanged', lambda s, c: c >= 1.0),
]


def norm_words(text):
    return [w.lower().replace('’', "'") for w in WORD.findall(text or '')]


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + (x != y))
        previous = current
    return previous[-1]


def deleted_positions(source, result):
    gone = set()
    for op, i1, i2, _, _ in difflib.SequenceMatcher(None, source, result, autojunk=False).get_opcodes():
        if op in ('delete', 'replace'):
            gone.update(range(i1, i2))
    return gone


def filler_positions(words):
    hits = {i for i, w in enumerate(words) if w in FILLERS}
    for phrase in FILLER_PHRASES:
        n = len(phrase.split())
        for i in range(len(words) - n + 1):
            if ' '.join(words[i:i + n]) == phrase:
                hits.update(range(i, i + n))
    return hits


def word_marks(text):
    out = []
    for match in re.finditer(r"([\w'’-]+)([^\w\s]*)", text or ''):
        mark = next((c for c in match.group(2) if c in MARKS), '')
        out.append((match.group(1).lower().replace('’', "'"), match.group(1), mark))
    return out


def score(source, output, target):
    s, o, t = norm_words(source), norm_words(output), norm_words(target)
    ft, fo = TOKEN.findall(target), TOKEN.findall(output)
    r = {'wer_edits': edit_distance(t, o), 'wer_words': max(1, len(t)),
         'fmt_edits': edit_distance(ft, fo), 'fmt_tokens': max(1, len(ft)),
         'exact': ' '.join(output.split()) == ' '.join(target.split())}
    wispr_gone, out_gone = deleted_positions(s, t), deleted_positions(s, o)
    wispr_kept = set(range(len(s))) - wispr_gone
    fillers = filler_positions(s)
    r.update(drop_both=len(wispr_gone & out_gone), drop_wispr=len(wispr_gone),
             filler_wispr=len(fillers & wispr_gone), filler_both=len(fillers & wispr_gone & out_gone),
             kept_wispr=len(wispr_kept - fillers), kept_lost=len((wispr_kept - fillers) & out_gone))
    wt, wo = word_marks(target), word_marks(output)
    tp = fp = fn = same_case = shared = 0
    matcher = difflib.SequenceMatcher(None, [w[0] for w in wt], [w[0] for w in wo], autojunk=False)
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            a, b = wt[block.a + k], wo[block.b + k]
            shared += 1
            same_case += a[1] == b[1]
            if a[2] and a[2] == b[2]:
                tp += 1
            else:
                fn += bool(a[2])
                fp += bool(b[2])
    known = set(s) | set(t)
    r.update(p_tp=tp, p_fp=fp, p_fn=fn, case_same=same_case, case_shared=shared,
             invented=sum(w not in known for w in o), out_words=len(o))
    return r


def aggregate(scores, extras=None):
    if not scores:
        return {'rows': 0}
    total = lambda key: sum(r[key] for r in scores)
    ratio = lambda a, b: round(a / b, 4) if b else None
    precision = ratio(total('p_tp'), total('p_tp') + total('p_fp')) or 0
    recall = ratio(total('p_tp'), total('p_tp') + total('p_fn')) or 0
    out = {
        'rows': len(scores),
        'closeness': round(1 - total('fmt_edits') / total('fmt_tokens'), 4),
        'wer': ratio(total('wer_edits'), total('wer_words')),
        'exact': ratio(sum(r['exact'] for r in scores), len(scores)),
        'drop_recall': ratio(total('drop_both'), total('drop_wispr')),
        'filler_removed': ratio(total('filler_both'), total('filler_wispr')),
        'content_lost': ratio(total('kept_lost'), total('kept_wispr')) or 0.0,
        'invented': ratio(total('invented'), total('out_words')) or 0.0,
        'punct_f1': round(2 * precision * recall / (precision + recall), 4) if precision and recall else 0.0,
        'case_agree': ratio(total('case_same'), total('case_shared')),
    }
    if extras:
        out.update(extras)
    return out


def read_jsonl(path):
    return [json.loads(line) for line in path.open(encoding='utf-8') if line.strip()]


def mlx_outputs(rows, model_path, adapter):
    from mlx_lm import load, generate  # loads a model: only when asked
    model, tokenizer = load(str(model_path), adapter_path=str(adapter) if adapter else None)
    outputs = []
    for i, row in enumerate(rows):
        prompt = tokenizer.apply_chat_template(row['messages'][:2], add_generation_prompt=True,
                                               tokenize=False, enable_thinking=False)
        budget = min(1024, max(64, int(len(tokenizer.encode(row['messages'][1]['content'].split('\n', 1)[1])) * 1.3) + 32))
        text = generate(model, tokenizer, prompt=prompt, max_tokens=budget, verbose=False)
        outputs.append(re.sub(r'<think>.*?</think>', '', text, flags=re.S).strip())
        if (i + 1) % 25 == 0:
            print('  generated %d/%d' % (i + 1, len(rows)), file=sys.stderr)
    return outputs


def evaluate(label, ids, sources, outputs, targets, tags, flow=None, routing=None):
    scores = [score(s, o, t) for s, o, t in zip(sources, outputs, targets)]
    extras = {}
    if flow is not None:
        refused = [not (f.get('s1_result', '').startswith(('accepted', 'unchanged'))) or bool(f.get('guard_refused'))
                   for f in flow]
        times = sorted(f['cleanup_ms'] for f in flow if isinstance(f.get('cleanup_ms'), (int, float)))
        extras = {'refusal': round(sum(refused) / max(1, len(refused)), 4),
                  'cleanup_ms_p50': round(statistics.median(times), 1) if times else None,
                  'cleanup_ms_p95': round(times[max(0, int(len(times) * 0.95) - 1)], 1) if times else None}
    if routing is not None:
        extras['routing_ok'] = round(sum(routing) / len(routing), 4) if routing else 1.0
    report = {'system': label, **aggregate(scores, extras), 'slices': {}}
    for tag in sorted({t for row in tags for t in row}):
        picked = [sc for sc, row in zip(scores, tags) if tag in row]
        report['slices'][tag] = {k: v for k, v in aggregate(picked).items()
                                 if k in ('rows', 'closeness', 'wer', 'content_lost', 'invented')}
    return report, scores


def verdict(stock, candidate):
    lines, ok = [], True
    for key, text, rule in SHIP_RULES:
        s, c = stock.get(key), candidate.get(key)
        if s is None or c is None:
            lines.append(('?', text, s, c))
            ok = False
            continue
        passed = rule(s, c)
        ok &= passed
        lines.append(('PASS' if passed else 'FAIL', text, s, c))
    for tag in CRITICAL_TAGS:
        s = stock['slices'].get(tag, {}).get('content_lost')
        c = candidate['slices'].get(tag, {}).get('content_lost')
        if s is not None and c is not None:
            passed = c <= s + 0.005
            ok &= passed
            lines.append(('PASS' if passed else 'FAIL', 'no extra meaning loss on %s rows' % tag, s, c))
    return ok, lines


def side_by_side(path, ids, sources, targets, outputs_a, outputs_b, scores_a, scores_b, n=20):
    gain = [(1 - b['fmt_edits'] / b['fmt_tokens']) - (1 - a['fmt_edits'] / a['fmt_tokens'])
            for a, b in zip(scores_a, scores_b)]
    order = sorted(range(len(ids)), key=lambda i: gain[i])
    changed = [i for i in order if outputs_a[i] != outputs_b[i]]
    picks = changed[:n // 2] + changed[-(n - n // 2):] if len(changed) > n else changed
    clean = lambda s: (s or '').replace('|', '/').replace('\n', ' ⏎ ')
    lines = ['# Flow cleanup: now vs tuned (%d examples)' % len(picks), '',
             'For each row, mark which Flow line is closer to how you want it: **now**, **tuned** or **same**. '
             'Flag any row where a version changed what you meant.', '']
    for k, i in enumerate(sorted(set(picks), key=lambda i: gain[i], reverse=True), 1):
        lines += ['## %d' % k, '', '- **You said (Parakeet):** ' + clean(sources[i]), '- **Wispr:** ' + clean(targets[i]),
                  '- **Flow now:** ' + clean(outputs_a[i]), '- **Flow tuned:** ' + clean(outputs_b[i]),
                  '- Your pick: now / tuned / same — meaning changed? yes / no', '']
    path.write_text('\n'.join(lines), encoding='utf-8')
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--data', type=Path, default=DATA)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--identity', action='store_true')
    mode.add_argument('--flow-results', type=Path, nargs='+', metavar='JSONL',
                      help='Flow --cleanup-run outputs: stock first, then candidate(s)')
    mode.add_argument('--mlx-model', type=Path)
    mode.add_argument('--predictions', type=Path)
    parser.add_argument('--adapter', type=Path)
    parser.add_argument('--limit', type=int)
    parser.add_argument('--side-by-side', type=Path, help='write a 20-row review page for Jordan (needs 2 runs)')
    parser.add_argument('--details', type=Path, help='per-row scores (private)')
    parser.add_argument('--json', type=Path, help='write the reports as JSON')
    args = parser.parse_args()

    rows = read_jsonl(args.data / 'test.jsonl')
    meta = read_jsonl(args.data / 'test.meta.jsonl')
    if args.limit:
        rows, meta = rows[:args.limit], meta[:args.limit]
    ids = [m['id'] for m in meta]
    sources = [r['messages'][1]['content'].split('\n', 1)[1] for r in rows]
    model_targets = [r['messages'][2]['content'] for r in rows]          # what the model is trained to emit
    pasted_targets = [m.get('wispr_target_as_pasted') or t for m, t in zip(meta, model_targets)]  # what Wispr pasted
    tags = [m.get('tags', []) for m in meta]
    reports = []

    if args.identity:
        reports.append(evaluate('identity (input unchanged)', ids, sources, sources, pasted_targets, tags)[0])
    elif args.predictions:
        by_key = {}
        for item in read_jsonl(args.predictions):
            by_key[item.get('id', item.get('index'))] = item['output']
        outputs = [by_key.get(i, by_key.get(n)) for n, i in enumerate(ids)]
        if any(o is None for o in outputs):
            raise SystemExit('%d test rows have no prediction' % sum(o is None for o in outputs))
        reports.append(evaluate(str(args.predictions), ids, sources, outputs, model_targets, tags)[0])
    elif args.mlx_model:
        outputs = mlx_outputs(rows, args.mlx_model, args.adapter)
        label = 'model only, no Flow post-steps: %s%s' % (args.mlx_model.name, ' + adapter' if args.adapter else '')
        reports.append(evaluate(label, ids, sources, outputs, model_targets, tags)[0])
    else:
        routing_rows = {r['id']: r for r in read_jsonl(args.data / 'eval-input.jsonl') if r.get('slice') == 'routing'}
        runs = []
        for path in args.flow_results:
            results = {r['id']: r for r in read_jsonl(path)}
            missing = [i for i in ids if i not in results]
            if missing:
                raise SystemExit('%s: %d test rows missing' % (path, len(missing)))
            flow = [results[i] for i in ids]
            outputs = [f.get('final') or '' for f in flow]
            routing = [results[i].get('final', '').strip() == r['text'].strip()
                       for i, r in routing_rows.items() if i in results]
            label = '%s (Flow production path)' % (flow[0].get('model') or path.name)
            report, scores = evaluate(label, ids, sources, outputs, pasted_targets, tags, flow=flow, routing=routing)
            runs.append((report, scores, outputs))
            reports.append(report)
        if len(runs) >= 2:
            ok, lines = verdict(runs[0][0], runs[-1][0])
            print('\nSHIP CHECK (%s vs %s)' % (runs[-1][0]['system'], runs[0][0]['system']))
            for status, text, s, c in lines:
                print('  %-4s %-62s stock=%s  tuned=%s' % (status, text, s, c))
            print('  => %s (then Jordan reviews the side-by-side: tuned better or same in >= 14 of 20, '
                  'no meaning changes)' % ('SHIP CANDIDATE' if ok else 'DO NOT SHIP'))
            if args.side_by_side:
                side_by_side(args.side_by_side, ids, sources, pasted_targets, runs[0][2], runs[-1][2],
                             runs[0][1], runs[-1][1])
                print('Side-by-side written to', args.side_by_side)

    for report in reports:
        print(json.dumps(report, indent=2))
    if args.json:
        args.json.write_text(json.dumps(reports, indent=2))
        args.json.chmod(0o600)


if __name__ == '__main__':
    main()
