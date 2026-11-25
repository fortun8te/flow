#!/usr/bin/env python3
"""Build the private dataset that teaches S1-mini to clean up like Wispr Flow.

A pair is (the exact string Flow hands S1-mini in production) -> (what Wispr pasted, or
a user edit of it), minus anything Flow adds after cleanup (American spelling,
replacements, the very-casual formatter). Everything is local; nothing trains or uploads.

Two passes:

    # Pass 1: select rows, copy their audio out of the Wispr export, and write the job file
    # for Flow's headless `--cleanup-prepare` mode (the only byte-exact way to get S1 inputs).
    python3 scripts/prepare-wispr-cleanup-v2.py --materialize-audio

    # (Mac, overnight) Flow --cleanup-prepare <config>  ->  prepared.jsonl

    # Pass 2: build train/valid/test from Flow's exact inputs.
    python3 scripts/prepare-wispr-cleanup-v2.py --write --prepared "$O/prepared.jsonl" [shadow-pairs.jsonl]

Without --prepared the inputs are Wispr's own ASR text. That build is marked
"production_exact_inputs": false and the PC trainer refuses it unless told otherwise.

Read-only sources: Wispr's flow.sqlite (mode=ro, query_only), the Wispr export ZIP in
~/Downloads, Flow's replacements.json, the imported Wispr profile and dictionary.

Output (~/Library/Application Support/VOICE/WisprCleanupTuning-v2/, all 0600):
  train.jsonl valid.jsonl test.jsonl  chat format (system, user = control line + "\\n" + input, assistant)
  test.meta.jsonl                     aligned with test.jsonl: id, bundle, tags, Wispr texts
  routing.jsonl                       recent rows Flow must route around S1 (Dutch, mixed)
  eval-input.jsonl                    {id, text, bundle_id} for Flow's `--cleanup-run` (test + routing)
  flow-prepare-input.jsonl            {id, audio, bundle_id, mic_class, ...} for `--cleanup-prepare`
  grpo/train.jsonl grpo/valid.jsonl   {system, prompt, answer} for a later preference/RL step
  summary.json                        counts and drop reasons only, no text
"""
import argparse
import datetime as dt
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import tempfile
import wave
import zipfile

HOME = Path.home()
SUPPORT = HOME / 'Library/Application Support/VOICE'
DEFAULT_DB = HOME / 'Library/Application Support/Wispr Flow/flow.sqlite'
DEFAULT_OUTPUT = SUPPORT / 'WisprCleanupTuning-v2'
OLD_EVALUATION = SUPPORT / 'WisprAudioEvaluation/manifest.json'
PROFILE = SUPPORT / 'WisprPersonalization/profile.json'
DICTIONARY = SUPPORT / 'WisprPersonalization/dictionary.json'
REPLACEMENTS = SUPPORT / 'Wispr Import/replacements.json'
DOWNLOADS = HOME / 'Downloads'

# Exact S1-mini system prompt: Sources/Voice/Services/S1MiniPolisher.swift `systemPrompt`.
SYSTEM_PROMPT = ('You are a text normalizer for speech-to-text transcripts. The input begins with a control line '
                 'specifying the styling, structure, and context settings; clean the transcript to match those '
                 'settings and output only the cleaned text.')
DEFAULT_CONTROL = '[Styling: semi-formal] [Structure: prose] [Context: general]'  # S1MiniPolisher.Options()

FIELDS = ('transcriptEntityId', 'timestamp', 'asrText', 'formattedText', 'editedText', 'toneMatchedText', 'status',
          'app', 'detectedLanguage', 'hasRevertedAI', 'usedFallbackAsr', 'usedFallbackFormatting',
          'transcriptCommand', 'personalizationStyleSettings', 'duration', 'micDevice', 'numDictionaryReplacements')
WORD = re.compile(r"[\w'’]+", re.UNICODE)
DUTCH = {'het', 'een', 'niet', 'ik', 'maar', 'ook', 'wel', 'nog', 'heb', 'jij', 'mijn', 'dus', 'gewoon',
         'eigenlijk', 'echt', 'nou', 'zijn', 'wat', 'naar', 'wordt', 'kunnen', 'moet', 'hebben', 'dit', 'deze'}

