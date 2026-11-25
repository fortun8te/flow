"""Shared core for DOSE1 T2 synthetic rows. Python standard library only; deterministic by seed.

Principle: corrupt clean text, never clean corrupt text. Each row starts from a clean target.
Every change is an op on a list of Tok objects:
  text  what the model sees (input side)
  tgt   what the target shows; None means the token exists only in the input and is removed
Protected tokens (prot=True) carry a value that must reach the target exactly. Ops may change
how they look in the input (spoken form, dropped apostrophe, casing) but never the value, and
never apply typos to them: a typo in a number would make the target unrecoverable from the input.
"""
from __future__ import annotations

import hashlib
import random
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

SEED = 20261114
PUNCT = ".,?!;:"
SENT_END = ".?!"
EM_DASH = "—"
EMPTY = "EMPTY"

# Rates. "measured" = Jordan's raw Parakeet inputs (WisprCleanupTuning-v2 train, 3,320 rows,
# 105,638 words), read locally, aggregates only. "prior" = planning value, not measured.
DICT_RATES: Dict[str, float] = {
    "soft_filler_per_100": 2.6,        # prior. Measured proxy: 3.3 filler-like words per 100 input words deleted by cleanup (WisprCleanup train), 2.0 (S1 train)
    "uhum_share_of_fillers": 0.08,     # measured um/uh-type tokens only 0.18 per 100 words: Parakeet already drops most of them
    "repeat_per_token": 0.004,         # measured 0.35 immediate repeats per 100 words
    "restart_per_sentence": 0.06,      # prior: restarts are not visible in ASR output
    "self_correction_per_slot": 0.03,  # measured: 3.4% of rows contain a cue phrase
    "cutoff_per_token": 0.0015,        # measured 0.02 dash or ellipsis cut-offs per 100 words
    "homophone_per_token": 0.006,      # prior: per eligible word (HOMOPHONES list only), restored in the target
    "spell_numbers_prob": 0.40,        # measured: 15% of rows have spelled numbers, 36.5% of those keep digits in the target
    "spoken_url_email_prob": 0.70,     # prior
    "lowercase_row": 0.08,             # measured 8.1% of rows all lowercase
    "drop_final_punct": 0.27,          # measured 26.9% of rows without final . ? !
    "run_on_per_boundary": 0.25,       # prior
}

# Typing rates. No Jordan typed samples exist locally, so these are planning values from general
# typing studies (per-keystroke error roughly 1-3% overall, uncorrected share assumed lower).
# They must be tuned against a small real typed sample before use.
TYPE_RATES: Dict[str, float] = {
    "sub_per_char": 0.006,             # light row: about 1 typo per 17 words (all four ops together); heavy rows x3
    "omit_per_char": 0.003,
    "double_per_char": 0.002,
    "transpose_per_pair": 0.002,
    "merge_per_space": 0.01,
    "apostrophe_drop": 0.5,
    "lowercase_row": 0.5,
    "vowel_drop_per_word": 0.08,       # slang rows only
    "heavy_row_share": 0.25,
    "heavy_multiplier": 3.0,
}

FILLER_WORDS = {"um", "uh", "erm", "uhm", "eh", "ehm"}
SOFT_FILLERS = ["like", "so", "basically", "you know", "I mean", "kind of", "sort of", "right", "yeah"]
UHUM_FILLERS = ["um", "uh", "erm", "uhm"]
DUTCH_SOFT_FILLERS = ["eh", "ehm", "dus", "eigenlijk", "nou"]
FILLER_ONLY_POOL = FILLER_WORDS | {w for phrase in SOFT_FILLERS + DUTCH_SOFT_FILLERS for w in phrase.lower().split()}
CUE_REGEX = re.compile(r"(?<![A-Za-z])(no wait|actually no|sorry, no)(?![A-Za-z])", re.I)
FILLER_REGEX = re.compile(r"(?<![\w'])(um|uh|erm|uhm|ehm)(?![\w'])", re.I)

HOMOPHONES = {
    "their": "there", "there": "their", "your": "you're", "you're": "your", "its": "it's", "it's": "its",
    "then": "than", "than": "then", "accept": "except", "affect": "effect", "where": "were", "were": "where",
    "write": "right", "right": "write", "hear": "here", "here": "hear", "to": "too", "too": "to",
    "know": "no", "new": "knew", "sight": "site", "weather": "whether", "which": "witch",
}

