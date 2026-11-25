#!/usr/bin/env python3
"""Build private training pairs (raw speech text -> Wispr's formatted text) for a cleanup-model LoRA.

Reads the local Wispr history read-only and writes chat-format JSONL that
`mlx_lm.lora --data <dir>` accepts. Only the stable *tuning* split is used, so
the evaluation clips stay untouched for an honest before/after comparison.

    python3 scripts/prepare-wispr-cleanup-tuning.py            # counts only
    python3 scripts/prepare-wispr-cleanup-tuning.py --write    # write the files

Caveats that matter for quality:
- Wispr's formatted text is its product output, not text Jordan approved.
- The input here is Wispr's own speech recogniser, not Parakeet. For the best
  result, re-transcribe the tuning audio with Parakeet and use that as input.
- Nothing here trains or loads a model.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
DEFAULT_DB = Path.home() / 'Library/Application Support/Wispr Flow/flow.sqlite'
DEFAULT_OUTPUT = Path.home() / 'Library/Application Support/VOICE/WisprCleanupTuning'
DEFAULT_SYSTEM = ('Clean up this dictated text. Fix punctuation, capitalisation and obvious speech slips. '
                  'Keep the meaning, names, numbers and language exactly. Output only the cleaned text.')

spec = importlib.util.spec_from_file_location('wispr_eval', HERE / 'prepare-wispr-audio-evaluation.py')
wispr_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wispr_eval)

WORD = re.compile(r"[\w'’]+", re.UNICODE)
NUMBER = re.compile(r'\d+(?:[.,]\d+)*')


def words(text):
    return [w.lower().replace('’', "'") for w in WORD.findall(text)]


def keep(raw, formatted, min_words, max_words):
    """Drop pairs where the product rewrote rather than cleaned, so the model learns light cleanup."""
    raw_words, formatted_words = words(raw), words(formatted)
    if not (min_words <= len(raw_words) <= max_words) or not formatted_words:
        return 'length'
    ratio = len(formatted_words) / len(raw_words)
    if ratio < 0.6 or ratio > 1.25:
        return 'length_changed'
    if sorted(NUMBER.findall(raw)) != sorted(NUMBER.findall(formatted)):
        return 'digits_changed'
    shared = len(set(raw_words) & set(formatted_words)) / max(1, len(set(formatted_words)))
    if shared < 0.7:
        return 'rewritten'
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--reference-db', type=Path, default=DEFAULT_DB)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--system-prompt-file', type=Path,
                        help='Use the exact prompt of the model being tuned (required for S1-mini)')
    parser.add_argument('--languages', default='en,nl', help='Comma-separated stored languages to keep')
    parser.add_argument('--min-words', type=int, default=4)
    parser.add_argument('--max-words', type=int, default=150)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()

    system = args.system_prompt_file.read_text().strip() if args.system_prompt_file else DEFAULT_SYSTEM
    languages = {item.strip() for item in args.languages.split(',') if item.strip()}
    indexed, _ = wispr_eval.history_rows({}, args.reference_db)
    dropped, seen, pairs = {}, set(), []

    def drop(reason):
        dropped[reason] = dropped.get(reason, 0) + 1

    for identifier in sorted(indexed):
        group = indexed[identifier]
        if wispr_eval.source_split(identifier) != 'tuning':
            drop('evaluation_split_held_out')
            continue
        if len(group) != 1:
            drop('repeated_id')
            continue
        row = group[0]
        metadata = row['metadata']
        status = (row.get('status') or '').lower()
        if row['deleted'] or row.get('oversized_text') or (status and status not in wispr_eval.SUCCESS):
            drop('deleted_failed_or_unfinished')
            continue
        if metadata.get('hasRevertedAI') or metadata.get('usedFallbackFormatting') or metadata.get('usedFallbackAsr'):
            drop('reverted_or_fallback')
            continue
        language = (wispr_eval.language_of(row) or '').split('-')[0].lower()
        if language not in languages:
            drop('language')
            continue
        raw = (row['texts'].get('raw_asr_text') or '').strip()
        formatted = (row['texts'].get('formatted_text') or '').strip()
        if not raw or not formatted:
            drop('empty_text')
            continue
        reason = keep(raw, formatted, args.min_words, args.max_words)
        if reason:
            drop(reason)
            continue
        key = ' '.join(words(raw))
        if key in seen:
            drop('duplicate')
            continue
        seen.add(key)
        pairs.append((identifier, {'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': raw},
            {'role': 'assistant', 'content': formatted}]}))

    # Stable 90/10 split inside the tuning data, independent of file order.
    valid = [p for i, p in pairs if int(wispr_eval.digest('valid:' + i)[:8], 16) % 10 == 0]
    train = [p for i, p in pairs if int(wispr_eval.digest('valid:' + i)[:8], 16) % 10 != 0]
    print(json.dumps({'train': len(train), 'valid': len(valid), 'dropped': dropped,
                      'unchanged_pairs': sum(1 for _, p in pairs
                                             if p['messages'][1]['content'] == p['messages'][2]['content'])}, indent=2))
    if not args.write:
        print('Counts only. Add --write to create the private files.')
        return
    wispr_eval.private_directory(args.output)
    for name, rows in (('train.jsonl', train), ('valid.jsonl', valid)):
        path = args.output / name
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as file:
            for row in rows:
                file.write(json.dumps(row, ensure_ascii=False) + '\n')
    print('Wrote', args.output)
    print('Next (not run here): mlx_lm.lora --model <local model dir> --train --data "%s" '
          '--iters 600 --batch-size 4 --num-layers 8 --adapter-path <private dir>' % args.output)


if __name__ == '__main__':
    main()
