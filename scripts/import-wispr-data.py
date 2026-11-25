#!/usr/bin/env python3
"""Merge Wispr Flow's local data into Flow. Safe to run again: it only adds what is missing.

History text (not audio) becomes dictation rows in voice.db, tagged ["wispr"] and keeping
Wispr's own row id, so Companion shows each dictation once. Dictionary words go to Flow's word
list, and snippets and word replacements go to replacements.json where Companion can edit them.
Wispr's database is opened read-only and never changed.
"""
import json, os, sqlite3, subprocess, sys, uuid
from pathlib import Path

home = Path.home()
wispr = home / 'Library/Application Support/Wispr Flow/flow.sqlite'
voice_dir = home / 'Library/Application Support/VOICE'
voice = voice_dir / 'voice.db'
dry = '--dry-run' in sys.argv
if not wispr.exists(): sys.exit('Wispr Flow history not found; nothing to merge.')
src = sqlite3.connect(f'file:{wispr}?mode=ro', uri=True)
dst = sqlite3.connect(voice, timeout=30)

# --- history ---
have = {row[0].lower() for row in dst.execute('SELECT id FROM meetings')}
rows = src.execute("""
    SELECT transcriptEntityId, timestamp, app, duration, asrText, formattedText, editedText
    FROM History WHERE status IN ('formatted','raw_transcript') AND COALESCE(isArchived,0) = 0
""").fetchall()
added = 0
for rid, stamp, app, duration, asr, formatted, edited in rows:
    if not rid or rid.lower() in have: continue
    raw = (asr or formatted or edited or '').strip()
    final = (edited or formatted or '').strip() or None
    if not raw and not final: continue
    date = (stamp or '').replace(' +00:00', '')
    if not dry:
        dst.execute("""INSERT INTO meetings (id, title, date, duration, kind, tagsJson, sourceApp, finalText)
                       VALUES (?, 'Dictation', ?, ?, 'dictation', '["wispr"]', ?, ?)""",
                    (rid, date, float(duration or 0), app, final))
        dst.execute("""INSERT INTO segments (id, meetingId, speaker, text, startTime, endTime, isFinal)
                       VALUES (?, ?, 'Speaker 1', ?, 0, ?, 1)""",
                    (str(uuid.uuid4()).upper(), rid, raw or final, float(duration or 0)))
    added += 1
if not dry: dst.commit()

# --- dictionary and snippets ---
words, rules = [], []
for phrase, replacement, snippet in src.execute(
        "SELECT phrase, replacement, isSnippet FROM Dictionary WHERE COALESCE(isDeleted,0) = 0"):
    phrase = (phrase or '').strip(); replacement = (replacement or '').strip()
    if not phrase: continue
    if snippet or (replacement and replacement != phrase): rules.append((phrase, replacement))
    else: words.append(phrase)

domain = 'com.example.flow'
try: current = json.loads(subprocess.check_output(
        ['plutil', '-extract', 'userProperNouns', 'json', '-o', '-', str(home / f'Library/Preferences/{domain}.plist')],
        stderr=subprocess.DEVNULL))
except Exception: current = []
lower = {w.lower() for w in current}
new_words = [w for w in words if w.lower() not in lower]
if new_words and not dry:
    subprocess.check_call(['defaults', 'write', domain, 'userProperNouns', '-array', *(current + new_words)])

folder = voice_dir / 'Wispr Import'
path = folder / 'replacements.json'
existing = json.loads(path.read_text()) if path.exists() else []
known = {e.get('from', '').lower() for e in existing}
new_rules = [{'from': f, 'to': t, 'source': 'pure'} for f, t in rules if t and f.lower() not in known]
if new_rules and not dry:
    folder.mkdir(mode=0o700, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(existing + new_rules, indent=2, ensure_ascii=False))
    os.chmod(tmp, 0o600); tmp.replace(path)

print(json.dumps(dict(dryRun=dry, historyAdded=added, historyAlready=len(rows) - added,
                      wordsAdded=len(new_words), rulesAdded=len(new_rules))))