# ---------------------------------------------------------------------------
# Python ports of Flow's routing, checked against the Swift on 13 Nov 2026.
# Flow's --cleanup-prepare output is authoritative; these are only used to
# cross-check it and for the draft (inexact) build.
# ---------------------------------------------------------------------------
# Utils/CursorPaster.swift codeEditorBundleIds + isCodeEditor() substring rules -> PolishContext.code,
# which Qwen3Polisher.polish passes through without calling S1-mini.
CODE_BUNDLES = {'com.apple.dt.Xcode', 'com.microsoft.VSCode', 'com.todesktop.230313mzl4w4u92',
                'com.todesktop.230313mzl4w4u92.cursor', 'com.apple.Terminal', 'com.googlecode.iterm2',
                'co.zeit.hyper', 'dev.warp.Warp-Stable', 'com.jetbrains.intellij', 'com.jetbrains.pycharm',
                'com.jetbrains.WebStorm', 'com.jetbrains.AppCode', 'com.jetbrains.goland', 'com.sublimetext.4'}
CODE_SUBSTRINGS = ('xcode', 'vscode', 'cursor', 'terminal', 'iterm', 'jetbrains', 'sublime', 'zed')
# Services/WisprPersonalizationProfile.swift style(forBundleID:)
PERSONAL = {'com.apple.MobileSMS', 'ru.keepcoder.Telegram', 'com.whatsapp.WhatsApp', 'net.whatsapp.WhatsApp',
            'com.hnc.Discord', 'com.discord', 'com.facebook.Messenger'}
WORK = {'com.tinyspeck.slackmacOS', 'com.tinyspeck.slackmacgap', 'com.microsoft.teams', 'com.microsoft.teams2'}
EMAIL = {'com.apple.mail', 'com.microsoft.Outlook', 'com.superhuman.Superhuman', 'com.readdle.smartemail-Mac'}
# Proposed Swift mapping personalityStyle -> S1 styling (docs, "Loading in Flow" step).
STYLING = {'veryCasual': 'casual', 'casual': 'semi-casual', 'excited': 'semi-formal', 'neutral': 'semi-formal',
           'formal': 'formal'}
# Wispr's own per-row style names -> Flow style names (WisprPersonalizationProfile.style(for:)).
WISPR_STYLE = {'excited': 'excited', 'verycasual': 'veryCasual', 'casual': 'casual', 'formal': 'formal'}


def is_code_app(bundle):
    if not bundle:
        return False
    return bundle in CODE_BUNDLES or any(s in bundle.lower() for s in CODE_SUBSTRINGS)


def flow_style(bundle, profile):
    styles = {k: (v or '').lower() for k, v in (profile.get('personalization_styles') or {}).items()}
    if not bundle:
        context = 'unset'
    elif bundle in PERSONAL:
        context = 'personal'
    elif bundle in WORK:
        context = 'work'
    elif bundle in EMAIL:
        context = 'email'
    else:
        context = 'other'
    return WISPR_STYLE.get(styles.get(context, ''), 'neutral')


def flow_control(bundle, profile, policy):
    if policy == 'flow-current':
        return DEFAULT_CONTROL  # what Qwen3Polisher sends today: S1MiniPolisher.polish(text, language:) defaults
    style = flow_style(bundle, profile)
    lower = (bundle or '').lower()
    email = not is_code_app(bundle) and any(s in lower for s in ('mail', 'spark', 'outlook'))  # PolishContext.email
    return '[Styling: %s] [Structure: prose] [Context: %s]' % (STYLING.get(style, 'semi-formal'),
                                                               'email' if email else 'general')


# ---------------------------------------------------------------------------
# Post-cleanup steps Flow applies itself; targets are normalised so the model does not learn them.
# Services/AmericanSpelling.swift (applied in DictationTextPreparation.finalize after cleanup).
SPELLING = [('colour', 'color'), ('favour', 'favor'), ('flavour', 'flavor'), ('honour', 'honor'), ('humour', 'humor'),
            ('labour', 'labor'), ('neighbour', 'neighbor'), ('behaviour', 'behavior'), ('rumour', 'rumor'),
            ('harbour', 'harbor'), ('armour', 'armor'), ('vapour', 'vapor'), ('endeavour', 'endeavor'),
            ('savour', 'savor'), ('parlour', 'parlor'), ('centre', 'center'), ('theatre', 'theater'),
            ('metre', 'meter'), ('litre', 'liter'), ('fibre', 'fiber'), ('organis', 'organiz'), ('realis', 'realiz'),
            ('recognis', 'recogniz'), ('apologis', 'apologiz'), ('prioritis', 'prioritiz'), ('optimis', 'optimiz'),
            ('customis', 'customiz'), ('minimis', 'minimiz'), ('maximis', 'maximiz'), ('summaris', 'summariz'),
            ('emphasis', 'emphasiz'), ('finalis', 'finaliz'), ('visualis', 'visualiz'), ('categoris', 'categoriz'),
            ('personalis', 'personaliz'), ('normalis', 'normaliz'), ('standardis', 'standardiz'),
            ('synchronis', 'synchroniz'), ('utilis', 'utiliz'), ('criticis', 'criticiz'), ('analys', 'analyz'),
            ('paralys', 'paralyz'), ('defence', 'defense'), ('licence', 'license'), ('offence', 'offense'),
            ('catalogue', 'catalog'), ('dialogue', 'dialog'), ('grey', 'gray'), ('aluminium', 'aluminum'),
            ('programme', 'program'), ('tyre', 'tire'), ('cheque', 'check'), ('jewellery', 'jewelry'),
            ('plough', 'plow'), ('sceptic', 'skeptic')]


