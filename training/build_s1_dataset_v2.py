#!/usr/bin/env python3
"""Build the S1-mini LoRA v2 dataset: strict content-preserving targets (v1 lost too much content).

Same inputs and holdouts as build_s1_dataset.py (v1): test.jsonl (253 frozen rows) and the 58 eval cases are never
trained on; valid.jsonl is the validation set. What changes is the training target rule:

- A target may delete only fillers (the scorer's own FILLERS / FILLER_PHRASES) and adjacent duplicate words.
- Any other deletion of input content drops the pair (numbers, names, dictionary terms, ordinary words).
- The one exception is a true self-correction: a cue ("no wait", "I mean", "actually", "sorry", ...) with the
  deleted material before the last cue, the corrected value kept after it, and no content lost after the cue.
- Invented content drops the pair: any digit not in the input, or any content word not in the input.
- Pairs that keep numbers, names, or a self-correction with a number are duplicated (weight) so they dominate.
- A small Dutch passthrough set (target = input unchanged) keeps Dutch alone.

Output: ~/Library/Application Support/VOICE/S1Tuning-v2/ (0600 files, private, never committed).
    python3 training/build_s1_dataset_v2.py
"""
import difflib
import json
import os
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_s1_dataset import (CASES, SRC, STOP, pair, read_jsonl, toks, trigrams, jaccard,  # noqa: E402
                              write_private)

HOME = Path.home()
OUT = HOME / 'Library/Application Support/VOICE/S1Tuning-v2'
CONTROL = '[Styling: semi-formal] [Structure: prose] [Context: general]'
SYSTEM = ('You are a text normalizer for speech-to-text transcripts. The input begins with a control line '
          'specifying the styling, structure, and context settings; clean the transcript to match those '
          'settings and output only the cleaned text.')
SEED = 7

