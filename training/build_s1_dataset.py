#!/usr/bin/env python3
"""Build the private S1-mini LoRA dataset from the v2 Wispr split (no audio, no network).

Input:  ~/Library/Application Support/VOICE/WisprCleanupTuning-v2/{train,valid,test}.jsonl (chat format)
        Tests/PolishEval/polish-eval-cases.json (58 held-out eval cases; their raw inputs must not be trained on)
Output: ~/Library/Application Support/VOICE/S1Tuning-v1/  (0600 files, never leaves this Mac except
        over the home network to the Windows PC for training)

Held-out for scoring: test.jsonl (253 frozen rows, never trained) and the 58 eval cases.
Validation (loss, early stop, checkpoint choice): valid.jsonl (171 rows).
Train: the rest of train.jsonl after the noise filters below.
"""
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

HOME = Path.home()
SRC = HOME / 'Library/Application Support/VOICE/WisprCleanupTuning-v2'
OUT = HOME / 'Library/Application Support/VOICE/S1Tuning-v1'
CASES = Path(__file__).resolve().parent.parent / 'Tests/PolishEval/polish-eval-cases.json'

STOP = set("""a an the and or but of to in on at for with from by as is are was were be been it its it's i i'm i'd
i'll i've me my we our you your he she they them their this that these those so if then than just not no do does
did doing have has had there here about up out into over what which who when where how can could would should will
shall may might must also very too all any some more most""".split())


def toks(s):
    return re.findall(r"[a-z0-9']+", s.lower())


def read_jsonl(path):
    with open(path, encoding='utf-8') as f:
        return [json.loads(line) for line in f if line.strip()]


def pair(row):
    user = row['messages'][1]['content']
    control, _, text = user.partition('\n')
    return control, text, row['messages'][2]['content']


def trigrams(s):
    w = toks(s)
    return {tuple(w[i:i + 3]) for i in range(max(0, len(w) - 2))}


def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def write_private(path, rows):
    with open(path, 'w', encoding='utf-8') as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')
    os.chmod(path, 0o600)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    train = read_jsonl(SRC / 'train.jsonl')
    valid = read_jsonl(SRC / 'valid.jsonl')
    test = read_jsonl(SRC / 'test.jsonl')

    cases = json.loads(CASES.read_text(encoding='utf-8'))
    case_tri = [trigrams(c['raw']) for c in cases]
    test_tri = [trigrams(pair(r)[1]) for r in test]
    dropped = Counter()
    kept, seen = [], set()
    for row in train:
        control, text, target = pair(row)
        if not target.strip() or not text.strip():
            dropped['empty'] += 1
            continue
        key = (text.strip(), target.strip())
        if key in seen:
            dropped['duplicate'] += 1
            continue
        in_words = set(toks(text))
        invented = {w for w in toks(target) if w not in in_words and w not in STOP and len(w) >= 3 and not w.isdigit()}
        if len(invented) >= 2:
            dropped['invented_content'] += 1
            continue
        in_n, out_n = len(text.split()), len(target.split())
        if in_n >= 8 and not (0.5 <= out_n / in_n <= 1.3):
            dropped['length_ratio'] += 1
            continue
        tri = trigrams(text)
        if any(jaccard(tri, c) >= 0.6 for c in case_tri):
            dropped['overlaps_eval_case'] += 1
            continue
        if any(jaccard(tri, t) >= 0.6 for t in test_tri):
            dropped['overlaps_test'] += 1
            continue
        seen.add(key)
        kept.append(row)

    write_private(OUT / 'train.jsonl', kept)
    write_private(OUT / 'valid.jsonl', valid)
    write_private(OUT / 'test.jsonl', test)
    for name in ('test.meta.jsonl',):
        src = SRC / name
        if src.exists():
            write_private(OUT / name, read_jsonl(src))

    summary = {
        'source': 'WisprCleanupTuning-v2 (Wispr ASR inputs; production_exact_inputs = false)',
        'train_in': len(train), 'train_kept': len(kept), 'dropped': dict(dropped),
        'valid': len(valid), 'test_heldout': len(test), 'eval_cases_heldout': len(cases),
        'heldout_share_of_all_rows': round((len(valid) + len(test)) / (len(train) + len(valid) + len(test)), 4),
        'control_lines': dict(Counter(pair(r)[0] for r in kept + valid + test)),
        # Carried over from the v2 build so scripts/pc/train_s1_lora.py accepts the dataset.
        'system_prompt_sha256': json.loads((SRC / 'summary.json').read_text(encoding='utf-8')).get('system_prompt_sha256'),
        'production_exact_inputs': False,
    }
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    os.chmod(OUT / 'summary.json', 0o600)
    print(json.dumps({k: v for k, v in summary.items() if k != 'control_lines'}, indent=2))


if __name__ == '__main__':
    sys.exit(main())