def keep_input_spelling(source, target):
    """Where the input says 'colours' and Wispr says 'colors', keep 'colours': Flow converts it later."""
    lower_source = source.lower()
    for british, american in SPELLING:
        def swap(match):
            word = match.group(0)
            candidate = british + word[len(american):]
            if re.search(r'\b%s\b' % re.escape(candidate), lower_source):
                if word.isupper() and len(word) > 1:
                    return candidate.upper()
                return candidate[0].upper() + candidate[1:] if word[0].isupper() else candidate
            return word
        target = re.sub(r'\b%s\w*' % re.escape(american), swap, target, flags=re.IGNORECASE)
    return target


def decasualize(text):
    """Undo WisprStyleFormatter's very-casual pass (sentence-opening lowercase, final period dropped).

    Flow re-applies it after S1 for personal apps, so the model only needs normal prose here.
    """
    text = re.sub(r"(?m)(^|[.!?]\s+)([a-z]+)\b", lambda m: m.group(1) + m.group(2)[0].upper() + m.group(2)[1:], text)
    text = re.sub(r"\bi\b(?=('m|'ve|'ll|'d|\s|[.,!?]|$))", 'I', text)
    stripped = text.rstrip()
    if stripped and stripped[-1].isalnum() and not re.search(r'(?m)^\s*(?:[-*•]|\d+\.)\s+', stripped):
        text = stripped + '.'
    return text


# ---------------------------------------------------------------------------
def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def words(text):
    return [w.lower().replace('’', "'") for w in WORD.findall(text or '')]


def squash(text):
    return re.sub(r'\s+', ' ', (text or '')).strip()


def parse_time(value):
    text = (value or '').strip().replace('Z', '+00:00').replace(' +', '+').replace(' -', '-')
    moment = dt.datetime.fromisoformat(text.replace(' ', 'T', 1))
    return (moment if moment.tzinfo else moment.replace(tzinfo=dt.timezone.utc)).timestamp()


def private_directory(path):
    path = path.expanduser().absolute()
    for component in reversed([path, *path.parents]):
        if component.is_symlink():
            raise SystemExit('Refusing a symlink in the output path: %s' % component)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid() or not stat.S_ISDIR(path.stat().st_mode):
        raise SystemExit('Output directory must belong to this user')
    path.chmod(0o700)
    return path


def write_private(path, text):
    fd, temporary = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as file:
            file.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_jsonl(path, rows):
    write_private(path, ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))


def load_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def read_history(database):
    uri = database.expanduser().absolute().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only=ON')
        columns = {r['name'] for r in connection.execute('PRAGMA table_info(History)')}
        fields = [f for f in FIELDS if f in columns]
        # Constant column whitelist; the audio blob is only tested for presence here.
        sql = 'SELECT %s, audio IS NOT NULL AS has_db_audio FROM History' % ','.join('"%s"' % f for f in fields)
        return [dict(r) for r in connection.execute(sql)]


def find_export_zip(explicit):
    if explicit:
        return explicit if explicit.is_file() else None
    found = sorted(DOWNLOADS.glob('wispr-flow-data-export-*.zip'), key=lambda p: p.stat().st_mtime)
    return found[-1] if found else None


def export_audio_members(archive_path):
    members = {}
    if archive_path:
        with zipfile.ZipFile(archive_path) as archive:
            for name in archive.namelist():
                parts = name.split('/')
                if len(parts) == 3 and parts[0] == 'dictations' and re.fullmatch(r'audio-[A-Za-z0-9_-]+\.wav', parts[2]):
                    members.setdefault(parts[1], []).append(name)
    return members