# ---- control line -------------------------------------------------------------------------
# Value table v3 (MASTER-PLAN-v3 sections 3.2 and 6.2). One table for the data builder, the trainer, the
# golden-prompt tests and (through golden/flow_requests.json) the app. Level Off never reaches the model.
# Styling changes capitals and punctuation only; it never changes a word.
CONTROL_TABLE_VERSION = 3
CONTROL_RULE_KEYS = {"concise", "clear", "reorder", "structure", "tone"}
POLISH_RULE_ORDER = ("concise", "clear", "reorder", "structure", "tone")
_CTRL_PAIR = re.compile(r"\[([A-Za-z]+): ([^\]]+)\]")
_CLEAN_ALLOWED = {
    "Level": {"light", "medium"},
    "Styling": {"formal", "casual", "very-casual", "excited"},
    "Structure": {"prose", "lists"},
    "Context": {"general", "email"},
}
# What the user sees in Settings -> the value in the control line.
STYLE_UI_NAMES = {"Formal": "formal", "Casual": "casual", "Very casual": "very-casual", "Excited": "excited"}
# Wispr's own identifiers (history rows, imported profile) -> the value in the control line.
STYLE_FROM_WISPR = {"formal": "formal", "casual": "casual", "veryCasual": "very-casual", "genz": "very-casual",
                    "excited": "excited"}
# v2 names found in older rows -> v3. v2's "formal" (contraction expansion) was dropped, so it has no mapping here:
# a v2 row that says formal cannot be told apart from a v3 formal row and must be rebuilt, not migrated.
_V2_STYLING = {"semi-formal": "formal", "semi-casual": "casual"}
_V2_STRUCTURE = {"list": "lists"}
# The default line (plan 6.2): Jordan's level, the neutral style, lists allowed, no email layout.
DEFAULT_CLEAN = {"level": "light", "styling": "formal", "structure": "lists", "context": "general"}
# Opt+1 switch settings by name. "fix_only": every rewrite switch off, tone kept. "jordan": his real setting
# (all 706 runs on Wispr's current model: four switches on, "Maintain your tone" off).
POLISH_PRESETS = {
    "fix_only": {"concise": "off", "clear": "off", "reorder": "off", "structure": "off", "tone": "on"},
    "jordan": {"concise": "on", "clear": "on", "reorder": "on", "structure": "on", "tone": "off"},
}


def control_line(task: str, *, level: str = DEFAULT_CLEAN["level"], styling: str = DEFAULT_CLEAN["styling"],
                 structure: str = DEFAULT_CLEAN["structure"], context: str = DEFAULT_CLEAN["context"],
                 rules: Optional[Dict[str, str]] = None, preset: str = "fix_only") -> str:
    """One function builds every control line, so training and shipped prompts cannot drift.

    clean:  [Task: clean] [Level: ..] [Styling: ..] [Structure: ..] [Context: ..]
    polish: [Task: polish] [Rules: concise=.. clear=.. reorder=.. structure=.. tone=..]   (fixed switch order)
    """
    if task == "clean":
        fields = [("Task", "clean"), ("Level", level), ("Styling", styling),
                  ("Structure", structure), ("Context", context)]
    elif task == "polish":
        switches = dict(POLISH_PRESETS[preset] if rules is None else rules)
        if set(switches) != CONTROL_RULE_KEYS:
            raise ValueError("polish rules must list every switch")
        fields = [("Task", "polish"), ("Rules", " ".join(f"{k}={switches[k]}" for k in POLISH_RULE_ORDER))]
    else:
        raise ValueError(f"unknown task {task!r}")
    line = " ".join(f"[{k}: {v}]" for k, v in fields)
    parse_control_line(line)
    return line


