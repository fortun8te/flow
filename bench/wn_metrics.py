"""Shared scoring for WhisperNow cleanup outputs (PC trainer and scripts/eval-whispernow.py). No dependencies.

Content first, grounded in the transcript itself (so copying a bad Wispr target does not score perfectly):
  unexplained_cut   input words the output dropped with no reason (not a filler, a repetition/restart,
                    a self-correction, or light function-word smoothing)
  negation_lost     a negation the speaker said that the output dropped
  number_invented   a number in the output that the speaker never said
  words_invented    content words in the output that are not in the input (approved forms excepted)
Wispr similarity second:
  closeness_chars   difflib character ratio to Wispr's text (the measure behind the 0.862 / 0.861 numbers)
  closeness_tokens  1 - token edit rate with case and punctuation (scripts/eval-cleanup-vs-wispr.py)
  wer               word error rate to Wispr, ignoring case and punctuation
  cut_vs_wispr      share of the input words Wispr kept (minus fillers) that the output deleted
  fillers_left      filler tokens left in the output (Wispr's own count reported beside it)
Behaviour: empty, answering (reply instead of cleanup), looping, max-token stops.
"""
import difflib
import importlib.util
from pathlib import Path
import re

_distance_spec = importlib.util.spec_from_file_location("flow_text_metrics", Path(__file__).with_name("text_metrics.py"))
_distance_module = importlib.util.module_from_spec(_distance_spec)
_distance_spec.loader.exec_module(_distance_module)
edit_distance = _distance_module.edit_distance