def snippet_texts():
    """Replacement outputs Flow pastes itself (replacements.json) plus Wispr dictionary snippets."""
    outputs = [e.get('to', '') for e in load_json(REPLACEMENTS, []) if isinstance(e, dict)]
    for entry in load_json(DICTIONARY, {}).get('entries', []):
        word, replacement = entry.get('word') or '', entry.get('replacement') or ''
        if replacement and (len(replacement) >= 20 or '@' in replacement or '\n' in replacement
                            or not set(words(replacement)) <= set(words(word))):
            outputs.append(replacement)
    return [o.strip().lower() for o in outputs if len(o.strip()) >= 3]


def dictionary_terms():
    terms = set()
    for entry in load_json(DICTIONARY, {}).get('entries', []):
        for key in ('word', 'replacement'):
            value = (entry.get(key) or '').strip()
            if value and len(value) < 40 and '@' not in value:
                terms.add(value.lower())
    return terms


def looks_dutch(text):
    tokens = words(text)
    return bool(tokens) and sum(t in DUTCH for t in tokens) / len(tokens) >= 0.12


def mic_class(device):
    lower = (device or '').lower()
    if 'built-in' in lower or 'macbook' in lower:
        return 'builtIn'
    if 'usb' in lower:
        return 'usb'
    if 'airpods' in lower or 'bluetooth' in lower or 'buds' in lower:
        return 'bluetooth'
    return 'unknown'


# Word-level support check: Wispr must not add content that is not in what was said.
NUMBER_WORDS = {'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven',
                'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty',
                'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand', 'million',
                'billion', 'percent', 'dollars', 'dollar', 'euros', 'euro', 'first', 'second', 'third', 'half'}
EXPANSIONS = {'gonna': {'going', 'to'}, 'wanna': {'want', 'to'}, 'gotta': {'got', 'to'}, 'kinda': {'kind', 'of'},
              'sorta': {'sort', 'of'}, 'lemme': {'let', 'me'}, 'gimme': {'give', 'me'}, 'ok': {'okay'},
              'okay': {'ok'}, 'alright': {'all', 'right'}, "'cause": {'because'}, 'cause': {'because'},
              'till': {'until'}, 'yeah': {'yes'}, 'yep': {'yes'}}


FUNCTION_WORDS = {'a', 'an', 'the', 'and', 'or', 'but', 'so', 'to', 'of', 'in', 'on', 'at', 'for', 'with', 'by',
                  'is', 'are', 'was', 'were', 'be', 'that', 'it', 'as', 'if', 'then', 'than', 'about', 'from'}


def unsupported_words(source, target):
    have = set(words(source))
    for word in list(have):
        have |= EXPANSIONS.get(word, set())
        if "'" in word:
            have |= set(word.split("'"))
    have |= {a for b, a in SPELLING for w in list(have) if w.startswith(b)}
    missing = []
    for word in words(target):
        base = word.split("'")[0]
        if word in have or base in have or word.isdigit() or re.fullmatch(r'\d[\d,.:%]*\w{0,2}', word):
            continue
        if word in NUMBER_WORDS or word in ('s', 't', 'd', 'll', 're', 've', 'm'):
            continue
        if any(word.startswith(a) and any(h.startswith(b) for h in have) for b, a in SPELLING):
            continue
        missing.append(word)
    return missing


def pair_problem(source, target, min_words, max_words, max_unsupported):
    a, b = words(source), words(target)
    if not (min_words <= len(a) <= max_words) or not b:
        return 'length'
    ratio = len(b) / len(a)
    if ratio < 0.55 or ratio > 1.2:
        return 'length_changed'
    if difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() < 0.6:
        return 'rewritten'
    missing = unsupported_words(source, target)
    content = [w for w in missing if w not in FUNCTION_WORDS]
    if len(content) > max_unsupported or len(missing) - len(content) > 2:
        return 'target_not_supported_by_speech'
    return None


