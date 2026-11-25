#!/usr/bin/env python3
"""Build Jordan's private dataset for LoRA-tuning WhisperNow LFM3 1.7B to clean up like Wispr Flow.

WhisperNow's format (github.com/stephan271c/WhisperNow, training/src/whispernow_training/model/prompt.py):
one user turn holding only the trimmed transcript, no system prompt; the reply is the cleaned text, or
the literal word EMPTY when nothing was dictated.

Priorities: content preservation
first, Wispr imitation second. Every target is audited against the input: each deleted content word
needs a reason (filler, repetition/restart, self-correction cue), each added word needs an approved
equivalence (number format, contraction, small grammar fix, word join). Rows that fail go to a review
queue, never silently into training. Disagreements between what Wispr formatted and what it actually
pasted are flagged for review too.

    # counts only, then write (the public sample needs the `datasets` library)
    uv run --with datasets==5.2.0 python3 scripts/prepare-whispernow-data.py
    uv run --with datasets==5.2.0 python3 scripts/prepare-whispernow-data.py --write

    # with Flow's own text (Flow --cleanup-prepare output; its `formatted` field is the model input)
    ... --write --flow-inputs "$HOME/Library/Application Support/VOICE/WisprCleanupTuning-v2/prepared.jsonl"

    # after review: apply decisions from the sheet (approve / reject / fix + fixed_target)
    ... --write --approvals "$OUT/review.csv"

    # no network: skip the public rows, or reuse the pool written earlier
    python3 scripts/prepare-whispernow-data.py --write --no-public
    python3 scripts/prepare-whispernow-data.py --write --public-pool "$OUT/public-pool.jsonl"

Read-only sources: Wispr's flow.sqlite (mode=ro, query_only), the v2 build's test/valid files (to freeze
the same held-out rows), Flow's replacements and Wispr dictionary (snippet check).

Frozen split: frozen-ids.json is written on the first --write (test = v2's 253 ids, valid = v2's 171 ids,
challenge = rows chosen once from the older pool). Later builds read it and never move those rows.

Output (~/Library/Application Support/VOICE/WhisperNowTuning/, files 0600, folder 0700):
  train-curated-{500,750,1000}.jsonl (+ -mix)   nested personal sets (+15% public MIT rows)
  train-full.jsonl (+ -mix)                      every eligible personal row (auto-passed or approved)
  valid-tune.jsonl valid-select.jsonl            personal validation (early stopping / checkpoint choice)
  valid-public.jsonl                             public MIT regression rows (forgetting monitor)
  test.jsonl test.meta.jsonl                     the same 253 legacy test rows as v2, plus audit flags
  challenge.jsonl challenge.meta.jsonl           frozen hard slices (never trained): url/path, list,
                                                 number/time, self-correction, short, code app
  review.csv review.html                         curated candidates + challenge rows for a human pass
  audit.jsonl                                    every personal row: status, flags, reasons (no text)
  frozen-ids.json public-pool.jsonl ATTRIBUTION.txt summary.json
Each training line: {"id", "origin", "input_source", "messages": [{"role": "user"}, {"role": "assistant"}]}
"""
import argparse
import csv
import datetime as dt
import difflib
import hashlib
import html
import importlib.util
import io
import json
from pathlib import Path
import random
import re
import sqlite3
import sys

HOME = Path.home()
SUPPORT = HOME / 'Library/Application Support/VOICE'
V2_DIR = SUPPORT / 'WisprCleanupTuning-v2'
DEFAULT_OUTPUT = SUPPORT / 'WhisperNowTuning'
DEFAULT_DB = HOME / 'Library/Application Support/Wispr Flow/flow.sqlite'
PUBLIC_REPO = 'category271/whispernow-cleanup'
PUBLIC_REVISION = '8a54b7665decf3362593f72d28eb7691b4508c59'  # train 60,836 / val 2,424 / test 3,297
BASE_MODEL = 'category271/whispernow-lfm3-1.7b@34d7624c191379f40b63aa48b7d6bad3d7987f73'
EMPTY = 'EMPTY'
NESTED = (500, 750, 1000)

# Reuse v2's helpers (routing ports, spelling, snippet and style rules) so both builds agree.
_spec = importlib.util.spec_from_file_location('prep_v2', Path(__file__).with_name('prepare-wispr-cleanup-v2.py'))
v2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(v2)
words, squash, digest = v2.words, v2.squash, v2.digest