def parse_control_line(line: str) -> Dict[str, str]:
    """Strict parser. Raises ValueError on anything the model must never see."""
    pairs = _CTRL_PAIR.findall(line)
    if not pairs or _CTRL_PAIR.sub("", line).strip():
        raise ValueError(f"malformed control line: {line!r}")
    if line != " ".join(f"[{k}: {v}]" for k, v in pairs):
        raise ValueError(f"control line spacing is not canonical: {line!r}")
    out: Dict[str, str] = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate key {key!r}")
        out[key] = value
    task = out.get("Task")
    if task == "clean":
        if list(out) != ["Task", "Level", "Styling", "Structure", "Context"]:
            raise ValueError("clean line needs exactly Task, Level, Styling, Structure, Context, in that order")
        for key, allowed in _CLEAN_ALLOWED.items():
            if out[key] not in allowed:
                raise ValueError(f"{key}={out[key]!r} not allowed")
    elif task == "polish":
        if list(out) != ["Task", "Rules"]:
            raise ValueError("polish line needs exactly Task and Rules")
        seen: Dict[str, str] = {}
        for rule in out["Rules"].split(" "):
            key, _, value = rule.partition("=")
            if key not in CONTROL_RULE_KEYS or value not in {"on", "off"} or key in seen:
                raise ValueError(f"bad rule {rule!r}")
            seen[key] = value
        if tuple(seen) != POLISH_RULE_ORDER:
            raise ValueError("polish rules must list every switch once, in the fixed order")
    else:
        raise ValueError(f"unknown Task {task!r}")
    return out


def migrate_control_line(line: str) -> str:
    """Rewrites a v2 control line to the v3 names. A line that is already v3 comes back unchanged.
    Raises ValueError if the result is still not a valid v3 line."""
    def swap(match):
        key, value = match.group(1), match.group(2)
        if key == "Styling":
            value = _V2_STYLING.get(value, value)
        elif key == "Structure":
            value = _V2_STRUCTURE.get(value, value)
        return f"[{key}: {value}]"
    out = _CTRL_PAIR.sub(swap, line)
    parse_control_line(out)
    return out


def all_control_lines() -> List[str]:
    """Every control line the app may send (the golden-prompt test covers each one)."""
    lines = [control_line("clean", level=lv, styling=st, structure=sr, context=cx)
             for lv in ("light", "medium") for st in ("formal", "casual", "very-casual", "excited")
             for sr in ("prose", "lists") for cx in ("general", "email")]
    for bits in range(32):
        rules = {k: ("on" if bits >> i & 1 else "off") for i, k in enumerate(POLISH_RULE_ORDER)}
        lines.append(control_line("polish", rules=rules))
    return lines


# ---- deterministic randomness -------------------------------------------------------------
def sub_rng(stream: str, idx: int, attempt: int = 0, seed: int = SEED) -> random.Random:
    digest = hashlib.sha256(f"dose1-t2|{seed}|{stream}|{idx}|{attempt}".encode()).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


# ---- number words ---------------------------------------------------------------------------
_ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen "
         "fourteen fifteen sixteen seventeen eighteen nineteen").split()
_TENS = {2: "twenty", 3: "thirty", 4: "forty", 5: "fifty", 6: "sixty", 7: "seventy", 8: "eighty", 9: "ninety"}
_ORD_SPECIAL = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                "nine": "ninth", "twelve": "twelfth"}


def spoken_int(n: int) -> str:
    if n < 0 or n >= 1_000_000:
        raise ValueError("out of range")
    if n < 20:
        return _ONES[n]
    if n < 100:
        t, o = divmod(n, 10)
        return _TENS[t] + ("" if o == 0 else " " + _ONES[o])
    if n < 1000:
        h, r = divmod(n, 100)
        return f"{_ONES[h]} hundred" + ("" if r == 0 else " " + spoken_int(r))
    th, r = divmod(n, 1000)
    return f"{spoken_int(th)} thousand" + ("" if r == 0 else " " + spoken_int(r))


def spoken_ordinal(n: int) -> str:
    words = spoken_int(n).split()
    last = words[-1]
    if last in _ORD_SPECIAL:
        words[-1] = _ORD_SPECIAL[last]
    elif last.endswith("y"):
        words[-1] = last[:-1] + "ieth"
    else:
        words[-1] = last + "th"
    return " ".join(words)


# ---- slot values ------------------------------------------------------------------------------
FIRST_NAMES = ["Priya", "Tomas", "Elena", "Marco", "Aisha", "Jonas", "Lena", "Ravi", "Sofia", "Ines",
               "Kofi", "Hana", "Dylan", "Mara"]