def html_to_plain(text):
    """Wispr stores lists as <ul>/<ol> HTML and pastes them as '- item' / '1. item' lines (pastedText)."""
    if '<li>' not in text and '<ul>' not in text and '<ol' not in text:
        return text

    def ordered(match):
        start = int(match.group(1) or 1)
        items = re.findall(r'<li>(.*?)</li>', match.group(2), flags=re.S)
        return '\n'.join('%d. %s' % (start + i, item.strip()) for i, item in enumerate(items))

    text = re.sub(r'<ol(?: start="(\d+)")?>(.*?)</ol>', ordered, text, flags=re.S)
    text = re.sub(r'<ul>(.*?)</ul>', lambda m: '\n'.join('- ' + i.strip() for i in re.findall(r'<li>(.*?)</li>', m.group(1), flags=re.S)),
                  text, flags=re.S)
    return re.sub(r'\n{3,}', '\n\n', re.sub(r'</?[a-z]+[^>]*>', '', text)).strip()


def trailing_only(a, b):
    strip = lambda s: re.sub(r'[\s.!?,]+$', '', s)
    return strip(a) == strip(b)


def choose_target(formatted, edited):
    """Prefer Jordan's edit only when it is a real, light correction of Wispr's text.

    editedText is Wispr's read-back of the text box after paste: later typing, cut-off text,
    whitespace and whole-message lowercasing are not corrections and keep formattedText.
    """
    f, e = squash(formatted), squash(edited)
    if not e or e == f:
        return formatted.strip(), 'formatted'
    if trailing_only(f, e):
        return formatted.strip(), 'formatted:edit_trailing_only'
    if e.lower() == f.lower() or trailing_only(e.lower(), f.lower()):
        return formatted.strip(), 'formatted:edit_case_only'
    core = re.sub(r'[\s.!?,]+$', '', f)
    if e.startswith(core) or f.startswith(e) or e.startswith(f):
        return formatted.strip(), 'formatted:edit_was_append_or_truncation'
    if edited.count('\n') > formatted.count('\n'):
        return formatted.strip(), 'formatted:edit_added_lines'
    fw, ew = f.split(), e.split()
    if not fw or not (0.85 <= len(ew) / len(fw) <= 1.15):
        return formatted.strip(), 'formatted:edit_too_large'
    matcher = difflib.SequenceMatcher(None, fw, ew, autojunk=False)
    changed = sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in matcher.get_opcodes() if op != 'equal')
    if matcher.ratio() < 0.85 or changed > max(3, round(0.15 * len(fw))):
        return formatted.strip(), 'formatted:edit_too_large'
    return e, 'edited'


def row_wispr_style(row):
    try:
        style = json.loads(row.get('personalizationStyleSettings') or '{}').get('personalizationStyle')
    except ValueError:
        style = None
    return WISPR_STYLE.get((style or '').lower(), 'neutral' if style else None)


def hard_tags(source, target, terms):
    tags = []
    if re.search(r'(?m)^\s*(?:[-*•]|\d+[.)])\s+', target):
        tags.append('list')
    if re.search(r'\d', source + target) or set(words(source)) & (NUMBER_WORDS - {'first', 'second', 'half'}):
        tags.append('number')
    if re.search(r"\b\d{1,2}(:\d{2})?\s?(am|pm|a\.m\.|p\.m\.)|\bo'clock\b|\b(today|tomorrow|tonight|yesterday|monday|"
                 r"tuesday|wednesday|thursday|friday|saturday|sunday)\b", source, re.I):
        tags.append('time')
    if re.search(r'https?://|www\.|\b\w+\.(com|io|ai|app|dev|org|net|nl)\b|@\w|[/~]\w+/', source + ' ' + target, re.I):
        tags.append('url_email_path')
    lower = ' %s ' % ' '.join(words(target))
    if any(' %s ' % ' '.join(words(t)) in lower for t in terms if words(t)):
        tags.append('dictionary_name')
    if re.search(r"\b(i mean|sorry|no wait|wait no|actually|scratch that|or rather)\b", source, re.I) or \
            re.search(r"\b(\w+) \1\b", source, re.I):
        tags.append('self_correction')
    if len(words(source)) > 80:
        tags.append('long')
    return tags


def shingles(text, n=3):
    w = words(text)
    return {' '.join(w[i:i + n]) for i in range(max(1, len(w) - n + 1))} if w else set()


def load_prepared(paths):
    """id -> {s1_input, route, control_line, ...} from Flow --cleanup-prepare output or shadow-pairs.jsonl."""
    prepared = {}
    for path in paths:
        for line in path.open(encoding='utf-8'):
            if not line.strip():
                continue
            item = json.loads(line)
            if 'wispr_id' in item:  # shadow-pairs.jsonl
                if item.get('usable') and item.get('flow_input') is not None:
                    prepared[item['wispr_id']] = {'s1_input': item['flow_input'], 'route': item.get('route', 's1'),
                                                  'control_line': item.get('control_line'), 'source': 'shadow'}
            elif item.get('status') == 'ok':
                prepared[item['id']] = {**item, 'source': 'flow-cli'}
    return prepared