WORD = re.compile(r"[\w'’]+", re.UNICODE)
TOKEN = re.compile(r"[\w'’-]+|[^\w\s]", re.UNICODE)
FILLERS = {'um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'hmm', 'ah', 'like', 'basically', 'literally', 'mm', 'mhm'}
FILLER_PHRASES = ('you know', 'i mean', 'sort of', 'kind of')
SOFT = {'so', 'just', 'really', 'actually', 'okay', 'ok', 'yeah', 'right', 'well', 'oh', 'anyway', 'and', 'but',
        'then', 'now', 'pretty', 'very', 'stuff', 'whatever'}
DROPPABLE = {'a', 'an', 'the', 'and', 'so', 'to', 'of', 'in', 'on', 'at', 'for', 'is', 'are', 'was', 'were', 'be',
             'that', 'it', 'as', 'by', 'then', 'there', "it's", "that's", 'this'}
CUES = {'no', 'sorry', 'wait', 'actually', 'mean', 'rather', 'scratch', 'instead', 'correction', 'not'}
NEGATIONS = {'not', 'never', "don't", "doesn't", "didn't", "can't", 'cannot', "won't", "isn't", "aren't", "wasn't",
             "weren't", "shouldn't", "wouldn't", "couldn't", "haven't", "hasn't", 'nothing', 'none', 'without'}
GRAMMAR = DROPPABLE | {'or', 'but', 'with', 'if', 'than', 'about', 'from', 'does', 'do', 'did', 'many', 'much', 'am',
                       'has', 'have', 'had', 'will', 'would', 'can', 'could', 'should', 'its', 'these', 'those',
                       "there's", 'into', 'onto', 'i', "i'm", 'me', 'my', 'we', 'you', 'your', 'they', 'also', 'up', 'going'}
UNITS = {'zero': 0, 'oh': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8,
         'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
         'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'first': 1, 'second': 2, 'third': 3,
         'fourth': 4, 'fifth': 5, 'sixth': 6, 'seventh': 7, 'eighth': 8, 'ninth': 9, 'tenth': 10, 'twelfth': 12,
         'thirteenth': 13, 'fifteenth': 15, 'twentieth': 20, 'thirtieth': 30}
TENS = {'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50, 'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90}
SCALES = {'hundred': 100, 'thousand': 1000, 'k': 1000, 'million': 10 ** 6, 'billion': 10 ** 9}
EXPANSIONS = {'gonna': {'going', 'to'}, 'wanna': {'want', 'to'}, 'gotta': {'got', 'to'}, 'kinda': {'kind', 'of'},
              'sorta': {'sort', 'of'}, 'lemme': {'let', 'me'}, 'gimme': {'give', 'me'}, 'ok': {'okay'}, 'okay': {'ok'},
              'alright': {'all', 'right'}, 'cause': {'because'}, 'till': {'until'}, 'yeah': {'yes'}, 'yep': {'yes'}}
# Spoken symbols that a writer turns into the symbol itself ("slash" -> "/", "focus underscore app" -> "focus_app").
SPOKEN_SYMBOLS = {'slash': '/', 'backslash': '\\', 'underscore': '_', 'dot': '.', 'dash': '-', 'hyphen': '-', 'colon': ':',
                  'percent': '%', 'hashtag': '#', 'hash': '#', 'ampersand': '&', 'tilde': '~', 'asterisk': '*', 'equals': '=',
                  'plus': '+'}
ANSWER_OPENERS = re.compile(r"^(sure|certainly|of course|here(?:'s| is| are)|i can|i'd be happy|absolutely|great question|"
                            r"as an ai|i'm sorry|i cannot)\b", re.I)


def words(text):
    return [w.lower().replace('’', "'") for w in WORD.findall(text or '')]


def filler_positions(tokens):
    hits = {i for i, w in enumerate(tokens) if w in FILLERS}
    for phrase in FILLER_PHRASES:
        n = len(phrase.split())
        for i in range(len(tokens) - n + 1):
            if ' '.join(tokens[i:i + n]) == phrase:
                hits.update(range(i, i + n))
    return hits


def compose(run):
    out, parts, current, total = set(), [], 0, 0
    for token in run:
        if token in UNITS:
            value = UNITS[token]
            out.add(value)
            if 20 <= current < 100 and current % 10 == 0 and value < 10:
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
        elif run:
            values |= compose(run)
            run = []
    return values


def invented_numbers(source, output):
    values, bad = spoken_values(source), []
    output = re.sub(r'(?m)^(\s*)\d+[.)]\s', r'\1', output or '')  # list numbering is layout
    for raw in re.findall(r'\d+(?:[.,:/]\d+)*(?:st|nd|rd|th|k|%)?', output, flags=re.I):
        core = re.sub(r'(st|nd|rd|th|k|%)$', '', raw, flags=re.I)
        parts = [int(p) for p in re.split(r'[.,:/]', core.replace(',', '')) if p.isdigit()]
        joined = re.sub(r'\D', '', core)
        if not ((joined and len(joined) < 12 and int(joined) in values) or (parts and all(p in values for p in parts))):
            bad.append(raw)
    return bad


def same_stem(a, b):
    if a == b:
        return True
    if min(len(a), len(b)) >= 4 and (a.endswith(b) or b.endswith(a)):
        return True
    n = 0
    while n < min(len(a), len(b)) and a[n] == b[n]:
        n += 1
    return n >= 3 and n >= min(len(a), len(b)) - 1 or (n >= 4 and n >= 0.6 * max(len(a), len(b)))


def numberish(w):
    return w in UNITS or w in TENS or w in SCALES or w in ('and', 'point', 'by', 'percent', "o'clock", 'number') or w.isdigit()


def symbol_join(spoken, written):
    """'qwen three point eight' == 'qwen3 8' and 'focus underscore app' == 'focus_app' once spoken symbols are dropped,
    single number words become digits and written separators are ignored."""
    a = ''.join(str(UNITS.get(w, TENS.get(w, w))) for w in spoken if w not in SPOKEN_SYMBOLS and w != 'point')
    b = re.sub(r'[_./:\\-]', '', ''.join(written))
    return bool(a) and a == b


def edit_reasons(source, output):
    """Per input word the output dropped: filler / repeat / correction / soft / content. Plus added words."""
    s, o = words(source), words(output)
    fillers = filler_positions(s)
    deleted, added = [], []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, s, o, autojunk=False).get_opcodes():
        if op == 'equal':
            continue
        gone, new = s[i1:i2], o[j1:j2]
        if op == 'replace':
            joined_a, joined_b = ''.join(gone), ''.join(new)
            if joined_a == joined_b or joined_a.replace("'", '') == joined_b.replace("'", '') \
                    or (all(numberish(g) for g in gone) and all(re.fullmatch(r'[\d.,:/%]+\w{0,2}', x) for x in new)) \
                    or any(set(new) <= EXPANSIONS.get(g, set()) | {g} for g in gone) or symbol_join(gone, new) \
                    or (len(new) == 1 and len(gone) <= 2 and all(same_stem(g, new[0]) or g in DROPPABLE or g in FILLERS for g in gone)
                        and any(same_stem(g, new[0]) for g in gone)):
                continue
        for w in new:
            if w not in s and w not in GRAMMAR and not re.fullmatch(r'[\d.,:/%]+\w{0,2}', w) \
                    and not any(w == x + y for x, y in zip(s, s[1:])) and not any(w in EXPANSIONS.get(g, ()) for g in s):
                added.append(w)
        if not gone:
            continue
        after = s[i2:i2 + max(8, len(gone) + 4)]
        nearby = set(s[max(0, i1 - len(gone) - 12):i1]) | set(after)
        window = set(s[max(0, i1 - 3):i2 + 3])
        restart = gone[0] in after[:3] or all(w in after for w in gone)
        for k, w in enumerate(gone):
            i = i1 + k
            if i in fillers:
                reason = 'filler'
            elif w in SPOKEN_SYMBOLS and SPOKEN_SYMBOLS[w] in (output or ''):
                reason = 'symbol'
            elif w in nearby or restart:
                reason = 'repeat'
            elif window & CUES:
                reason = 'correction'
            elif w in SOFT or w in DROPPABLE:
                reason = 'soft'
            else:
                reason = 'content'
            deleted.append((i, w, reason))
    return deleted, added