LAST_NAMES = ["Raman", "Ortiz", "Haddad", "Berg", "Okafor", "Novak", "Lindqvist", "Costa", "Mehta",
              "Walsh", "Brandt"]
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
NEGATIONS = ["do not", "never", "must not"]
URL_PATHS = [("docs", "docs"), ("pricing", "pricing"), ("guide/setup", "guide slash setup"),
             ("workshop/notes", "workshop slash notes")]
CURRENCIES = [("€", "euros"), ("$", "dollars"), ("£", "pounds")]
CUES = ["no wait", "actually no", "sorry, no"]


@dataclass
class Tok:
    text: str
    tgt: Optional[str]
    prot: bool = False
    kind: Optional[str] = None
    value: Optional[str] = None      # protected or superseded value, exact target form (no trailing punctuation)
    spoken: Optional[str] = None     # spoken rendering for the input, when the kind allows one
    suffix: str = ""                 # trailing punctuation merged from the template
    glue: bool = False               # typing: join to the previous token with no space
    superseded: bool = False         # a wrong value the speaker corrects; absent from the target


def _prot(kind: str, value: str, spoken: Optional[str] = None) -> Tok:
    return Tok(text=value, tgt=value, prot=True, kind=kind, value=value, spoken=spoken)


def _url_slot(scheme: str, path: str, spoken_path: str) -> Tok:
    """The spoken input must state the protocol, not hide it in target metadata."""
    if scheme not in ("http", "https"):
        raise ValueError("unsupported synthetic URL scheme")
    return _prot("url", f"{scheme}://example.com/{path}",
                 f"{scheme} colon slash slash example dot com slash {spoken_path}")


def _draw(name: str, rng: random.Random, *, explicit_url_protocol: bool = False) -> Tok:
    if name == "NAME":
        v = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"
        return _prot("name", v)
    if name == "NUM":
        n = rng.randint(2, 9999)
        return _prot("number", str(n), spoken_int(n))
    if name == "MONEY":
        sym, word = rng.choice(CURRENCIES)
        n = rng.randint(5, 9000)
        return _prot("money", f"{sym}{n:,}", f"{spoken_int(n)} {word}")
    if name == "DATE":
        m, d = rng.choice(MONTHS), rng.randint(1, 28)
        return _prot("date", f"{m} {d}", f"{m} {spoken_ordinal(d)}")
    if name == "TIME":
        h, m = rng.randint(1, 12), rng.choice([0, 15, 30, 45])
        spoken = f"{spoken_int(h)} {spoken_int(m)}" if m else f"{spoken_int(h)} o'clock"
        return _prot("time", f"{h}:{m:02d}", spoken)
    if name == "DAY":
        d = rng.choice(WEEKDAYS)
        return _prot("weekday", d)
    if name == "URL":
        path, spoken_path = rng.choice(URL_PATHS)
        if explicit_url_protocol:
            return _url_slot("https", path, spoken_path)
        # Preserve the original generator/fixture contract. New dictation data
        # must explicitly opt into visible protocol recovery through the flag.
        return _prot("url", f"https://example.com/{path}", f"example dot com slash {spoken_path}")
    if name == "EMAIL":
        first, last = rng.choice(FIRST_NAMES).lower(), rng.choice(LAST_NAMES).lower()
        return _prot("email", f"{first}.{last}@example.org", f"{first} dot {last} at example dot org")
    if name == "NEG":
        v = rng.choice(NEGATIONS)
        return _prot("negation", v)
    if name == "DONT":
        return _prot("negation", "don't", "dont")
    raise KeyError(name)


def _draw_different(name: str, rng: random.Random, avoid: str, *, explicit_url_protocol: bool = False) -> Tok:
    for _ in range(50):
        tok = _draw(name, rng, explicit_url_protocol=explicit_url_protocol)
        if tok.value != avoid:
            return tok
    raise RuntimeError("could not draw a different value")