# Same filler definition as scripts/eval-cleanup-vs-wispr.py, so training and the ship check agree.
FILLERS = {'um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'hmm', 'ah', 'like', 'basically', 'literally'}
FILLER_PHRASES = ('you know', 'i mean', 'sort of', 'kind of')
CUE_PHRASES = [('no', 'wait'), ('wait', 'no'), ('wait', ','), ('i', 'mean'), ('scratch', 'that'), ('or', 'rather'),
               ('actually',), ('sorry',), ('correction',), ('no', 'no'), ('no', ',')]
RESTART_WINDOW = 12
NUMBER_WORDS = {'zero': '0', 'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6',
                'seven': '7', 'eight': '8', 'nine': '9', 'ten': '10', 'eleven': '11', 'twelve': '12',
                'thirteen': '13', 'fourteen': '14', 'fifteen': '15', 'sixteen': '16', 'seventeen': '17',
                'eighteen': '18', 'nineteen': '19', 'twenty': '20', 'thirty': '30', 'forty': '40', 'fifty': '50',
                'sixty': '60', 'seventy': '70', 'eighty': '80', 'ninety': '90', 'hundred': '100',
                'thousand': '1000'}
WORD = re.compile(r"[\w'’]+", re.UNICODE)
# Currency and unit words are formatting ("three dollars" -> "$3", "50 percent" -> "50%"), not content.
UNIT_WORDS = {'dollars', 'dollar', 'bucks', 'buck', 'euros', 'euro', 'pounds', 'pound', 'percent'}

DUTCH_PASSTHROUGH = [
    'Ik denk dat we morgen om tien uur kunnen beginnen, eh, als dat past.',
    'Uhm, kan jij de factuur van vierhonderd euro even doorsturen naar Pieter?',
    'Dat was echt een hele goede vergadering gisteren, vond je niet?',
    'Ik ben nu onderweg, ik ben over tien minuten bij je.',
    'Nou, laten we dat maar gewoon zo doen, toch?',
    'Het spijt me, ik kon je niet bereiken want mijn telefoon was leeg.',
    'Zullen we vrijdag samen naar de markt gaan in Utrecht?',
    'Ik heb het rapport al gemaild, maar ik wacht nog op jouw feedback.',
    'Sorry, ik was even vergeten dat we een afspraak hadden om twee uur.',
    'De trein naar Amsterdam vertrekt van spoor zeven om kwart over drie.',
    'Hoe laat komen jullie eigenlijk aan bij het station?',
    'Het is best koud vandaag, dus neem een jas mee als je naar buiten gaat.',
    'Ehm, ik weet niet zeker of het kan, maar ik kijk het na.',
    'We hebben de kosten met twintig procent verlaagd in het eerste kwartaal.',
    'Kun je even kijken of de bestelling van dinsdag al is verstuurd?',
    'Dat klinkt als een goed plan, laten we het zo proberen.',
    'Ik ga zo even koffie halen, wil jij ook iets?',
    'Mijn zus woont sinds vorig jaar in Rotterdam, in een klein appartement aan de haven.',
    'Oké, geen stress, we redden dit wel samen.',
    'Het pakket is bezorgd op de derde verdieping, bij mevrouw De Vries.',
    'Hé, heb je al gehoord dat de winkel in de Kalverstraat sluit?',
    'Ik vind het lastig om te kiezen, eigenlijk wil ik allebei.',
    'Tot zo, ik ben er over een kwartier.',
    'Eh, het kostte ongeveer 45 minuten, misschien iets minder.',
    'Wij gaan volgende week naar Groningen voor het congres van zes tot en met acht maart.',
    'Kun je de presentatie nog even nakijken voordat ik hem naar de klant stuur?',
    'Sorry dat ik zo laat ben, het verkeer op de A2 stond helemaal vast.',
    'Dit is de laatste versie, de oude moet je niet meer gebruiken.',
    'Ik heb gisteren drie mails beantwoord en nog twee uitgesteld.',
    'Hoi, hoe gaat het met je en met de kinderen?',
]


def norm_tokens(text):
    """Lowercase word tokens; thousands commas removed; number words mapped to digits."""
    text = re.sub(r'(?<=\d),(?=\d{3}\b)', '', text or '')
    out = []
    for w in WORD.findall(text):
        w = w.lower().replace('’', "'")
        if w in UNIT_WORDS:
            continue
        out.append(NUMBER_WORDS.get(w, w))
    return out


def is_number(tok):
    return bool(re.search(r'\d', tok))


def filler_positions(words):
    hits = {i for i, w in enumerate(words) if w in FILLERS}
    for phrase in FILLER_PHRASES:
        parts = phrase.split()
        n = len(parts)
        for i in range(len(words) - n + 1):
            if words[i:i + n] == parts:
                hits.update(range(i, i + n))
    return hits


def cue_spans(words):
    spans = []
    for phrase in CUE_PHRASES:
        n = len(phrase)
        for i in range(len(words) - n + 1):
            if tuple(words[i:i + n]) == phrase:
                spans.append((i, i + n - 1))
    return sorted(spans)


def capitalised_names(source):
    """Capitalised words not at the start of a sentence (approximates dictionary names and product names)."""
    names = set()
    for sentence in re.split(r'(?<=[.!?])\s+', source):
        for k, match in enumerate(re.finditer(r"\b[A-Z][\w'-]*", sentence)):
            if k > 0 or match.start() > 0:
                names.add(match.group(0).lower())
    return names


def audit(source, target):
    """Return (verdict, detail). verdict is 'keep', 'self_correction', or 'drop:<reason>'."""
    s, t = norm_tokens(source), norm_tokens(target)
    if not s or not t:
        return 'drop:empty', None
    fill = filler_positions(s)
    deleted = set()
    matcher = difflib.SequenceMatcher(None, s, t, autojunk=False)
    for op, i1, i2, j1, j2 in matcher.get_opcodes():
        if op not in ('delete', 'replace'):
            continue
        for i in range(i1, i2):
            # a replacement that is the same word spelled differently (dont -> don't) is not a loss
            if op == 'replace' and any(difflib.SequenceMatcher(None, s[i], t[j]).ratio() >= 0.8
                                       for j in range(j1, j2)):
                continue
            deleted.add(i)

    def repeated_run(a, b):
        # a restart: the same run of words is said again a few words later, and that copy is kept
        n = b - a + 1
        for j in range(b + 1, min(len(s) - n, b + RESTART_WINDOW) + 1):
            if s[j:j + n] == s[a:b + 1] and not any(k in deleted for k in range(j, j + n)):
                return True
        return False

    lost, run = [], []
    for i in sorted(deleted):
        if i in fill:
            continue
        if run and i != run[-1] + 1:
            if not repeated_run(run[0], run[-1]):
                lost.extend(run)
            run = []
        run.append(i)
    if run and not repeated_run(run[0], run[-1]):
        lost.extend(run)
    # invented content: a digit the input never said, or a content word with no close match in the input
    in_words = set(s)
    invented = [w for w in t if w not in in_words and (
        is_number(w) or (w not in STOP and len(w) >= 4 and
                         max(difflib.SequenceMatcher(None, w, x).ratio() for x in in_words) < 0.75))]
    if invented:
        return 'drop:invented', invented[:5]
    if not lost:
        return 'keep', None

    cues = cue_spans(s)
    if cues:
        cue_start, cue_end = cues[-1]
        after = [k for k in range(cue_end + 1, len(s)) if k not in fill]
        kept_after = all(k not in deleted for k in after)  # nothing after the last cue may be lost
        before_ok = all(cue_start - RESTART_WINDOW <= i < cue_start for i in lost)  # only the restarted part goes
        has_after = bool(after)
        numbers_lost = any(is_number(s[i]) for i in lost)
        # a dropped number is only a correction if a corrected number survives after the cue
        corrected_number = any(is_number(w) for w in s[cue_end + 1:]) and any(is_number(w) for w in t)
        if kept_after and before_ok and has_after and (corrected_number or not numbers_lost):
            return 'self_correction', [s[i] for i in lost]
    kind = 'number' if any(is_number(s[i]) for i in lost) else \
        'name' if any(s[i] in capitalised_names(source) for i in lost) else 'content'
    return 'drop:' + kind, [s[i] for i in lost][:5]


def weight_for(source, target, verdict):
    s_tok, t_tok = set(norm_tokens(source)), set(norm_tokens(target))
    numbers = {w for w in s_tok if is_number(w)}
    names = {n for n in capitalised_names(source) if n in t_tok}
    w = 1
    if numbers and numbers <= t_tok:
        w += 1
    if names:
        w += 1
    if verdict == 'self_correction' and numbers:
        w += 1  # hard negative: a restart where the corrected number must survive
    return w


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    train = read_jsonl(SRC / 'train.jsonl')
    valid = read_jsonl(SRC / 'valid.jsonl')
    test = read_jsonl(SRC / 'test.jsonl')
    cases = json.loads(CASES.read_text(encoding='utf-8'))
    case_tri = [trigrams(c['raw']) for c in cases]
    test_tri = [trigrams(pair(r)[1]) for r in test]

    dropped, verdicts = Counter(), Counter()
    kept, seen = [], set()
    dropped_examples = []
    for row in train:
        control, text, target = pair(row)
        if not target.strip() or not text.strip():
            dropped['empty'] += 1
            continue
        key = (text.strip(), target.strip())
        if key in seen:
            dropped['duplicate'] += 1
            continue
        in_n, out_n = len(text.split()), len(target.split())
        if in_n >= 8 and not (0.5 <= out_n / in_n <= 1.3):
            dropped['length_ratio'] += 1
            continue
        verdict, detail = audit(text, target)
        if verdict.startswith('drop:'):
            dropped[verdict] += 1
            if len(dropped_examples) < 400:
                dropped_examples.append({'verdict': verdict, 'detail': detail, 'input': text, 'target': target})
            continue
        tri = trigrams(text)
        if any(jaccard(tri, c) >= 0.6 for c in case_tri):
            dropped['overlaps_eval_case'] += 1
            continue
        if any(jaccard(tri, t) >= 0.6 for t in test_tri):
            dropped['overlaps_test'] += 1
            continue
        seen.add(key)
        verdicts[verdict] += 1
        copies = weight_for(text, target, verdict)
        for _ in range(copies):
            kept.append(row)
    # Dutch passthrough: input is left unchanged (Flow routes Dutch around S1; this guards the model too).
    dutch = []
    for line in DUTCH_PASSTHROUGH:
        dutch.append({'messages': [{'role': 'system', 'content': SYSTEM},
                                   {'role': 'user', 'content': CONTROL + '\n' + line},
                                   {'role': 'assistant', 'content': line}]})
    rng = random.Random(SEED)
    train_rows = kept + dutch
    rng.shuffle(train_rows)
    # Validation: the same content rule (drop only; no duplicates), so checkpoint choice reflects the target rule.
    valid_kept = [r for r in valid if not audit(pair(r)[1], pair(r)[2])[0].startswith('drop:')]

    write_private(OUT / 'train.jsonl', train_rows)
    write_private(OUT / 'valid.jsonl', valid_kept)
    write_private(OUT / 'test.jsonl', test)
    for name in ('test.meta.jsonl',):
        src = SRC / name
        if src.exists():
            write_private(OUT / name, read_jsonl(src))
    write_private(OUT / 'dropped-examples.jsonl', dropped_examples)

    summary = {
        'source': 'WisprCleanupTuning-v2 (Wispr ASR inputs; production_exact_inputs = false); v2 strict targets',
        'train_in': len(train), 'unique_kept': len(seen), 'train_rows_after_weighting': len(train_rows) - len(dutch),
        'dropped': dict(dropped), 'kept_verdicts': dict(verdicts),
        'dutch_passthrough_rows': len(dutch),
        'valid_in': len(valid), 'valid_kept': len(valid_kept),
        'test_heldout': len(test), 'eval_cases_heldout': len(cases),
        'control_lines': {CONTROL: len(train_rows) + len(valid_kept) + len(test)},
        'system_prompt_sha256': json.loads((SRC / 'summary.json').read_text(encoding='utf-8')).get('system_prompt_sha256'),
        'production_exact_inputs': False,
    }
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    os.chmod(OUT / 'summary.json', 0o600)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    sys.exit(main())