FILLERS = {'um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'hmm', 'ah', 'like', 'basically', 'literally', 'mm', 'mhm'}
FILLER_PHRASES = ('you know', 'i mean', 'sort of', 'kind of')
SOFT = {'so', 'just', 'really', 'actually', 'okay', 'ok', 'yeah', 'right', 'well', 'oh', 'anyway', 'and', 'but',
        'then', 'now', 'pretty', 'very', 'stuff', 'whatever'}
CUES = {'no', 'sorry', 'wait', 'actually', 'mean', 'rather', 'scratch', 'instead', 'correction', 'not'}
NEGATIONS = {'not', 'never', "don't", "doesn't", "didn't", "can't", 'cannot', "won't", "isn't", "aren't", "wasn't",
             "weren't", "shouldn't", "wouldn't", "couldn't", "haven't", "hasn't", 'nothing', 'none', 'without'}
# Words Wispr may add for grammar ("how much tokens" -> "how many tokens", "He not use" -> "He does not use").
GRAMMAR = v2.FUNCTION_WORDS | {'does', 'do', 'did', 'many', 'much', 'am', 'has', 'have', 'had', 'will', 'would', 'can',
                               'could', 'should', 'its', "it's", 'this', 'these', 'those', 'there', "there's", 'into',
                               'onto', 'i', "i'm", 'me', 'my', 'we', 'you', 'your', 'they', 'also', 'up'}
# Function words whose removal is grammar smoothing; words that can flip meaning (if, or, but, than,
# without, not, only, before, after) are deliberately absent.
DROPPABLE = {'a', 'an', 'the', 'and', 'so', 'to', 'of', 'in', 'on', 'at', 'for', 'is', 'are', 'was', 'were', 'be',
             'that', 'it', 'as', 'by', 'then', 'there', "it's", "that's", 'this'}
NOISE_ONLY = FILLERS | {'oh', 'hm', 'huh', 'ugh', 'ahh', 'mmm'}
SWEAR = re.compile(r'\b(fuck\w*|shit\w*|damn|bitch\w*|asshole|crap|bloody|wtf|retard\w*)\b', re.I)
LENGTH_BUCKETS = [(1, 7), (8, 15), (16, 30), (31, 60), (61, 150), (151, 10 ** 6)]
UNITS = {'zero': 0, 'oh': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8,
         'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
         'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'first': 1, 'second': 2, 'third': 3,
         'fourth': 4, 'fifth': 5, 'sixth': 6, 'seventh': 7, 'eighth': 8, 'ninth': 9, 'tenth': 10, 'eleventh': 11,
         'twelfth': 12, 'thirteenth': 13, 'fourteenth': 14, 'fifteenth': 15, 'sixteenth': 16, 'seventeenth': 17,
         'eighteenth': 18, 'nineteenth': 19, 'twentieth': 20, 'thirtieth': 30}
TENS = {'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90}
SCALES = {'hundred': 100, 'thousand': 1000, 'k': 1000, 'million': 10 ** 6, 'billion': 10 ** 9}
# Coverage targets per 750 curated rows (recipe table); scaled for other sizes. Tags overlap.
COVERAGE = {'short': 120, 'no_edit': 150, 'fillers': 120, 'self_correction': 80, 'number_negation': 100,
            'names_code': 100, 'list': 45, 'long': 60, 'swearing': 45, 'instruction': 80}
CHALLENGE_SLICES = ('url_path', 'list', 'number_time', 'self_correction', 'short', 'code_app')
# Public replay shares. The public no_edit rows are all CC BY 4.0, so the MIT-only default moves their
# share elsewhere; --allow-cc-by-no-edit uses the recipe's table and writes the attribution.
PUBLIC_QUOTA = {'fillers': 0.22, 'self_correction': 0.22, 'code_and_symbols': 0.15, 'literal_cue': 0.10, 'list': 0.05,
                'prose': 0.15, 'dictated_command': 0.06, 'empty': 0.05, 'no_edit': 0.0}
CC_BY_QUOTA = {'no_edit': 0.25, 'fillers': 0.17, 'self_correction': 0.20, 'code_and_symbols': 0.15, 'literal_cue': 0.10,
               'list': 0.05, 'prose': 0.05, 'empty': 0.03, 'dictated_command': 0.0}


def read_jsonl(path):
    with open(path, encoding='utf-8') as file:
        return [json.loads(line) for line in file if line.strip()]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as file:
        for chunk in iter(lambda: file.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def key(text):
    return ' '.join(words(text))


# ---------------------------------------------------------------------------
# Numbers: a number in the target must come from a value the speaker said.
def compose(run):
    """Values a run of number words can mean: each word, composed numbers, and paired readings (twenty thirty)."""
    out, parts, current, total = set(), [], 0, 0
    for token in run:
        if token in UNITS:
            value = UNITS[token]
            out.add(value)
            if current >= 20 and current % 10 == 0 and current < 100 and value < 10:
                current += value
            else:
                if current:
                    parts.append(current)
                current = value
        elif token in TENS:
            out.add(TENS[token])
            if current:
                parts.append(current)
            current = TENS[token]
        elif token in SCALES:
            current = (current or 1) * SCALES[token]
            total += current
            out.add(total)
            current = 0
    if current:
        parts.append(current)
    out.update(parts)
    if total:
        out.add(total + (parts[-1] if parts and parts[-1] < 1000 else 0))
    for a, b in zip(parts, parts[1:]):
        out.add(a * 100 + b)
    return out


def spoken_values(text):
    values = set()
    for match in re.findall(r'\d+(?:[.,:/]\d+)*', text or ''):
        values.update(int(p) for p in re.split(r'[.,:/]', match.replace(',', '')) if p)
        joined = re.sub(r'\D', '', match)
        if 0 < len(joined) < 12:
            values.add(int(joined))
    run = []
    for token in words(text) + ['<end>']:
        if token in UNITS or token in TENS or token in SCALES:
            run.append(token)
            continue
        if run:
            values |= compose(run)
            run = []
    return values


def invented_numbers(source, target):
    values = spoken_values(source)
    bad = []
    target = re.sub(r'(?m)^(\s*)\d+[.)]\s', r'\1', target or '')  # list numbering is layout, not a stated value
    for raw in re.findall(r'\d+(?:[.,:/]\d+)*(?:st|nd|rd|th|k|%)?', target or '', flags=re.I):
        core = re.sub(r'(st|nd|rd|th|k|%)$', '', raw, flags=re.I)
        parts = [int(p) for p in re.split(r'[.,:/]', core.replace(',', '')) if p.isdigit()]
        joined = re.sub(r'\D', '', core)
        if (joined and len(joined) < 12 and int(joined) in values) or (parts and all(p in values for p in parts)):
            continue
        bad.append(raw)
    return bad


def changed_identifiers(source, target):
    """Tokens mixing letters and digits (20AC, b11960, GPT4) that the speaker did not say."""
    said = {t.lower().strip('.') for t in re.findall(r"[\w.-]+", source or '')}
    said_joined = re.sub(r'[\s.-]', '', (source or '').lower())
    out = []
    for token in re.findall(r'\b(?=\w*\d)(?=\w*[A-Za-z])[\w.-]+\b', target or ''):
        low = token.lower().strip('.')
        if low in said or re.sub(r'[.-]', '', low) in said_joined or re.fullmatch(r'\d+(st|nd|rd|th|k|s|am|pm|x|d)', low):
            continue
        if spelled_out(low, source):
            continue
        out.append(token)
    return out


def spelled_out(identifier, source):
    """'1D' from "one d", 'W01' from "w zero one", 'L1' from "l one": every letter and number piece was spoken."""
    said, values = set(words(source)), spoken_values(source)
    for piece in re.findall(r'[a-z]+|\d+', identifier):
        if piece.isdigit():
            if int(piece) not in values:
                return False
        elif piece not in said and not all(ch in said for ch in piece):
            return False
    return True


# ---------------------------------------------------------------------------
def filler_positions(tokens):
    hits = {i for i, w in enumerate(tokens) if w in FILLERS}
    for phrase in FILLER_PHRASES:
        n = len(phrase.split())
        for i in range(len(tokens) - n + 1):
            if ' '.join(tokens[i:i + n]) == phrase:
                hits.update(range(i, i + n))
    return hits


NUMBERISH = set(UNITS) | set(TENS) | set(SCALES) | {'and', 'point', 'by', 'o', 'clock', "o'clock", 'percent', 'a'}


def is_equivalent_swap(gone, added):
    """A replace op that is a written-form change, not a content change: numbers, contractions, joins, spelling."""
    a, b = ' '.join(gone), ' '.join(added)
    if a.replace(' ', '') == b.replace(' ', '') or a.replace("'", '') == b.replace("'", ''):
        return True
    if all(g in NUMBERISH or g.isdigit() for g in gone) and all(re.fullmatch(r'[\d.,:/%]+\w{0,2}', x) or x == 'percent' for x in added):
        return True
    if any(set(added) <= v2.EXPANSIONS.get(g, set()) | {g} for g in gone):
        return True
    if len(gone) == len(added) == 1 and any(gone[0].startswith(br) and added[0].startswith(am) for br, am in v2.SPELLING):
        return True
    # Inflection or a cut-off word completed ("efficient" -> "efficiently", "prom" -> "prompt", "let" -> "letting").
    if len(added) == 1 and len(gone) <= 2 and any(same_stem(g, added[0]) for g in gone):
        return all(same_stem(g, added[0]) or g in DROPPABLE or g in FILLERS for g in gone)
    return False


def same_stem(a, b):
    if a == b:
        return True
    n = 0
    while n < min(len(a), len(b)) and a[n] == b[n]:
        n += 1
    if min(len(a), len(b)) >= 4 and (a.endswith(b) or b.endswith(a)):
        return True  # "remake" -> "make"
    return n >= 3 and n >= min(len(a), len(b)) - 1 or (n >= 4 and n >= 0.6 * max(len(a), len(b)))


def audit(source, target):
    """Explain every edit from source to target. Status: 'auto' (all edits explained), 'review', or 'reject'."""
    s, t = words(source), words(target)
    counts = {'filler': 0, 'repeat': 0, 'correction': 0, 'soft': 0, 'content': 0, 'equivalent': 0, 'grammar_add': 0}
    if target.strip() == EMPTY:
        noise = bool(s) and all(w in NOISE_ONLY for w in s)
        return {'status': 'auto' if noise else 'reject', 'flags': ['empty_target'], 'review': [],
                'reject': [] if noise else ['false_empty'], 'deletions': [], 'additions': [], 'numbers': [],
                'identifiers': [], **counts, 'similarity': 0.0, 'source_words': len(s)}
    fillers = filler_positions(s)
    flags, review, reject, deletions, additions = [], [], [], [], []
    ratio = difflib.SequenceMatcher(None, s, t, autojunk=False).ratio() if s and t else 0.0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, s, t, autojunk=False).get_opcodes():
        if op == 'equal':
            continue
        gone, added = s[i1:i2], t[j1:j2]
        if op == 'replace' and is_equivalent_swap(gone, added):
            counts['equivalent'] += 1
            continue
        for w in added:
            if w in s:
                continue  # moved word
            if w in GRAMMAR or w.isdigit() or re.fullmatch(r'[\d.,:/%]+\w{0,2}', w) \
                    or any(w == x + y for x, y in zip(s, s[1:])) or any(w in v2.EXPANSIONS.get(g, ()) for g in s):
                counts['grammar_add'] += 1
                continue
            additions.append(w)
        if not gone:
            continue
        after = s[i2:i2 + max(8, len(gone) + 4)]
        nearby = set(s[max(0, i1 - len(gone) - 12):i1]) | set(after)  # restarts repeat words said shortly before
        window = set(s[max(0, i1 - 3):i2 + 3])
        restart = gone[0] in after[:3] or all(w in after for w in gone)
        for k, w in enumerate(gone):
            i = i1 + k
            if i in fillers:
                reason = 'filler'
            elif w in nearby or restart:
                reason = 'repeat'
            elif window & CUES:
                reason = 'correction'
            elif w in SOFT or w in DROPPABLE:
                reason = 'soft'
            else:
                reason = 'content'
            counts[reason] += 1
            if w in NEGATIONS and reason not in ('repeat', 'filler'):
                review.append('negation_removed')
            deletions.append((i, w, reason))
    tail = [d for d in deletions if d[0] >= len(s) - 4 and d[2] in ('content', 'correction', 'soft')]
    if len([d for d in tail if d[2] == 'content']) >= 1 and len(tail) >= 2 and t[-1:] != s[-1:]:
        review.append('truncated_ending')
    if counts['content']:
        review.append('unexplained_deletion')
    if additions:
        review.append('unsupported_addition')
    if counts['grammar_add'] > 3:
        review.append('many_grammar_additions')
    if counts['soft'] > max(2, 0.03 * len(s)):
        review.append('many_soft_words_cut')
    elif counts['soft']:
        flags.append('soft_words_cut')
    if counts['correction']:
        flags.append('self_correction_resolved')  # still auto, but the sheet shows what was dropped
    numbers, identifiers = invented_numbers(source, target), changed_identifiers(source, target)
    if numbers:
        reject.append('invented_number')
    if identifiers:
        reject.append('changed_identifier')
    if len(s) < 2:
        reject.append('too_short')
    if ratio < 0.6 and len(s) > 3:
        reject.append('rewritten')
    if len(t) > 1.25 * len(s) + 3:
        reject.append('target_longer_than_speech')
    if re.search(r'</?[a-z]+>', target):
        reject.append('html_in_target')
    status = 'reject' if reject else ('review' if review else 'auto')
    return {'status': status, 'flags': sorted(set(flags)), 'review': sorted(set(review)), 'reject': sorted(set(reject)),
            'deletions': [(w, r) for _, w, r in deletions], 'additions': additions, 'numbers': numbers,
            'identifiers': identifiers, **counts, 'similarity': round(ratio, 4), 'source_words': len(s)}


def quality_score(a):
    """Ranking inside a coverage tag: real cleanup, few soft cuts, small rewrites."""
    if a['status'] == 'reject':
        return -9.0
    cleanup = a['filler'] + a['repeat'] + a['correction']
    return round(1.0 + 0.8 * min(1.0, cleanup / 2) + 0.2 * (a['correction'] > 0) - 0.25 * a['soft']
                 - 1.0 * a['content'] - 0.5 * len(a['additions']) - 2.0 * max(0.0, 0.9 - a['similarity'])
                 - 0.3 * (a['status'] == 'review'), 4)


# ---------------------------------------------------------------------------
def app_class(bundle):
    b = (bundle or '').lower()
    if v2.is_code_app(bundle):
        return 'code'
    if bundle in v2.PERSONAL:
        return 'chat'
    if bundle in v2.WORK:
        return 'work'
    if bundle in v2.EMAIL or 'mail' in b:
        return 'email'
    if any(x in b for x in ('chrome', 'safari', 'firefox', 'company.thebrowser', 'brave')):
        return 'browser'
    if any(x in b for x in ('claude', 'codex', 'openai', 'chatgpt', 't3', 'hermes', 'anysphere', 'perplexity')):
        return 'ai_agent'
    return 'other'


def tags_for(source, target, bundle, a):
    s = words(source)
    numberish = (set(UNITS) - {'first', 'second', 'one'}) | set(TENS) | set(SCALES)
    tags = set()
    if len(s) <= 10:
        tags.add('short')
    if len(s) <= 5:
        tags.add('very_short')
    if len(s) > 150:
        tags.add('long')
    if a['filler'] + a['content'] + a['repeat'] + a['correction'] + a['soft'] == 0 and not a['additions']:
        tags.add('no_edit')
    if a['filler'] + a['repeat'] > 0:
        tags.add('fillers')
    if a['correction'] > 0 or re.search(r"\b(no wait|wait no|or rather|scratch that|no actually|sorry i mean)\b", source, re.I):
        tags.add('self_correction')
    if re.search(r'\d', source + target) or set(s) & numberish or set(s) & NEGATIONS:
        tags.add('number_negation')
    if re.search(r'\d', source + target) or set(s) & numberish or re.search(
            r"\b\d{1,2}(:\d{2})?\s?(am|pm)\b|\bo'clock\b|\b(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|"
            r"friday|saturday|sunday)\b", source, re.I):
        tags.add('number_time')
    if re.search(r'https?://|www\.|\b\w+\.(com|io|ai|app|dev|org|net|nl|md|py|json|swift|ts|js)\b|[/~]\w+/|\bslash\b'
                 r'|\bdot com\b|--\w|\bdash dash\b', source + ' ' + target, re.I):
        tags.add('url_path')
    if re.search(r'[a-z][A-Z]|\b[A-Z]{2,}\b|\w_\w|`', target) or 'url_path' in tags:
        tags.add('names_code')
    if re.search(r'(?m)^\s*(?:[-*•]|\d+[.)])\s+', target):
        tags.add('list')
    if SWEAR.search(source):
        tags.add('swearing')
    if '?' in target or re.search(r"\b(can you|could you|please|make sure|i want you to|let's|go ahead)\b", source, re.I):
        tags.add('instruction')
    if app_class(bundle) == 'code':
        tags.add('code_app')
    return sorted(tags)


# ---------------------------------------------------------------------------
def read_db(database):
    uri = database.expanduser().absolute().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only=ON')
        columns = {r['name'] for r in connection.execute('PRAGMA table_info(History)')}
        fields = [f for f in list(v2.FIELDS) + ['pastedText', 'serverFinalizedText'] if f in columns]
        return [dict(r) for r in connection.execute('SELECT %s FROM History' % ','.join('"%s"' % f for f in fields))]


def load_flow_inputs(paths):
    """Wispr id -> Flow's pre-cleanup text: `formatted` from Flow --cleanup-prepare, or shadow-pairs.jsonl."""
    found, routes = {}, {}
    for path in paths:
        for item in read_jsonl(path):
            if 'wispr_id' in item:  # shadow pairs: Flow's live capture
                text = item.get('flow_formatted') or item.get('flow_input')
                if item.get('usable') and text:
                    found[item['wispr_id']] = {'text': text, 'source': 'flow:shadow', 'route': item.get('route', 's1'),
                                               'raw': item.get('parakeet_raw')}
                continue
            if item.get('status') != 'ok':
                continue
            route = item.get('route') or 's1'
            routes[route] = routes.get(route, 0) + 1
            text = item.get('formatted') or ''
            found[item['id']] = {'text': text, 'source': 'flow:formatted' if text.strip() else 'flow:empty',
                                 'route': route, 'raw': item.get('parakeet_raw')}
    return found, routes


def normalise_target(text, source, bundle, profile):
    """Undo what Flow does after cleanup (American spelling, very-casual formatter), as v2 does."""
    target = v2.keep_input_spelling(source, v2.html_to_plain((text or '').strip()))
    if target and v2.flow_style(bundle, profile) == 'veryCasual':
        target = v2.decasualize(target)
    return target


def choose_target(row, source, profile, snippets):
    """Model-stage target from formattedText / pastedText / editedText; every disagreement is flagged."""
    bundle = row.get('app')
    formatted = normalise_target(row.get('formattedText'), source, bundle, profile)
    pasted_raw = (row.get('pastedText') or '').strip()
    pasted = normalise_target(pasted_raw, source, bundle, profile) if pasted_raw else ''
    spoken = ' %s ' % ' '.join(words(source))
    flags, review = [], []
    target, origin = formatted, 'formatted'
    if pasted and squash(pasted) != squash(formatted):
        fw, pw = words(formatted), words(pasted)
        expanded = any(sn in pasted.lower() and ' %s ' % ' '.join(words(sn)) not in spoken for sn in snippets)
        if fw == pw:
            flags.append('paste_differs_case_punct')  # formatted kept; shown in the sheet
        elif expanded:
            flags.append('paste_has_snippet_expansion')  # replacements belong to Flow, not the model
        elif len(pw) > len(fw) and (pw[:len(fw)] == fw or set(fw) <= set(pw)):
            target, origin = pasted, 'pasted'
            review.append('formatted_truncated_used_paste')
        else:
            review.append('paste_differs_words')
    edited, kind = v2.choose_target(row.get('formattedText') or '', row.get('editedText') or '')
    edited_norm = normalise_target(edited, source, bundle, profile) if kind == 'edited' else ''
    if edited_norm:
        review.append('user_edit_available')  # reviewer decides; the target stays Wispr's unless fixed
    return target, origin, flags, review, {'formatted': formatted, 'pasted': pasted, 'edited': edited_norm}


def eligible(row, profile, snippets):
    """v2's row-level rules (status, language, command mode, tone match, style mapping). A drop reason or None."""
    if not row.get('transcriptEntityId') or not row.get('timestamp'):
        return 'no_id_or_time'
    if (row.get('status') or '') != 'formatted':
        return 'not_formatted'
    if row.get('hasRevertedAI') or row.get('usedFallbackAsr') or row.get('usedFallbackFormatting'):
        return 'reverted_or_fallback'
    if (row.get('transcriptCommand') or '') not in ('', 'popo', 'ptt'):
        return 'command_or_instruct_mode'
    if squash(row.get('toneMatchedText')):
        return 'tone_matched'
    asr, formatted = (row.get('asrText') or '').strip(), (row.get('formattedText') or '').strip()
    if not asr or not formatted:
        return 'empty_text'
    if (row.get('detectedLanguage') or '') != 'en' or v2.looks_dutch(asr) or v2.looks_dutch(formatted):
        return 'not_english'
    spoken = ' %s ' % ' '.join(words(asr))
    if any(sn in v2.html_to_plain(formatted).lower() and ' %s ' % ' '.join(words(sn)) not in spoken for sn in snippets):
        return 'snippet_or_replacement_expanded'
    style = v2.row_wispr_style(row)
    if style is None:
        return 'no_wispr_style_recorded'
    if style != v2.flow_style(row.get('app'), profile):
        return 'wispr_style_differs_from_flow_mapping'
    return None


# ---------------------------------------------------------------------------
def order_candidates(pool, cap, seed):
    """One deterministic ordering whose prefixes are the nested sets: 60% representative, 40% coverage.

    Representative picks go round-robin over (month, app class, length bucket) strata in hash order.
    Coverage picks take the tag with the largest deficit against COVERAGE (scaled to the prefix length)
    and its best-scored row. Rows that still need review stay in the ordering (the sheet shows them);
    the train files skip them until approved, so the next eligible row fills in.
    """
    strata = {}
    for r in pool:
        bucket = next(i for i, (lo, hi) in enumerate(LENGTH_BUCKETS) if lo <= max(1, len(words(r['input']))) <= hi)
        strata.setdefault((r['timestamp'][:7], r['app_class'], bucket), []).append(r)
    for rows in strata.values():
        rows.sort(key=lambda r: digest('%s:%s' % (seed, r['id'])))
    rep_queue, depth = [], 0
    while len(rep_queue) < len(pool):
        layer = [strata[k][depth] for k in sorted(strata) if depth < len(strata[k])]
        if not layer:
            break
        rep_queue += layer
        depth += 1
    by_tag = {t: sorted([r for r in pool if t in r['tags'] and r['audit']['status'] != 'reject'],
                        key=lambda r: (-r['score'], digest('%s:%s' % (seed, r['id'])))) for t in COVERAGE}
    picked, seen, counts, coverage_n, rep_i = [], set(), {t: 0 for t in COVERAGE}, 0, 0
    while len(picked) < min(cap, len(pool)):
        k = len(picked) + 1
        choice = None
        if coverage_n < round(0.4 * k):
            scale = k / 750
            for t in sorted(COVERAGE, key=lambda t: counts[t] / (COVERAGE[t] * scale)):
                choice = next((r for r in by_tag[t] if r['id'] not in seen), None)
                if choice:
                    coverage_n += 1
                    break
        if choice is None:
            while rep_i < len(rep_queue) and (rep_queue[rep_i]['id'] in seen or rep_queue[rep_i]['audit']['status'] == 'reject'):
                rep_i += 1
            if rep_i >= len(rep_queue):
                break
            choice = rep_queue[rep_i]
        seen.add(choice['id'])
        picked.append(choice)
        for t in choice['tags']:
            if t in counts:
                counts[t] += 1
    return picked


def load_approvals(path):
    decisions = {}
    if not path:
        return decisions
    with open(path, newline='', encoding='utf-8') as file:
        for row in csv.DictReader(file):
            decision = (row.get('decision') or '').strip().lower()
            if decision in ('approve', 'reject', 'fix'):
                decisions[row['id']] = {'decision': decision, 'fixed_target': (row.get('fixed_target') or '').strip()}
    return decisions


# ---------------------------------------------------------------------------
def public_ok(row, max_words, quota, allow_cc_by):
    category = row.get('category')
    licensed = row.get('license') == 'MIT' or (allow_cc_by and category == 'no_edit' and row.get('license') == 'CC-BY-4.0')
    if not licensed or row.get('source') in ('heard', 'ami') or not quota.get(category):
        return False
    source, target = row.get('input') or '', row.get('output') or ''
    n = len(words(source))
    if not (3 <= n <= max_words) or not target.strip():
        return False
    if category == 'empty':
        return target.strip() == EMPTY
    if target.strip() == EMPTY or row.get('layout') not in (('plain', 'list') if category == 'list' else ('plain',)):
        return False
    a = audit(source, target)  # the same audit as personal rows
    return a['status'] != 'reject' and not a['additions'] and a['content'] == 0 and 'negation_removed' not in a['review']


def ngram_hashes(text, n=8):
    w = words(text)
    return {hash(' '.join(w[i:i + n])) for i in range(len(w) - n + 1)}


def sample_public(pool_size, valid_size, max_words, seed, scan_limit, allow_cc_by, personal_grams):
    try:
        from datasets import load_dataset
    except ImportError:
        raise SystemExit('The public mix needs the datasets library: run with `uv run --with datasets==5.2.0 python3 ...`, '
                         'or pass --no-public / --public-pool FILE.')
    quota = CC_BY_QUOTA if allow_cc_by else PUBLIC_QUOTA
    print('Public rows: reading %s@%s (streaming)' % (PUBLIC_REPO, PUBLIC_REVISION[:10]), file=sys.stderr)
    test_keys, test_grams = set(), set()
    for row in load_dataset(PUBLIC_REPO, split='test', streaming=True, revision=PUBLIC_REVISION):
        test_keys.add(key(row['input']))
        test_grams |= ngram_hashes(row['input'])
    blocked = test_grams | personal_grams

    def clean(row):
        return key(row['input']) not in test_keys and not (ngram_hashes(row['input']) & blocked)

    want = {c: round(pool_size * q) for c, q in quota.items() if q}
    per_cat, scanned, overlap = {c: [] for c in want}, 0, 0
    for row in load_dataset(PUBLIC_REPO, split='train', streaming=True, revision=PUBLIC_REVISION).shuffle(seed=seed, buffer_size=5000):
        scanned += 1
        if scanned > scan_limit or all(len(per_cat[c]) >= want[c] for c in want):
            break
        c = row.get('category')
        if c in want and len(per_cat[c]) < want[c] and public_ok(row, max_words, quota, allow_cc_by):
            if clean(row):
                per_cat[c].append(row)
            else:
                overlap += 1
    print('Public pool per category (have/want):', {c: '%d/%d' % (len(per_cat[c]), want[c]) for c in want},
          'scanned', scanned, file=sys.stderr)
    # Interleave by quota so every prefix of the pool keeps roughly the target category mix.
    pool, used = [], {c: 0 for c in want}
    while any(used[c] < len(per_cat[c]) for c in want):
        c = min((c for c in want if used[c] < len(per_cat[c])), key=lambda c: (used[c] + 1) / want[c])
        pool.append(per_cat[c][used[c]])
        used[c] += 1
    valid = []
    for row in load_dataset(PUBLIC_REPO, split='val', streaming=True, revision=PUBLIC_REVISION).shuffle(seed=seed, buffer_size=2500):
        if len(valid) >= valid_size:
            break
        if row.get('category') in want and public_ok(row, max_words, quota, allow_cc_by) and clean(row):
            valid.append(row)
    keep = ('id', 'input', 'output', 'category', 'source', 'license', 'layout')
    return ([{k: r.get(k) for k in keep} for r in pool], [{k: r.get(k) for k in keep} for r in valid],
            {'scanned_train_rows': scanned, 'rejected_overlap': overlap})


def chat(row_id, origin, input_source, transcript, target, **extra):
    return {'id': row_id, 'origin': origin, 'input_source': input_source, **extra,
            'messages': [{'role': 'user', 'content': transcript.strip()}, {'role': 'assistant', 'content': target}]}


def public_chat(row):
    return chat('public:' + row['id'], 'public', 'public:' + (row.get('source') or ''), row['input'], row['output'],
                license=row.get('license'), category=row.get('category'))


def mix(personal, pool, fraction, token_cap, seed):
    """Add public rows up to `fraction` of rows while public reply words stay under `token_cap` of all reply words."""
    if fraction <= 0 or not pool:
        return list(personal), 0
    want = round(len(personal) * fraction / (1 - fraction))
    personal_words = sum(len(r['messages'][1]['content'].split()) for r in personal)
    limit = token_cap / (1 - token_cap) * personal_words
    chosen, public_words = [], 0
    for row in pool:
        if len(chosen) >= want:
            break
        n = len(row['output'].split())
        if public_words + n > limit:
            continue
        chosen.append(row)
        public_words += n
    rows = list(personal) + [public_chat(r) for r in chosen]
    random.Random(seed).shuffle(rows)
    return rows, len(chosen)


# ---------------------------------------------------------------------------
def review_sheet(rows, path_csv, path_html):
    fields = ['rank', 'set', 'id', 'status', 'needs_review', 'reject', 'flags', 'app', 'input_source', 'tags', 'input',
              'target', 'target_origin', 'wispr_formatted_if_different', 'wispr_pasted_if_different', 'user_edit',
              'deleted_words', 'added_words', 'decision', 'fixed_target']
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=fields)
    writer.writeheader()
    differs = lambda text, target: text if text and squash(text) != squash(target) else ''
    for r in rows:
        a = r['audit']
        writer.writerow({
            'rank': r.get('rank', ''), 'set': r['set'], 'id': r['id'], 'status': a['status'],
            'needs_review': ' '.join(a['review']), 'reject': ' '.join(a['reject']), 'flags': ' '.join(a['flags']),
            'app': r.get('bundle_id') or '', 'input_source': r['input_source'], 'tags': ' '.join(r['tags']),
            'input': r['input'], 'target': r['target'], 'target_origin': r['target_origin'],
            'wispr_formatted_if_different': differs(r['candidates']['formatted'], r['target']),
            'wispr_pasted_if_different': differs(r['candidates']['pasted'], r['target']),
            'user_edit': r['candidates']['edited'],
            'deleted_words': '; '.join('%s (%s)' % (w, why) for w, why in a['deletions']),
            'added_words': ' '.join(a['additions'] + ['#' + n for n in a['numbers']] + ['@' + i for i in a['identifiers']]),
            'decision': r.get('decision', ''), 'fixed_target': r.get('fixed_target', '')})
    v2.write_private(path_csv, buffer.getvalue())

    def marked(r):
        reasons = {}
        for w, why in r['audit']['deletions']:
            reasons.setdefault(w, why)
        kept = set(words(r['target']))
        out = []
        for token in r['input'].split():
            w = (words(token) or [''])[0]
            if w and w not in kept and w in reasons:
                out.append('<del class="%s" title="%s">%s</del>' % ('bad' if reasons[w] == 'content' else 'ok', reasons[w],
                                                                    html.escape(token)))
            else:
                out.append(html.escape(token))
        return ' '.join(out)

    body = []
    for r in rows:
        a = r['audit']
        extra = ''
        for label, text in (('Wispr pasted', differs(r['candidates']['pasted'], r['target'])),
                            ('Wispr formatted', differs(r['candidates']['formatted'], r['target'])),
                            ('Your edit', r['candidates']['edited'])):
            if text:
                extra += '<div class="alt"><b>%s:</b> %s</div>' % (label, html.escape(text))
        notes = a['review'] + a['reject'] + a['flags'] + ['+' + x for x in a['additions']]
        body.append('<tr class="%s"><td>%s<br><small>%s</small></td><td>%s<br><small>%s<br>%s</small></td>'
                    '<td><div>%s</div><div class="tgt">%s</div>%s</td><td>%s</td></tr>' % (
                        a['status'], r.get('rank', ''), html.escape(r['set']), html.escape(a['status']),
                        html.escape(r.get('app_class', '')), html.escape(' '.join(r['tags'])), marked(r),
                        html.escape(r['target']), extra, html.escape(' '.join(notes))))
    page = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Cleanup review</title><style>'
            ':root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--bad:#c62828;--ok:#8e8e93;--rev:#fff7e0;--rej:#fdecea}'
            '@media (prefers-color-scheme:dark){:root{--bg:#161617;--fg:#f5f5f7;--muted:#a1a1a6;--line:#2c2c2e;--bad:#ff6b6b;'
            '--ok:#8e8e93;--rev:#3a3018;--rej:#3d1f1f}}'
            'body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:16px}'
            'table{border-collapse:collapse;width:100%}td{border-bottom:1px solid var(--line);padding:8px;vertical-align:top}'
            'td:first-child{width:5em}td:nth-child(2){width:9em}td:last-child{width:14em;color:var(--muted);font-size:12px}'
            'small{color:var(--muted)}.tgt{margin-top:6px;font-weight:500}.alt{margin-top:4px;color:var(--muted);font-size:13px}'
            'del.bad{color:var(--bad);text-decoration:line-through 2px}del.ok{color:var(--ok)}'
            'tr.review{background:var(--rev)}tr.reject{background:var(--rej)}'
            '</style><h1>Cleanup review</h1><p><small>Top line: what you said (struck words are removed; red means no reason '
            'was found). Bold line: the training target. Decide in review.csv: approve, reject, or fix plus fixed_target. '
            'Yellow rows need a decision before they can train; red rows are excluded.</small></p><table>'
            + ''.join(body) + '</table>')
    v2.write_private(path_html, page)


# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--v2-dir', type=Path, default=V2_DIR)
    p.add_argument('--reference-db', type=Path, default=DEFAULT_DB, help="Wispr's flow.sqlite, opened read-only")
    p.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    p.add_argument('--flow-inputs', type=Path, nargs='*', default=[],
                   help='Flow --cleanup-prepare JSONL (uses `formatted`) and/or shadow-pairs.jsonl, keyed by Wispr id')
    p.add_argument('--approvals', type=Path, help='review.csv with decision = approve / reject / fix (+ fixed_target)')
    p.add_argument('--refreeze', action='store_true', help='rebuild frozen-ids.json (not needed for normal rebuilds)')
    p.add_argument('--challenge-per-slice', type=int, default=20)
    p.add_argument('--sheet-extra', type=int, default=300, help='candidates beyond 1,000 shown in the sheet as fill-ins')
    p.add_argument('--public-fraction', type=float, default=0.15)
    p.add_argument('--public-token-cap', type=float, default=0.20, help='max public share of reply words')
    p.add_argument('--public-pool-size', type=int, default=400)
    p.add_argument('--public-valid', type=int, default=200)
    p.add_argument('--public-max-words', type=int, default=150)
    p.add_argument('--public-scan-limit', type=int, default=70000)
    p.add_argument('--public-pool', type=Path, help='reuse a public-pool.jsonl (+ valid-public.jsonl beside it)')
    p.add_argument('--no-public', action='store_true')
    p.add_argument('--allow-cc-by-no-edit', action='store_true', help='also use CC BY 4.0 no_edit rows (attribution written)')
    p.add_argument('--seed', type=int, default=109)
    p.add_argument('--write', action='store_true')
    args = p.parse_args()
    if not 0 <= args.public_fraction < 0.5:
        raise SystemExit('--public-fraction must be in [0, 0.5)')

    profile = v2.load_json(v2.PROFILE, {})
    snippets = v2.snippet_texts()
    rows = read_db(args.reference_db)
    by_id = {r['transcriptEntityId']: r for r in rows if r.get('transcriptEntityId')}
    flow, flow_routes = load_flow_inputs(args.flow_inputs)
    approvals = load_approvals(args.approvals)
    frozen_path = args.output / 'frozen-ids.json'

    # ---- frozen held-out ids: the v2 test (253) and valid (171) rows ----
    if frozen_path.exists() and not args.refreeze:
        frozen = json.loads(frozen_path.read_text())
    else:
        asr_index = {}
        for r in rows:
            asr_index.setdefault(key(r.get('asrText') or ''), []).append(r)
        valid_ids = []
        for line in read_jsonl(args.v2_dir / 'valid.jsonl'):
            user = line['messages'][1]['content']
            found = asr_index.get(key(user.split('\n', 1)[1] if user.startswith('[Styling') else user), [])
            match = next((r for r in found if r.get('formattedText')), found[0] if found else None)
            if match:
                valid_ids.append(match['transcriptEntityId'])
        frozen = {'frozen_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                  'from_v2_built_at': json.loads((args.v2_dir / 'summary.json').read_text()).get('built_at'),
                  'test': [m['id'] for m in read_jsonl(args.v2_dir / 'test.meta.jsonl')], 'valid': valid_ids,
                  'challenge': {}}
    held = set(frozen['test']) | set(frozen['valid'])
    test_cutoff = min(v2.parse_time(by_id[i]['timestamp']) for i in frozen['test'] if i in by_id)

    # ---- personal pool: every eligible row, audited ----
    dropped, pool = {}, []

    def drop(reason):
        dropped[reason] = dropped.get(reason, 0) + 1

    for row in rows:
        rid = row.get('transcriptEntityId')
        reason = eligible(row, profile, snippets)
        if reason:
            if rid not in held:
                drop(reason)
            continue
        info = flow.get(rid)
        if info and info['text'].strip():
            source, input_source = info['text'], info['source']
        else:
            source, input_source = (row.get('asrText') or '').strip(), 'wispr_asr'
        target, origin, t_flags, t_review, candidates = choose_target(row, source, profile, snippets)
        a = audit(source, target)
        a['flags'] = sorted(set(a['flags'] + t_flags + (['no_flow_input'] if input_source == 'wispr_asr' else [])
                                + (['code_app_bypassed_in_flow'] if v2.is_code_app(row.get('app')) else [])))
        a['review'] = sorted(set(a['review'] + t_review))
        if info and info['route'] not in ('s1', 'skip:code-context'):
            a['reject'] = sorted(set(a['reject'] + ['flow_routes_around_cleanup:' + info['route']]))
        a['status'] = 'reject' if a['reject'] else ('review' if a['review'] else 'auto')
        decision = approvals.get(rid)
        if decision:
            if decision['decision'] == 'reject':
                a['status'], a['reject'] = 'reject', a['reject'] + ['reviewer_rejected']
            elif decision['decision'] == 'fix' and decision['fixed_target']:
                target, origin = decision['fixed_target'], 'reviewer_fix'
                fixed = audit(source, target)
                fixed['flags'] = sorted(set(fixed['flags'] + a['flags'] + ['reviewer_fix']))
                fixed['status'] = 'reject' if fixed['reject'] else 'approved'
                a = fixed
            elif decision['decision'] == 'approve' and a['status'] != 'reject':
                a['status'] = 'approved'
        entry = {'id': rid, 'timestamp': row['timestamp'], 'ts': v2.parse_time(row['timestamp']),
                 'bundle_id': row.get('app'), 'app_class': app_class(row.get('app')), 'input': source,
                 'input_source': input_source, 'target': target, 'target_origin': origin, 'candidates': candidates,
                 'audit': a, 'decision': (decision or {}).get('decision', ''),
                 'fixed_target': (decision or {}).get('fixed_target', '')}
        entry['tags'] = tags_for(source, target, row.get('app'), a)
        entry['score'] = quality_score(a)
        pool.append(entry)
    entries = {e['id']: e for e in pool}
    train_pool = [e for e in pool if e['id'] not in held and e['ts'] < test_cutoff]
    newer_unused = sum(1 for e in pool if e['id'] not in held and e['ts'] >= test_cutoff)

    # ---- challenge slices (frozen on the first build; never trained) ----
    if not frozen.get('challenge'):
        chosen, taken = {}, set()
        for name in CHALLENGE_SLICES:
            tag = 'very_short' if name == 'short' else name
            ranked = sorted([e for e in train_pool if tag in e['tags'] and e['audit']['status'] != 'reject' and e['id'] not in taken],
                            key=lambda e: digest('challenge:%s:%s' % (args.seed, e['id'])))
            chosen[name] = [e['id'] for e in ranked[:args.challenge_per_slice]]
            taken.update(chosen[name])
        frozen['challenge'] = chosen
    challenge_ids = {i for ids in frozen['challenge'].values() for i in ids}
    held_all = held | challenge_ids
    held_keys = {key(entries[i]['input']) for i in held_all if i in entries}
    held_grams = [g for g in (v2.shingles(entries[i]['input']) for i in held_all if i in entries) if g]
    train_candidates, seen_keys = [], set()
    for e in sorted(train_pool, key=lambda e: ({'approved': 0, 'auto': 1, 'review': 2, 'reject': 3}[e['audit']['status']], -e['ts'])):
        if e['id'] in challenge_ids:
            continue
        k = key(e['input'])
        if k in held_keys:
            drop('duplicate_of_held_out'); continue
        if k in seen_keys:
            drop('duplicate'); continue
        mine = v2.shingles(e['input'])
        if mine and any(len(mine & other) / len(mine | other) >= 0.6 for other in held_grams):
            drop('near_duplicate_of_held_out'); continue
        seen_keys.add(k)
        train_candidates.append(e)

    # ---- EMPTY targets: Flow heard only noise where Wispr pasted nothing ----
    empties = []
    for rid, info in flow.items():
        wrow = by_id.get(rid)
        text = info.get('raw') or info['text']
        if wrow is None or rid in held_all or not text.strip() or (wrow.get('formattedText') or '').strip():
            continue
        if words(text) and all(t in NOISE_ONLY for t in words(text)):
            empties.append(chat(rid, 'personal', info['source'], text, EMPTY))

    # ---- nested curated sets + full set ----
    ordering = order_candidates(train_candidates, NESTED[-1] + args.sheet_extra, args.seed)
    for rank, e in enumerate(ordering, 1):
        e['rank'] = rank
    trainable = lambda e: e['audit']['status'] in ('auto', 'approved')
    usable = [e for e in ordering if trainable(e)]
    nested = {n: usable[:n] for n in NESTED}
    full = [e for e in train_candidates if trainable(e)]
    to_chat = lambda e: chat(e['id'], 'personal', e['input_source'], e['input'], e['target'])

    # ---- valid (chronological tune/select split), legacy test, challenge ----
    valid = sorted([entries[i] for i in frozen['valid'] if i in entries], key=lambda e: e['ts'])
    valid = [e for e in valid if e['audit']['status'] != 'reject']
    half = len(valid) * 53 // 100
    valid_tune, valid_select = valid[:half], valid[half:]
    v2_test, v2_meta = read_jsonl(args.v2_dir / 'test.jsonl'), read_jsonl(args.v2_dir / 'test.meta.jsonl')
    if [m['id'] for m in v2_meta] != frozen['test']:
        raise SystemExit('v2 test.meta.jsonl no longer matches frozen-ids.json; the legacy test moved. Stop and check.')
    test_rows, test_meta = [], []
    for line, meta in zip(v2_test, v2_meta):
        user, target = line['messages'][1]['content'], line['messages'][2]['content']
        wispr_input = user.split('\n', 1)[1] if user.startswith('[Styling') else user
        info, e = flow.get(meta['id']), entries.get(meta['id'])
        reference = audit(wispr_input, target)
        test_rows.append(chat(meta['id'], 'personal', 'wispr_asr', wispr_input, target))
        test_meta.append({**meta, 'wispr_input': wispr_input, 'target': target,
                          'flow_input': info['text'] if info and info['text'].strip() else None,
                          'flow_route': info['route'] if info else None,
                          'wispr_pasted': e['candidates']['pasted'] if e else None,
                          'target_status': reference['status'],
                          'target_review': sorted(set(reference['review'] + reference['reject'] + (e['audit']['review'] if e else []))),
                          'phenomena': e['tags'] if e else []})
    challenge_rows, challenge_meta = [], []
    for name, ids in frozen['challenge'].items():
        for i in ids:
            e = entries.get(i)
            if e:
                challenge_rows.append(chat(i, 'personal', e['input_source'], e['input'], e['target'], slice=name))
                challenge_meta.append({'id': i, 'slice': name, 'bundle_id': e['bundle_id'], 'tags': e['tags'],
                                       'wispr_input': (by_id[i].get('asrText') or '').strip(), 'target': e['target'],
                                       'flow_input': e['input'] if e['input_source'].startswith('flow') else None,
                                       'target_status': e['audit']['status'],
                                       'target_review': e['audit']['review'] + e['audit']['reject']})

    # ---- public rows ----
    pool_rows, public_valid, public_stats = [], [], {}
    if args.public_pool:
        pool_rows = read_jsonl(args.public_pool)
        sibling = args.public_pool.with_name('valid-public.jsonl')
        public_valid = [{'id': r['id'].split(':', 1)[1], 'input': r['messages'][0]['content'], 'output': r['messages'][1]['content'],
                         'category': r.get('category'), 'license': r.get('license'), 'source': r['input_source'].split(':', 1)[1]}
                        for r in read_jsonl(sibling)] if sibling.exists() else []
        public_stats = {'reused_pool': str(args.public_pool)}
    elif not args.no_public and args.public_fraction > 0:
        personal_grams = set()
        for e in pool:
            personal_grams |= ngram_hashes(e['input'])
        pool_rows, public_valid, public_stats = sample_public(args.public_pool_size, args.public_valid, args.public_max_words,
                                                              args.seed, args.public_scan_limit, args.allow_cc_by_no_edit,
                                                              personal_grams)
    cc_by = [r for r in pool_rows + public_valid if r.get('license') != 'MIT']
    if any(r.get('license') != 'CC-BY-4.0' or r.get('category') != 'no_edit' for r in cc_by) or (cc_by and not args.allow_cc_by_no_edit):
        raise SystemExit('Public pool holds rows outside the allowed licenses; refusing.')
    fraction = 0 if args.no_public else args.public_fraction
    train_files, mixed = {}, {}
    for n, chosen_rows in nested.items():
        personal = [to_chat(e) for e in chosen_rows] + empties
        train_files['train-curated-%d.jsonl' % n] = personal
        train_files['train-curated-%d-mix.jsonl' % n], mixed[n] = mix(personal, pool_rows, fraction, args.public_token_cap, args.seed)
    full_chat = [to_chat(e) for e in full] + empties
    train_files['train-full.jsonl'] = full_chat
    train_files['train-full-mix.jsonl'], mixed['full'] = mix(full_chat, pool_rows, fraction, args.public_token_cap, args.seed)

    # ---- summary ----
    status_count = lambda es: {s: sum(e['audit']['status'] == s for e in es) for s in ('auto', 'approved', 'review', 'reject')}
    tag_names = sorted(set(COVERAGE) | {'code_app', 'url_path', 'number_time', 'very_short'})
    tag_count = lambda es: {t: sum(t in e['tags'] for e in es) for t in tag_names}
    reasons = {}
    for e in train_candidates:
        for r in e['audit']['review'] + e['audit']['reject']:
            reasons[r] = reasons.get(r, 0) + 1
    sources = {}
    for e in train_candidates + valid:
        sources[e['input_source']] = sources.get(e['input_source'], 0) + 1
    phenomena = {}
    for m in test_meta:
        for t in m['phenomena']:
            phenomena[t] = phenomena.get(t, 0) + 1
    summary = {
        'built_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
        'format': 'whispernow: one user turn = trimmed transcript, no system prompt; reply = cleaned text or EMPTY',
        'base_model': BASE_MODEL,
        'production_exact_inputs': bool(sources) and all(s.startswith('flow:') for s in sources),
        'input_source': sources, 'flow_inputs_files': [str(x) for x in args.flow_inputs], 'flow_routes': flow_routes,
        'reviewed': {'approvals_file': str(args.approvals) if args.approvals else None,
                     'approved_rows': sum(e['audit']['status'] == 'approved' for e in pool),
                     'curated_750_all_approved': all(e['audit']['status'] == 'approved' for e in nested[750]) and bool(nested[750])},
        'sizes': {**{'train_curated_%d' % n: len(train_files['train-curated-%d.jsonl' % n]) for n in NESTED},
                  **{'train_curated_%d_mix' % n: len(train_files['train-curated-%d-mix.jsonl' % n]) for n in NESTED},
                  'public_rows_in_mix': mixed, 'train_full': len(full_chat), 'train_full_mix': len(train_files['train-full-mix.jsonl']),
                  'valid_tune': len(valid_tune), 'valid_select': len(valid_select), 'valid_public': len(public_valid),
                  'test': len(test_rows), 'challenge': len(challenge_rows), 'empty_targets': len(empties),
                  'public_pool': len(pool_rows), 'review_sheet_rows': len(ordering) + len(challenge_rows)},
        'train_pool': {'candidates': len(train_candidates), 'status': status_count(train_candidates),
                       'review_and_reject_reasons': dict(sorted(reasons.items(), key=lambda x: -x[1])),
                       'eligible_rows_newer_than_test_window_unused': newer_unused},
        'curated_1000_ordering': {'status': status_count(ordering[:NESTED[-1]]), 'tags': tag_count(ordering[:NESTED[-1]])},
        'curated_750_trainable_tags': tag_count(nested[750]), 'full_tags': tag_count(full),
        'test': {'rows': len(test_rows), 'with_flow_input': sum(bool(m['flow_input']) for m in test_meta),
                 'targets_flagged_by_audit': sum(bool(m['target_review']) for m in test_meta),
                 'targets_rejected_by_audit': sum(m['target_status'] == 'reject' for m in test_meta), 'phenomena': phenomena},
        'challenge': {s: len(ids) for s, ids in frozen['challenge'].items()},
        'dropped': dict(sorted(dropped.items())),
        'public': {'repo': PUBLIC_REPO, 'revision': PUBLIC_REVISION, 'fraction': fraction, 'token_cap': args.public_token_cap,
                   'licenses': {l: sum(r.get('license') == l for r in pool_rows) for l in sorted({r.get('license') for r in pool_rows})},
                   'categories': {c: sum(r.get('category') == c for r in pool_rows) for c in CC_BY_QUOTA}, **public_stats},
        'seed': args.seed,
    }
    print(json.dumps(summary, indent=2))
    if not args.write:
        print('Counts only. Add --write to create the private files.')
        return

    out = v2.private_directory(args.output)
    if not frozen_path.exists() or args.refreeze:
        v2.write_private(frozen_path, json.dumps(frozen, indent=1) + '\n')
    files = dict(train_files)
    files.update({
        'valid-tune.jsonl': [to_chat(e) for e in valid_tune], 'valid-select.jsonl': [to_chat(e) for e in valid_select],
        'valid-public.jsonl': [public_chat(r) for r in public_valid], 'test.jsonl': test_rows, 'test.meta.jsonl': test_meta,
        'challenge.jsonl': challenge_rows, 'challenge.meta.jsonl': challenge_meta, 'public-pool.jsonl': pool_rows,
        'audit.jsonl': [{'id': e['id'], 'rank': e.get('rank'), 'app_class': e['app_class'], 'input_source': e['input_source'],
                         'target_origin': e['target_origin'], 'tags': e['tags'], 'score': e['score'],
                         **{k: v for k, v in e['audit'].items() if k not in ('deletions', 'additions', 'numbers', 'identifiers')},
                         'deleted_reasons': [r for _, r in e['audit']['deletions']]} for e in pool],
    })
    for name, rows_out in files.items():
        v2.write_jsonl(out / name, rows_out)
    label = lambda rank: next(('curated<=%d' % n for n in NESTED if rank <= n), 'fill-in')
    sheet = [dict(e, set=label(e['rank'])) for e in ordering]
    sheet += [dict(entries[i], set='challenge:' + s, rank='') for s, ids in frozen['challenge'].items() for i in ids if i in entries]
    review_sheet(sheet, out / 'review.csv', out / 'review.html')
    v2.write_private(out / 'ATTRIBUTION.txt', (
        'Public rows in *-mix.jsonl and valid-public.jsonl come from the WhisperNow Cleanup dataset\n'
        '(https://huggingface.co/datasets/%s, revision %s) by stephan271c.\n'
        'Rows whose license field is MIT are used under the MIT license.\n' % (PUBLIC_REPO, PUBLIC_REVISION)
        + ('%d no_edit rows are CC BY 4.0, from MagicNoThief/handy-dictation-editing\n'
           '(https://huggingface.co/datasets/MagicNoThief/handy-dictation-editing), as redistributed in WhisperNow Cleanup;\n'
           'licensed under https://creativecommons.org/licenses/by/4.0/ (filtered, text unchanged).\n' % len(cc_by)
           if cc_by else 'No CC BY 4.0 rows are included.\n')
        + "All other rows are Jordan's private dictations and stay on his machines.\n"))
    summary['sha256'] = {name: sha256_file(out / name) for name in list(files) + ['review.csv', 'frozen-ids.json']}
    v2.write_private(out / 'summary.json', json.dumps(summary, indent=2) + '\n')
    print('Wrote', out)


if __name__ == '__main__':
    main()