def deleted_positions(a, b):
    gone = set()
    for op, i1, i2, _, _ in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op in ('delete', 'replace'):
            gone.update(range(i1, i2))
    return gone


def looping(source, output):
    def grams(text):
        w = words(text)
        return [' '.join(w[i:i + 4]) for i in range(max(0, len(w) - 3))]
    said, out = grams(source), grams(output)
    return any(out.count(g) >= 3 and out.count(g) >= said.count(g) + 2 for g in set(out))  # repeats beyond what was said


def score_row(source, output, wispr, finish_reason=None):
    output = (output or '').strip()
    s, o, t = words(source), words(output), words(wispr)
    is_empty = not output or output == 'EMPTY'
    noise_only = bool(s) and all(w in FILLERS | {'oh', 'hm', 'huh'} for w in s)
    deleted, added = edit_reasons(source, output) if not is_empty else ([(i, w, 'content') for i, w in enumerate(s)], [])
    unexplained = [w for _, w, r in deleted if r == 'content']
    # Count-based: "not send" -> "don't send" or "isn't" -> "aren't" keeps the negation; only a net loss counts.
    is_neg = lambda w: w in NEGATIONS or w.endswith("n't")
    dropped_ok = {i for i, w, r in deleted if r in ('repeat', 'filler')}
    neg_in = sum(1 for i, w in enumerate(s) if is_neg(w) and i not in dropped_ok)
    negations_lost = ['neg'] * max(0, neg_in - sum(1 for w in o if is_neg(w))) if not is_empty else [w for w in s if is_neg(w)]
    fillers = filler_positions(s)
    wispr_kept = set(range(len(s))) - deleted_positions(s, t) - fillers
    out_gone = deleted_positions(s, o)
    ft, fo = TOKEN.findall(wispr or ''), TOKEN.findall(output)
    answering = (not is_empty and (bool(ANSWER_OPENERS.match(output)) and not ANSWER_OPENERS.match(source.strip()))
                 or len(o) > 1.5 * len(s) + 8)
    return {
        'source_words': len(s), 'unexplained_cut': len(unexplained), 'unexplained_words': unexplained[:12],
        'negation_lost': len(negations_lost), 'number_invented': len(invented_numbers(source, output)) if not is_empty else 0,
        'words_invented': len(added), 'invented_list': added[:12],
        'kept_wispr': len(wispr_kept), 'cut_vs_wispr': len(wispr_kept & out_gone),
        'fillers_left': len(filler_positions(o)), 'fillers_wispr': len(filler_positions(t)),
        'closeness_chars': difflib.SequenceMatcher(None, output, (wispr or '').strip()).ratio(),
        'fmt_edits': edit_distance(ft, fo), 'fmt_tokens': max(1, len(ft)),
        'wer_edits': edit_distance(t, o), 'wer_words': max(1, len(t)),
        'exact': ' '.join(output.split()) == ' '.join((wispr or '').split()),
        'empty': is_empty, 'false_empty': is_empty and not noise_only, 'answering': bool(answering),
        'looping': looping(source, output), 'max_tokens_stop': finish_reason == 'length',
    }


def aggregate(rows):
    if not rows:
        return {'rows': 0}
    total = lambda k: sum(r[k] for r in rows)
    n = len(rows)
    source_words = max(1, total('source_words'))
    return {
        'rows': n,
        # content gate (transcript-grounded)
        'rows_with_unexplained_cut': sum(r['unexplained_cut'] > 0 for r in rows),
        'unexplained_cut_per_1k_words': round(1000 * total('unexplained_cut') / source_words, 2),
        'negation_lost': total('negation_lost'), 'number_invented': total('number_invented'),
        'rows_with_invented_words': sum(r['words_invented'] > 0 for r in rows),
        'invented_per_1k_words': round(1000 * total('words_invented') / source_words, 2),
        # Wispr similarity
        'closeness_chars': round(sum(r['closeness_chars'] for r in rows) / n, 4),
        'closeness_tokens': round(1 - total('fmt_edits') / max(1, total('fmt_tokens')), 4),
        'wer': round(total('wer_edits') / max(1, total('wer_words')), 4),
        'exact': round(sum(r['exact'] for r in rows) / n, 4),
        'cut_vs_wispr': round(total('cut_vs_wispr') / max(1, total('kept_wispr')), 4),
        'fillers_left': total('fillers_left'), 'fillers_wispr': total('fillers_wispr'),
        # behaviour
        'empty': sum(r['empty'] for r in rows), 'false_empty': sum(r['false_empty'] for r in rows),
        'answering': sum(r['answering'] for r in rows), 'looping': sum(r['looping'] for r in rows),
        'max_tokens_stop': sum(r['max_tokens_stop'] for r in rows),
    }