def _correction(base: str, rng: random.Random, *, explicit_url_protocol: bool = False) -> List[Tok]:
    right = _draw(base, rng, explicit_url_protocol=explicit_url_protocol)
    wrong = _draw_different(base, rng, right.value, explicit_url_protocol=explicit_url_protocol)
    wrong_text = (wrong.spoken or wrong.value) + ","
    return [
        Tok(text=wrong_text, tgt=None, kind="superseded", value=wrong.value, superseded=True),
        Tok(text=rng.choice(CUES) + ",", tgt=None),
        right,
    ]


def slot_tokens(name: str, rng: random.Random, self_correction_rate: float, *, explicit_url_protocol: bool = False) -> List[Tok]:
    if name.startswith("CORR_"):
        return _correction(name[len("CORR_"):], rng, explicit_url_protocol=explicit_url_protocol)
    if name in ("DAY", "NUM") and self_correction_rate and rng.random() < self_correction_rate:
        return _correction(name, rng, explicit_url_protocol=explicit_url_protocol)
    return [_draw(name, rng, explicit_url_protocol=explicit_url_protocol)]


_SLOT = re.compile(r"(\{[A-Z_0-9]+\})")
_PUNCT_ONLY = re.compile(r"^[.,?!;:]+$")


def attach_punct(toks: List[Tok]) -> List[Tok]:
    """Punctuation split off a slot ("{NUM}.") joins the protected token before it."""
    out: List[Tok] = []
    for t in toks:
        if out and out[-1].prot and _PUNCT_ONLY.match(t.text) and not t.prot and t.tgt == t.text:
            prev = out[-1]
            prev.text += t.text
            prev.tgt = (prev.tgt or "") + t.text
            prev.suffix += t.text
        else:
            out.append(t)
    return out


def tokens_from_template(template: str, rng: random.Random, self_correction_rate: float = 0.0,
                         *, explicit_url_protocol: bool = False) -> List[Tok]:
    toks: List[Tok] = []
    for part in _SLOT.split(template):
        if not part:
            continue
        if _SLOT.fullmatch(part):
            toks.extend(slot_tokens(part[1:-1], rng, self_correction_rate,
                                    explicit_url_protocol=explicit_url_protocol))
        else:
            toks.extend(Tok(text=w, tgt=w) for w in part.split())
    return attach_punct(toks)


def whole_sentence_token(sentence: str, kind: str) -> Tok:
    """Literal-cue and instruction-as-text sentences are protected as one unit."""
    return Tok(text=sentence, tgt=sentence, prot=True, kind=kind, value=sentence)


# ---- shared helpers ---------------------------------------------------------------------------
def join_target(toks: List[Tok]) -> str:
    kept = [t.tgt for t in toks if t.tgt is not None]
    text = " ".join(kept)
    text = re.sub(r"\s+", " ", text).strip()
    return text if text else EMPTY


def join_input(toks: List[Tok]) -> str:
    out = ""
    for t in toks:
        if not out:
            out = t.text
        elif t.glue:
            out += t.text
        else:
            out += " " + t.text
    return re.sub(r"\s+", " ", out).strip()


def protected_entries(toks: List[Tok]) -> List[dict]:
    entries: List[dict] = []
    for t in toks:
        if t.prot:
            core = t.value.rstrip(PUNCT)
            entry = {"kind": t.kind, "value": core}
            icore = t.text.rstrip(PUNCT)
            if icore != core:
                entry["input"] = icore
            entries.append(entry)
        elif t.superseded:
            entries.append({"kind": "superseded", "value": t.value})
    return entries


def _insert_all(toks: List[Tok], inserts: List[Tuple[int, List[Tok]]]) -> None:
    for idx, group in sorted(inserts, key=lambda x: x[0], reverse=True):
        toks[idx:idx] = group


def _swap_word(text: str, alt: str) -> str:
    m = re.match(r"^([A-Za-z']+)(.*)$", text)
    if not m:
        return text
    core, rest = m.group(1), m.group(2)
    new = alt[0].upper() + alt[1:] if core[0].isupper() else alt
    return new + rest


