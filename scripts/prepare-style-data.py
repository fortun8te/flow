#!/usr/bin/env python3
"""Build a conservative style pilot. Standard library, read-only SQLite, no models.

Never overwrites an output directory. All descendants stay in the same split.
Style settings are requested styles, not proof of backend adherence.
"""
import argparse
import collections
import hashlib
import json
import re
import sqlite3
from pathlib import Path

STYLES = ('formal', 'casual', 'veryCasual', 'excited')


def read_rows(path):
    return [json.loads(line) for line in path.open() if line.strip()]


def words(text):
    return re.findall(r"\w+(?:['’]\w+)*", text.casefold())


def fingerprint(text):
    return ' '.join(words(text))


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def standard_case(text):
    return bool(re.match(r'[A-Z]', text)) and not re.search(r'[.!?]\s+[a-z]', text)


def supports(text, style):
    if not text or '[Styling:' in text:
        return False
    if style == 'veryCasual':
        return text.islower() and not text.endswith('.')
    if style == 'excited':
        return standard_case(text) and '!' in text
    if style == 'casual':
        return standard_case(text) and not text.endswith(('.', '!'))
    return standard_case(text) and text.endswith(('.', '?')) and '!' not in text


def structure(text):
    return 'lists' if len(re.findall(r'^\s*[-*] ', text, re.M)) >= 3 else 'prose'


