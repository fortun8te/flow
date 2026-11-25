#!/usr/bin/env python3
"""Join Flow shadow-mode captures to Wispr Flow's History rows, giving exact training pairs.

Shadow mode makes Flow record the same fn
press as Wispr without pasting, and append one JSON line per capture to
~/Library/Application Support/VOICE/Shadow/shadow.jsonl. This script matches each capture to
the Wispr row for the same utterance by time, duration and text similarity, one-to-one.

    python3 scripts/pair-shadow-with-wispr.py              # counts only
    python3 scripts/pair-shadow-with-wispr.py --write      # write shadow-pairs.jsonl

Then feed the pairs to the dataset builder (input = exactly what Flow's cleanup saw):

    python3 scripts/prepare-wispr-cleanup-v2.py --write \
        --parakeet-predictions "~/Library/Application Support/VOICE/WisprCleanupTuning-v2/shadow-pairs.jsonl"

Wispr's database is opened read-only (mode=ro, query_only). Nothing leaves this Mac.
"""
import argparse
import datetime as dt
import difflib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cleanup_v2', HERE / 'prepare-wispr-cleanup-v2.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

DEFAULT_SHADOW = Path.home() / 'Library/Application Support/VOICE/Shadow'
DEFAULT_OUTPUT = builder.DEFAULT_OUTPUT / 'shadow-pairs.jsonl'
WINDOW_SECONDS = 30.0      # search radius around the capture
ACCEPT_SIMILARITY = 0.5    # word similarity Parakeet vs Wispr ASR needed for a text-confirmed match
TIGHT_SECONDS = 2.5        # a time+duration-only match must be this close on both


def parse_time(value):
    """ISO 8601 from Flow ('2026-11-13T14:38:43.023Z') or Wispr ('2026-11-13 14:38:43.023 +00:00')."""
    text = value.strip().replace('Z', '+00:00')
    if ' +' in text or ' -' in text:
        text = text.replace(' +', '+').replace(' -', '-')
    moment = dt.datetime.fromisoformat(text.replace(' ', 'T', 1))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=dt.timezone.utc)
    return moment.timestamp()


def read_shadow(directory):
    captures = []
    for file in sorted(directory.glob('shadow*.jsonl')):
        for number, line in enumerate(file.open(encoding='utf-8'), 1):
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                item['_start'] = parse_time(item['started_at'])
                item['_end'] = parse_time(item['ended_at'])
            except (ValueError, KeyError):
                print('skipping unreadable line %s:%d' % (file.name, number))
                continue
            if item.get('schema') == 1 and (item.get('parakeet_raw') or '').strip():
                captures.append(item)
    return captures