# ---- dictation ops ----------------------------------------------------------------------------
def dictation_ops(toks: List[Tok], rng: random.Random, rates: Dict[str, float], dutch: bool = False) -> Tuple[List[Tok], List[dict]]:
    counts: Dict[str, int] = {}

    def bump(name: str, n: int = 1) -> None:
        if n:
            counts[name] = counts.get(name, 0) + n

    n_corr = sum(1 for t in toks if t.superseded)
    bump("self_correction", n_corr)

    # 1. spelled numbers and spoken URLs/emails (protected values keep their target form)
    for t in toks:
        if not (t.prot and t.spoken):
            continue
        if t.kind in ("number", "money", "time", "date") and rng.random() < rates["spell_numbers_prob"]:
            t.text = t.spoken + t.suffix
            bump("spell_number")
        elif t.kind in ("url", "email") and rng.random() < rates["spoken_url_email_prob"]:
            t.text = t.spoken + t.suffix
            bump("spoken_link")

    # 2. recognizer confusion on ordinary words, restored in the target
    for t in toks:
        if t.prot or t.tgt is None or t.superseded:
            continue
        core = re.match(r"^([A-Za-z']+)", t.text)
        if core and core.group(1).lower() in HOMOPHONES and rng.random() < rates["homophone_per_token"]:
            t.text = _swap_word(t.text, HOMOPHONES[core.group(1).lower()])
            bump("homophone")

    # 3. repeats, restarts, cut-off starts (input-only tokens)
    inserts: List[Tuple[int, List[Tok]]] = []
    for i, t in enumerate(toks):
        if t.prot or t.tgt is None or t.superseded:
            continue
        if rng.random() < rates["repeat_per_token"]:
            inserts.append((i, [Tok(text=t.text, tgt=None)]))
            bump("repeat")
        word = t.text.rstrip(PUNCT)
        if word.isalpha() and len(word) >= 6 and rng.random() < rates["cutoff_per_token"]:
            inserts.append((i, [Tok(text=word[:3] + "-", tgt=None)]))
            bump("cutoff_start")
    starts = [0] + [i + 1 for i, t in enumerate(toks) if t.tgt and t.tgt[-1] in SENT_END]
    for s in starts:
        if s + 1 >= len(toks) or toks[s].prot or toks[s + 1].prot:
            continue
        if rng.random() < rates["restart_per_sentence"]:
            k = rng.choice([1, 2])
            if all(not toks[s + j].prot and toks[s + j].tgt is not None for j in range(k)):
                group = [Tok(text=toks[s + j].text.rstrip(PUNCT) + ",", tgt=None) for j in range(k)]
                inserts.append((s, group))
                bump("restart")
    _insert_all(toks, inserts)

    # 4. soft fillers, at random positions, mostly soft words and rarely um/uh
    n_target = sum(1 for t in toks if t.tgt is not None)
    lam = rates["soft_filler_per_100"] * n_target / 100.0
    k = int(lam) + (1 if rng.random() < lam - int(lam) else 0)
    for _ in range(k):
        if rng.random() < rates["uhum_share_of_fillers"]:
            word = rng.choice(UHUM_FILLERS)
        else:
            word = rng.choice(DUTCH_SOFT_FILLERS if dutch else SOFT_FILLERS)
        if rng.random() < 0.5:
            word += ","
        pos = rng.randint(0, len(toks))
        toks.insert(pos, Tok(text=word, tgt=None))
        bump("filler")

    # 5. run-on sentences: drop the boundary in the input, keep it in the target
    for i in range(len(toks) - 1):
        t = toks[i]
        if not (t.tgt and t.tgt[-1] in SENT_END and t.tgt is not None):
            continue
        if rng.random() < rates["run_on_per_boundary"]:
            t.text = t.text.rstrip(PUNCT)
            j = next((x for x in range(i + 1, len(toks)) if toks[x].tgt is not None), None)
            if j is not None:
                nxt = toks[j]
                if not nxt.prot and nxt.text[:1].isupper() and not nxt.text.startswith("I") and nxt.text[:2] != "I'":
                    nxt.text = nxt.text[0].lower() + nxt.text[1:]
            bump("run_on")

    # 6. recognizer casing and final punctuation
    if rng.random() < rates["lowercase_row"]:
        for t in toks:
            t.text = t.text.lower()
        bump("lowercase_row")
    last = next((x for x in range(len(toks) - 1, -1, -1) if toks[x].tgt is not None), None)
    if last is not None and rng.random() < rates["drop_final_punct"]:
        toks[last].text = toks[last].text.rstrip(PUNCT)
        bump("drop_final_punct")

    ops = [{"op": name, "n": n} for name, n in counts.items()]
    return toks, ops