def email_parts(text):
    # Require already spoken greeting, body and sign-off. No invented subject/name.
    return re.fullmatch(r'(Hi|Hello|Hey|Dear) ([A-Za-z]+),\s+(.+?)\s+(Thanks|Best|Regards|Kind regards),\s+([A-Za-z]+)\.?', text, re.S)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, default=Path.home() / 'Library/Application Support/VOICE/WhisperNowTuning')
    ap.add_argument('--db', type=Path, default=Path.home() / 'Library/Application Support/Wispr Flow/flow.sqlite')
    ap.add_argument('--output', type=Path, default=Path.home() / 'Library/Application Support/VOICE/WhisperNowTuning-style')
    args = ap.parse_args()
    if args.output.exists():
        raise SystemExit('Refusing to overwrite existing output. Choose a new --output directory.')
    pool = read_rows(args.source / 'train-full-mix.jsonl')
    audit = {r['id']: r for r in read_rows(args.source / 'audit.jsonl')}
    blocked = set(strings(json.loads((args.source / 'frozen-ids.json').read_text())))
    forbidden_text = set()
    # Existing validation sets are also excluded. Only fingerprints used, no labels copied.
    for name in ('test.jsonl', 'challenge.jsonl', 'valid-tune.jsonl', 'valid-select.jsonl', 'valid-public.jsonl'):
        for row in read_rows(args.source / name):
            blocked.add(row['id'])
            forbidden_text.update(fingerprint(m['content']) for m in row['messages'])
    with sqlite3.connect(args.db.resolve().as_uri() + '?mode=ro', uri=True) as con:
        con.execute('PRAGMA query_only=ON')
        con.row_factory = sqlite3.Row
        history = [dict(r) for r in con.execute('SELECT transcriptEntityId, asrText, formattedText, app, url, personalizationStyleSettings, toneMatchedText FROM History')]
    hist = {r['transcriptEntityId']: r for r in history}
    counts = collections.Counter()
    observations = collections.defaultdict(collections.Counter)
    for h in history:
        settings = json.loads(h['personalizationStyleSettings'] or '{}')
        style = settings.get('personalizationStyle', 'missing')
        cat = settings.get('personalizationAppType', 'missing')
        counts[cat + '/' + style] += 1
        t = (h['formattedText'] or '').strip()
        observations[style].update(rows=1, lowercase=int(t.islower()), final_period=int(t.endswith('.')), contains_exclamation=int('!' in t), tone_matched_nonempty=int(bool(h['toneMatchedText'])))
    excluded = collections.Counter()
    eligible = []
    seen_ids = set()
    for r in pool:
        if r['id'] in seen_ids:
            continue
        seen_ids.add(r['id'])
        raw, target = (m['content'] for m in r['messages'])
        if r['id'] in blocked or any(fingerprint(t) in forbidden_text for t in (raw, target)):
            excluded['held_out_id_or_text'] += 1
            continue
        if r.get('origin') == 'personal' and audit.get(r['id'], {}).get('status') not in ('auto', 'approved'):
            excluded['not_auto_or_approved'] += 1
            continue
        if not raw.strip() or not target.strip() or target == 'EMPTY' or '[Styling:' in raw:
            excluded['empty_or_control'] += 1
            continue
        eligible.append(r)
    # Group duplicate input OR target text transitively, then split groups.
    parent = {r['id']: r['id'] for r in eligible}
    def root(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k
    keys = {}
    for r in eligible:
        for m in r['messages']:
            key = fingerprint(m['content'])
            if key in keys:
                a, b = root(r['id']), root(keys[key])
                parent[max(a, b)] = min(a, b)
            keys[key] = r['id']
    outputs = {'train': [], 'valid': []}
    emitted = set()
    examples = collections.defaultdict(list)
    def emit(r, target, style=None, kind='observed', layout='prose', context='general', category=None):
        raw = r['messages'][0]['content']
        group = root(r['id'])
        split = 'valid' if int(hashlib.sha256(group.encode()).hexdigest()[:8], 16) % 10 == 0 else 'train'
        control = f'[Styling: {style}] [Structure: {layout}] [Context: {context}]\n' if style else ''
        key = (control + raw, target)
        if key in emitted:
            return
        emitted.add(key)
        if kind.startswith('mechanical'):
            assert words(target) == words(r['messages'][1]['content']), r['id']
        ident = hashlib.sha256((r['id'] + control + target + kind).encode()).hexdigest()[:16]
        outputs[split].append({'id': 'style:' + ident, 'source_id': r['id'], 'source_group': group, 'origin': r.get('origin'), 'license': r.get('license'), 'kind': kind, 'style': style, 'structure': layout if style else None, 'context': context if style else None, 'app_category': category, 'messages': [{'role': 'user', 'content': control + raw}, {'role': 'assistant', 'content': target}]})
    for r in sorted(eligible, key=lambda x: x['id']):
        raw, target = (m['content'] for m in r['messages'])
        emit(r, target, kind='unstyled_replay')
        h = hist.get(r['id'])
        if h:
            settings = json.loads(h['personalizationStyleSettings'] or '{}')
            style = settings.get('personalizationStyle')
            if style == 'genz':
                style = 'veryCasual'
            cat = settings.get('personalizationAppType')
            observed = (h['toneMatchedText'] or h['formattedText'] or '').strip()
            # Require the current training target to be exactly the observed output.
            # Inconsistent settings are never silently relabelled as another style.
            context = 'email' if cat == 'email' else 'general'
            if style in STYLES and observed == target and supports(target, style) and (context != 'email' or email_parts(target)):
                emit(r, target, style, category=cat, layout=structure(target), context=context)
                if len(examples[style]) < 3:
                    examples[style].append({'source_id': r['id'], 'app': h['app'], 'asr': raw, 'target': target})
            else:
                excluded['observed_not_supported_or_target_mismatch'] += 1
        # Verified-neutral here means mechanical verification, NOT human approval:
        # same lexical tokens as ASR; simple sentence with full stop; no code/names.
        neutral = (words(raw) == words(target) and 4 <= len(words(target)) <= 70
                   and bool(re.fullmatch(r"[A-Z][a-zA-Z ,;'’\-]+\.", target))
                   and not re.search(r'\b[A-Z][A-Za-z]+', target[1:])
                   and not re.search(r'\b[A-Z]{2,}\b', target)
                   and standard_case(target))
        if neutral:
            emit(r, target, 'formal', 'mechanical_neutral')
            casual = target[:-1]  # retain contractions and internal punctuation
            emit(r, casual, 'casual', 'mechanical_terminal_period')
            emit(r, casual.lower(), 'veryCasual', 'mechanical_lowercase_terminal_period')
        # Pure existing bullet lists, >=3 short items, no prose to reinterpret.
        lines = target.splitlines()
        if 3 <= len(lines) <= 15 and all(re.fullmatch(r'- [A-Za-z][A-Za-z ,\'’\-]{0,80}', line) for line in lines):
            for style in ('formal', 'casual', 'veryCasual'):
                items = [line[2:] for line in lines]
                if style == 'veryCasual':
                    items = [t.lower() for t in items]
                bullet = '\n'.join('- ' + t for t in items)
                prose = '; '.join(items) + ('.' if style == 'formal' else '')
                emit(r, bullet, style, 'mechanical_list', layout='lists')
                emit(r, prose, style, 'mechanical_prose')
        # Existing email only: punctuation and whitespace boundaries, no new words.
        m = email_parts(target)
        if m and standard_case(target) and '!' not in target:
            greeting, name, body, signoff, sender = m.groups()
            email = f'{greeting} {name},\n\n{body}\n\n{signoff},\n{sender}'
            prose = re.sub(r'\s+', ' ', target)
            emit(r, email, 'formal', 'mechanical_email', context='email')
            emit(r, prose, 'formal', 'mechanical_email_prose')
    train_sources = {r['source_id'] for r in outputs['train']}
    valid_sources = {r['source_id'] for r in outputs['valid']}
    assert not train_sources & valid_sources
    assert not (train_sources | valid_sources) & blocked
    summary = {'version': 1, 'source': str(args.source), 'database_mode': 'ro + query_only', 'history_rows': len(history), 'history_category_style_counts': dict(sorted(counts.items())), 'history_style_observations': dict(observations), 'observed_training_examples': dict(examples), 'input_training_rows': len(pool), 'eligible_source_rows': len(eligible), 'excluded': dict(excluded), 'human_approved_neutral_claim': False, 'neutral_verification': 'audit auto/approved if personal, lexical identity to ASR, simple sentence and casing guards', 'all_source_ids_training_only': True, 'source_ids_disjoint': True, 'sizes': {}, 'sha256': {}}
    args.output.mkdir(parents=True, exist_ok=False)
    for split, rows in outputs.items():
        path = args.output / (split + '-style.jsonl')
        with path.open('x') as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + '\n')
        summary['sizes'][split] = {'rows': len(rows), 'source_ids': len({r['source_id'] for r in rows}), 'styles': dict(collections.Counter(r['style'] or 'unstyled' for r in rows)), 'kinds': dict(collections.Counter(r['kind'] for r in rows)), 'controls': dict(collections.Counter(f"{r['style']}/{r['structure']}/{r['context']}" for r in rows if r['style']))}
        summary['sha256'][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ('train-full-mix.jsonl', 'audit.jsonl', 'frozen-ids.json'):
        summary['sha256']['source:' + name] = hashlib.sha256((args.source / name).read_bytes()).hexdigest()
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'output': str(args.output), 'sizes': summary['sizes'], 'excluded': dict(excluded)}, indent=2))


if __name__ == '__main__':
    main()