def read_wispr(database, start, end):
    uri = database.expanduser().absolute().as_uri() + '?mode=ro'
    fields = [f for f in builder.FIELDS] + ['timestamp', 'speechDuration']
    with sqlite3.connect(uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only=ON')
        columns = {r['name'] for r in connection.execute('PRAGMA table_info(History)')}
        fields = [f for f in fields if f in columns]
        rows = [dict(r) for r in connection.execute(
            'SELECT %s FROM History WHERE timestamp IS NOT NULL' % ','.join('"%s"' % f for f in fields))]
    out = []
    for row in rows:
        try:
            row['_time'] = parse_time(row['timestamp'])
        except ValueError:
            continue
        if start - WINDOW_SECONDS <= row['_time'] <= end + WINDOW_SECONDS:
            out.append(row)
    return out


def route_of(capture):
    """Where Flow sent this capture. Records from 13 Nov 2026 carry `route` (ShadowRecord in
    Services/ShadowMode.swift); older ones are derived from cleanup_engine/result the same way
    ShadowCleanupObserver.route does."""
    if capture.get('route'):
        return capture['route']
    engine, result = capture.get('cleanup_engine') or '', capture.get('cleanup_result') or ''
    if engine == 'local:s1-mini' and not result.startswith('unavailable:unsupportedLanguage'):
        return 's1'
    if engine not in ('local:s1-mini', 'rules'):
        return 'skip:engine-' + engine
    return 'skip:' + (result.split(':', 1)[1] if ':' in result else result or 'unknown')


def control_line_of(capture):
    """The control line S1-mini actually got. Older s1 records lack it; Flow then always sent the default."""
    if capture.get('s1_control_line'):
        return capture['s1_control_line']
    return builder.DEFAULT_CONTROL if route_of(capture) == 's1' else None


def similarity(a, b):
    x, y = builder.words(a), builder.words(b)
    if not x or not y:
        return 0.0
    return difflib.SequenceMatcher(None, x, y, autojunk=False).ratio()


def candidates(capture, wispr):
    """Score every Wispr row near this capture. Wispr's timestamp may mark start or end, so use the closer."""
    found = []
    duration = capture.get('duration_s') or (capture['_end'] - capture['_start'])
    for row in wispr:
        offset = min(abs(row['_time'] - capture['_start']), abs(row['_time'] - capture['_end']))
        if offset > WINDOW_SECONDS:
            continue
        gap = abs((row.get('duration') or 0) - duration)
        text = similarity(capture['parakeet_raw'], row.get('asrText') or row.get('formattedText') or '')
        confirmed = text >= ACCEPT_SIMILARITY
        tight = offset <= TIGHT_SECONDS and gap <= TIGHT_SECONDS and text >= 0.2
        if confirmed or tight:
            found.append((text - offset / 60.0 - gap / 30.0, offset, gap, text, row))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--shadow-dir', type=Path, default=DEFAULT_SHADOW)
    parser.add_argument('--reference-db', type=Path, default=builder.DEFAULT_DB)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()

    captures = read_shadow(args.shadow_dir)
    if not captures:
        raise SystemExit('No shadow captures found in %s' % args.shadow_dir)
    wispr = read_wispr(args.reference_db, min(c['_start'] for c in captures), max(c['_end'] for c in captures))

    # Greedy one-to-one assignment, best scores first.
    scored = []
    for capture in captures:
        for score, offset, gap, text, row in candidates(capture, wispr):
            scored.append((score, offset, gap, text, capture['id'], row['transcriptEntityId']))
    scored.sort(reverse=True)
    used_capture, used_row, matches = set(), set(), {}
    for score, offset, gap, text, capture_id, row_id in scored:
        if capture_id in used_capture or row_id in used_row:
            continue
        used_capture.add(capture_id)
        used_row.add(row_id)
        matches[capture_id] = (row_id, offset, gap, text)

    rows_by_id = {r['transcriptEntityId']: r for r in wispr}
    pairs, outcome = [], {}
    for capture in captures:
        match = matches.get(capture['id'])
        if not match:
            outcome['unmatched'] = outcome.get('unmatched', 0) + 1
            continue
        row_id, offset, gap, text = match
        row = rows_by_id[row_id]
        formatted = builder.html_to_plain((row.get('formattedText') or '').strip())
        usable = (route_of(capture) == 's1' and capture.get('cleanup_input') is not None
                  and (row.get('status') or '') == 'formatted' and formatted and not builder.squash(row.get('toneMatchedText'))
                  and (row.get('transcriptCommand') or '') != 'command' and not row.get('hasRevertedAI'))
        target, kind = builder.choose_target(formatted, row.get('editedText') or '') if usable else ('', 'unusable')
        outcome[kind] = outcome.get(kind, 0) + 1
        pairs.append({
            'wispr_id': row_id, 'shadow_id': capture['id'],
            # Exact string Flow handed S1-mini (byte-for-byte, not stripped); None if cleanup never ran.
            'flow_input': capture.get('cleanup_input'),
            'route': route_of(capture),
            'control_line': control_line_of(capture),
            'control_line_recorded': bool(capture.get('s1_control_line')),
            'parakeet_raw': capture['parakeet_raw'], 'flow_cleaned': capture.get('flow_cleaned'),
            'wispr_asr': row.get('asrText'), 'wispr_formatted': formatted, 'target': target, 'target_kind': kind,
            'usable': bool(usable), 'audio': capture.get('audio'), 'front_app': capture.get('front_app'),
            'wispr_app': row.get('app'), 'match': {'seconds_apart': round(offset, 2),
                                                   'duration_gap': round(gap, 2), 'asr_similarity': round(text, 3)}})

    offsets = sorted(p['match']['seconds_apart'] for p in pairs)
    summary = {'captures': len(captures), 'wispr_rows_in_window': len(wispr), 'matched': len(pairs),
               'usable_pairs': sum(p['usable'] for p in pairs), 'outcome': outcome,
               'routes': {r: sum(p['route'] == r for p in pairs) for r in sorted({p['route'] for p in pairs})},
               'control_lines': {c: sum(p['control_line'] == c for p in pairs if p['route'] == 's1')
                                 for c in sorted({p['control_line'] for p in pairs if p['route'] == 's1'})},
               'median_seconds_apart': offsets[len(offsets) // 2] if offsets else None,
               'flow_equals_wispr': sum(builder.squash(p['flow_cleaned']) == builder.squash(p['target'])
                                        for p in pairs if p['usable'])}
    print(json.dumps(summary, indent=2))
    if not args.write:
        print('Counts only. Add --write to save the pairs.')
        return
    builder.private_directory(args.output.parent)
    builder.write_jsonl(args.output, pairs)
    print('Wrote', args.output)


if __name__ == '__main__':
    main()