# ---- typing ops -------------------------------------------------------------------------------
_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
_OFFS = [0.0, 0.25, 0.75]


def _neighbours() -> Dict[str, List[str]]:
    pos = {}
    for r, row in enumerate(_ROWS):
        for c, ch in enumerate(row):
            pos[ch] = (r, c + _OFFS[r])
    out: Dict[str, List[str]] = {}
    for a, (ra, xa) in pos.items():
        out[a] = [b for b, (rb, xb) in pos.items() if b != a and (
            (ra == rb and abs(xa - xb) == 1) or (abs(ra - rb) == 1 and abs(xa - xb) <= 0.75))]
    return out


NEIGHBOURS = _neighbours()


def _neighbour(c: str, rng: random.Random) -> str:
    low = c.lower()
    if low not in NEIGHBOURS:
        return c
    alt = rng.choice(NEIGHBOURS[low])
    return alt.upper() if c.isupper() else alt


def _typo_word(word: str, rng: random.Random, mult: float, counts: Dict[str, int]) -> str:
    out: List[str] = []
    for c in word:
        if not c.isalpha():
            out.append(c)
            continue
        r = rng.random()
        ps = TYPE_RATES["sub_per_char"] * mult
        po = TYPE_RATES["omit_per_char"] * mult
        pd = TYPE_RATES["double_per_char"] * mult
        if r < ps:
            out.append(_neighbour(c, rng))
            counts["substitute"] = counts.get("substitute", 0) + 1
        elif r < ps + po:
            counts["omit"] = counts.get("omit", 0) + 1
        elif r < ps + po + pd:
            out.extend([c, c])
            counts["double"] = counts.get("double", 0) + 1
        else:
            out.append(c)
    arr = out[:]
    j = 0
    while j < len(arr) - 1:
        if arr[j].isalpha() and arr[j + 1].isalpha() and rng.random() < TYPE_RATES["transpose_per_pair"] * mult:
            arr[j], arr[j + 1] = arr[j + 1], arr[j]
            counts["transpose"] = counts.get("transpose", 0) + 1
            j += 2
        else:
            j += 1
    return "".join(arr)


def typing_ops(toks: List[Tok], rng: random.Random, category: str, heavy: bool) -> List[dict]:
    rates = TYPE_RATES
    mult = rates["heavy_multiplier"] if heavy else 1.0
    counts: Dict[str, int] = {}

    # 1. typos on ordinary words. Protected values are never touched.
    for t in toks:
        if t.prot or t.tgt is None or len(re.sub(r"[^A-Za-z]", "", t.text)) < 2:
            continue
        new = _typo_word(t.text, rng, mult, counts)
        t.text = new
    # 2. dropped apostrophes, including protected negations ("don't" typed as "dont")
    for t in toks:
        if "'" in t.text and rng.random() < rates["apostrophe_drop"]:
            t.text = t.text.replace("'", "", 1)
            counts["apostrophe"] = counts.get("apostrophe", 0) + 1
    # 3. vowel drops in slang rows only
    if category == "slang":
        for t in toks:
            if t.prot or t.tgt is None:
                continue
            core = t.text.rstrip(PUNCT)
            if core.isalpha() and len(core) >= 4 and rng.random() < rates["vowel_drop_per_word"]:
                idx = next((i for i in range(1, len(core) - 1) if core[i] in "aeiouAEIOU"), None)
                if idx is not None:
                    t.text = core[:idx] + core[idx + 1:] + t.text[len(core):]
                    counts["vowel_drop"] = counts.get("vowel_drop", 0) + 1
    # 4. merged words (space dropped), ordinary words only
    for i in range(len(toks) - 1):
        a, b = toks[i], toks[i + 1]
        if a.prot or b.prot or a.tgt is None or b.tgt is None:
            continue
        if rng.random() < rates["merge_per_space"]:
            b.glue = True
            counts["merge"] = counts.get("merge", 0) + 1
    # 5. all lowercase
    if rng.random() < rates["lowercase_row"]:
        for t in toks:
            t.text = t.text.lower()
        counts["lowercase_row"] = 1
    return [{"op": name, "n": n} for name, n in counts.items()]