def materialize(rows, members, archive_path, database, output):
    audio_dir = private_directory(output / 'audio')
    jobs = []
    uri = database.expanduser().absolute().as_uri() + '?mode=ro'
    archive = zipfile.ZipFile(archive_path) if archive_path else None
    connection = sqlite3.connect(uri, uri=True)
    connection.execute('PRAGMA query_only=ON')
    try:
        for row in rows:
            identifier = row['transcriptEntityId']
            target = audio_dir / (digest(identifier) + '.wav')
            if not target.exists():
                if identifier in members:
                    data = archive.read(sorted(members[identifier])[0])
                elif row.get('has_db_audio'):
                    found = connection.execute('SELECT audio FROM History WHERE transcriptEntityId=?', (identifier,)).fetchone()
                    data = found[0] if found else None
                else:
                    continue
                if not data or data[:4] != b'RIFF' or len(data) > 50 * 1024 * 1024:
                    continue
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'wb') as file:
                    file.write(data)
            try:
                with wave.open(str(target)) as w:
                    seconds = w.getnframes() / float(w.getframerate())
            except (wave.Error, EOFError):
                continue
            if 0.2 <= seconds <= 600:
                jobs.append({'id': identifier, 'audio': str(target), 'bundle_id': row.get('app') or None,
                             'mic_class': mic_class(row.get('micDevice')), 'duration_s': round(seconds, 3),
                             'wispr_timestamp': row.get('timestamp')})
    finally:
        connection.close()
        if archive:
            archive.close()
    write_jsonl(output / 'flow-prepare-input.jsonl', jobs)
    return jobs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--reference-db', type=Path, default=DEFAULT_DB)
    parser.add_argument('--export-zip', type=Path)
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--prepared', type=Path, nargs='*', default=[],
                        help='Flow --cleanup-prepare output (prepared.jsonl) and/or shadow-pairs.jsonl')
    parser.add_argument('--allow-inexact', action='store_true',
                        help='with --prepared, fall back to Wispr ASR for rows Flow did not prepare (default: drop)')
    parser.add_argument('--control-policy', choices=('flow-current', 'style-mapped'), default='flow-current',
                        help='control line: what Flow sends today (one line for every app; default), or the '
                             'per-app mapping that needs the Swift change described in the plan')
    parser.add_argument('--test-days', type=float, default=7.0, help='most recent N days form the test split')
    parser.add_argument('--valid-percent', type=int, default=5)
    parser.add_argument('--min-words', type=int, default=2)
    parser.add_argument('--max-words', type=int, default=300)
    parser.add_argument('--max-unsupported', type=int, default=0,
                        help='content words in the target not heard in the input (default 0; up to 2 inserted function words allowed)')
    parser.add_argument('--train-code-apps', action=argparse.BooleanOptionalAction, default=True,
                        help='keep Warp/Cursor rows in train (Flow skips S1 there today); never in test')
    parser.add_argument('--train-lists', action='store_true',
                        help='also train on rows where Wispr made a list (default: test-only hard slice)')
    parser.add_argument('--materialize-audio', action='store_true',
                        help='copy audio for every selected row and write flow-prepare-input.jsonl')
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()

    profile = load_json(PROFILE, {})
    snippets = snippet_texts()
    terms = dictionary_terms()
    rows = read_history(args.reference_db)
    archive_path = find_export_zip(args.export_zip)
    members = export_audio_members(archive_path)
    prepared = load_prepared(args.prepared)
    exact_mode = bool(prepared)
    newest = max(parse_time(r['timestamp']) for r in rows if r.get('timestamp'))
    test_since = newest - args.test_days * 86400

    dropped, kinds = {}, {}
    selected, routing = [], []

    def drop(reason):
        dropped[reason] = dropped.get(reason, 0) + 1

    # ---- Stage A: row-level selection (independent of the input text) ----
    for row in rows:
        identifier = row['transcriptEntityId']
        if not identifier or not row.get('timestamp'):
            drop('no_id_or_time'); continue
        row['ts'] = parse_time(row['timestamp'])
        row['split'] = 'test' if row['ts'] >= test_since else (
            'valid' if int(digest('cleanup-v2:' + identifier)[:8], 16) % 100 < args.valid_percent else 'train')
        row['has_audio'] = identifier in members or bool(row.get('has_db_audio'))
        if (row.get('status') or '') != 'formatted':
            drop('not_formatted'); continue
        if row.get('hasRevertedAI') or row.get('usedFallbackAsr') or row.get('usedFallbackFormatting'):
            drop('reverted_or_fallback'); continue
        if (row.get('transcriptCommand') or '') not in ('', 'popo', 'ptt'):
            drop('command_or_instruct_mode'); continue
        if squash(row.get('toneMatchedText')):
            drop('tone_matched'); continue
        asr = (row.get('asrText') or '').strip()
        formatted = html_to_plain((row.get('formattedText') or '').strip())
        if not asr or not formatted:
            drop('empty_text'); continue
        language = row.get('detectedLanguage') or ''
        if language != 'en' or looks_dutch(asr) or looks_dutch(formatted):
            # Not trained. Recent ones become routing checks: Flow must pass them through untouched.
            if row['split'] == 'test' and row['has_audio']:
                row['route_expected'] = 'bypass'
                routing.append(row)
            drop('not_english_routed'); continue
        spoken = ' %s ' % ' '.join(words(asr))
        if any(s in formatted.lower() and ' %s ' % ' '.join(words(s)) not in spoken for s in snippets):
            drop('snippet_or_replacement_expanded'); continue
        wispr_style = row_wispr_style(row)
        if wispr_style is None:
            drop('no_wispr_style_recorded'); continue
        if wispr_style != flow_style(row.get('app'), profile):
            drop('wispr_style_differs_from_flow_mapping'); continue
        target, kind = choose_target(formatted, row.get('editedText') or '')
        row['target_raw'], row['target_kind'] = target, kind
        row['is_list'] = bool(re.search(r'(?m)^\s*(?:-|\d+\.)\s+', target))
        if row['is_list'] and row['split'] != 'test' and not args.train_lists:
            # Flow always sends [Structure: prose]; teaching lists under it would blur S1's trained control.
            drop('list_target_not_trained'); continue
        row['code_app'] = is_code_app(row.get('app'))
        if row['code_app'] and (row['split'] == 'test' or not args.train_code_apps):
            drop('code_app_flow_skips_s1'); continue
        selected.append(row)

    if args.materialize_audio:
        output = private_directory(args.output)
        jobs = materialize([r for r in selected + routing if r['has_audio']], members, archive_path,
                           args.reference_db, output)
        print('flow-prepare-input.jsonl: %d clips, %.1f h of audio' % (len(jobs), sum(j['duration_s'] for j in jobs) / 3600))

    # ---- Stage B: inputs, target normalisation, pair filters ----
    kept, seen, control_mismatch, route_skips = [], set(), 0, {}
    for row in selected:
        identifier = row['transcriptEntityId']
        info = prepared.get(identifier)
        control = flow_control(row.get('app'), profile, args.control_policy)
        if info:
            route = info.get('route') or 's1'
            # Flow passes code apps through (skip:code-context), so no s1_input is recorded there.
            # Train-only code-app rows use the text S1 would have seen: Flow's formatted text.
            if route != 's1' and not (row['code_app'] and route == 'skip:code-context'):
                route_skips[route] = route_skips.get(route, 0) + 1
                drop('flow_routes_around_s1'); continue
            source, input_source = info.get('s1_input') or info.get('formatted') or '', info['source']
            if info.get('control_line'):
                control_mismatch += info['control_line'] != control
                control = info['control_line']  # Flow's own choice wins
        elif exact_mode and not args.allow_inexact:
            drop('no_production_input'); continue
        else:
            source, input_source = (row.get('asrText') or '').strip(), 'wispr_asr'
        if not source.strip():
            drop('empty_input'); continue
        if len(source) > 4000:
            drop('over_s1_input_cap'); continue
        target = keep_input_spelling(source, row['target_raw'])
        if flow_style(row.get('app'), profile) == 'veryCasual':
            target = decasualize(target)  # Flow's WisprStyleFormatter re-applies it after S1 for these apps
        problem = pair_problem(source, target, args.min_words, args.max_words, args.max_unsupported)
        if problem:
            drop(problem); continue
        key = ' '.join(words(source))
        if key in seen:
            drop('duplicate'); continue
        seen.add(key)
        row.update(source=source, input_source=input_source, target=target, control=control,
                   tags=hard_tags(source, target, terms))
        kinds[row['target_kind']] = kinds.get(row['target_kind'], 0) + 1
        kept.append(row)

    # Near-duplicates: nothing in train may closely repeat a valid or test row.
    held = [(r['split'], shingles(r['source'])) for r in kept if r['split'] != 'train']
    final = []
    for row in kept:
        if row['split'] == 'train':
            mine = shingles(row['source'])
            if any(mine and other and len(mine & other) / len(mine | other) >= 0.6 for _, other in held):
                drop('near_duplicate_of_eval'); continue
        final.append(row)

    splits = {name: sorted([r for r in final if r['split'] == name], key=lambda r: r['ts'])
              for name in ('train', 'valid', 'test')}
    tag_counts = {}
    for row in splits['test']:
        for tag in row['tags']:
            tag_counts[tag] = tag_counts.get(tag, 0) + 1
    routing_ready = [r for r in routing if r['transcriptEntityId'] in prepared or not exact_mode]
    summary = {
        'built_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
        'production_exact_inputs': exact_mode and all(r['input_source'] != 'wispr_asr' for r in final),
        'input_source': {s: sum(r['input_source'] == s for r in final) for s in ('flow-cli', 'shadow', 'wispr_asr')},
        'rows_in_history': len(rows), 'kept': len(final),
        'splits': {k: len(v) for k, v in splits.items()},
        'test_window': {'days': args.test_days,
                        'since_utc': dt.datetime.fromtimestamp(test_since, dt.timezone.utc).isoformat(timespec='seconds')},
        'test_hard_slice_tags': tag_counts, 'routing_checks': len(routing_ready),
        'target_kind': kinds, 'dropped': dict(sorted(dropped.items())),
        'flow_route_skips': route_skips, 'control_line_mismatch_vs_python_port': control_mismatch,
        'control_lines': {c: sum(r['control'] == c for r in final) for c in sorted({r['control'] for r in final})},
        'code_app_rows_in_train': sum(r['code_app'] for r in splits['train']),
        'unchanged_pairs': sum(squash(r['source']) == squash(r['target']) for r in final),
        'control_policy': args.control_policy, 'system_prompt_sha256': digest(SYSTEM_PROMPT),
    }
    print(json.dumps(summary, indent=2))
    if not args.write:
        print('Counts only. Add --write to create the private files.')
        return

    output = private_directory(args.output)
    private_directory(output / 'grpo')

    def chat(r):
        return {'messages': [{'role': 'system', 'content': SYSTEM_PROMPT},
                             {'role': 'user', 'content': r['control'] + '\n' + r['source']},
                             {'role': 'assistant', 'content': r['target']}]}

    for name, items in splits.items():
        write_jsonl(output / (name + '.jsonl'), [chat(r) for r in items])
    write_jsonl(output / 'test.meta.jsonl', [{
        'id': r['transcriptEntityId'], 'timestamp': r['timestamp'], 'bundle_id': r.get('app'),
        'input_source': r['input_source'], 'target_kind': r['target_kind'], 'control': r['control'],
        'tags': r['tags'], 'wispr_asr': r.get('asrText'), 'wispr_formatted': (r.get('formattedText') or '').strip(),
        'wispr_target_as_pasted': r['target_raw']} for r in splits['test']])
    write_jsonl(output / 'routing.jsonl', [{
        'id': r['transcriptEntityId'], 'bundle_id': r.get('app'), 'language': r.get('detectedLanguage'),
        'input': (prepared.get(r['transcriptEntityId']) or {}).get('s1_input') or r.get('asrText'),
        'expected': 'unchanged by cleanup'} for r in routing_ready])
    write_jsonl(output / 'eval-input.jsonl',
                [{'id': r['transcriptEntityId'], 'text': r['source'], 'bundle_id': r.get('app'), 'slice': 'test'}
                 for r in splits['test']] +
                [{'id': r['transcriptEntityId'], 'bundle_id': r.get('app'), 'slice': 'routing',
                  'text': (prepared.get(r['transcriptEntityId']) or {}).get('s1_input') or r.get('asrText')}
                 for r in routing_ready])
    for name in ('train', 'valid'):
        write_jsonl(output / 'grpo' / (name + '.jsonl'), [
            {'system': SYSTEM_PROMPT, 'prompt': r['control'] + '\n' + r['source'], 'answer': r['target']}
            for r in splits[name]])
    write_private(output / 'summary.json', json.dumps(summary, indent=2) + '\n')
    print('Wrote', output)


if __name__ == '__main__':
    main()
