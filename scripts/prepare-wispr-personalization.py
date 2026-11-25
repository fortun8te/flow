#!/usr/bin/env python3
"""Copy limited Wispr behavior settings and evaluation examples to private storage.

The archive is never extracted. Examples are sensitive personal data and are for
local evaluation only, not instructions or evidence of user approval.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import tempfile
import zipfile

DEST = Path.home() / 'Library/Application Support/VOICE/WisprPersonalization'
MAX_EXAMPLES = 200
MAX_DATA_BYTES = 50 * 1024 * 1024


def private_dir(path):
    # Refuse symlinks at every existing component, including the final directory.
    for item in reversed([path, *path.parents]):
        if item.is_symlink():
            raise ValueError('Refusing a symlink in the private output path')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    if not stat.S_ISDIR(path.stat().st_mode):
        raise ValueError('Private output is not a directory')


def write_private(path, data):
    fd, tmp = tempfile.mkstemp(prefix='.import-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def meetings_from_export(data, archive):
    results = []
    transcript_files = data.get('transcript_files', [])
    with zipfile.ZipFile(archive) as z:
        for index, row in enumerate(data['main_db'].get('meetings', [])):
            if row.get('is_deleted') or not isinstance(row.get('id'), str) or not row['id']:
                continue
            entry = {k: row.get(k) for k in ('id', 'title', 'created_at', 'ended_at', 'recorded_ms', 'primary_language', 'summary', 'notes')}
            entry['source'] = {'member': 'data.json', 'table': 'main_db.meetings', 'index': index}
            entry['transcript_source'] = None
            entry['segments'] = []
            if not row.get('transcript_deleted_at'):
                matches = [f for f in transcript_files if f.get('meeting_id') == row['id'] and isinstance(f.get('arcname'), str)]
                refined = [f for f in matches if f['arcname'].rsplit('/', 1)[-1].startswith('refined-revision-') and f['arcname'].endswith('.ndjson')]
                live = [f for f in matches if f['arcname'].endswith('/live.ndjson')]
                chosen = refined if refined else live
                # Ambiguous versions are deliberately omitted, not guessed.
                if len(chosen) == 1:
                    member = chosen[0]['arcname']
                    infos = [i for i in z.infolist() if i.filename == member]
                    if len(infos) != 1 or infos[0].file_size > 25 * 1024 * 1024:
                        raise ValueError('Ambiguous or oversized transcript member')
                    for line in z.read(infos[0]).splitlines():
                        item = json.loads(line)
                        if not isinstance(item, dict) or not isinstance(item.get('text'), str):
                            continue
                        speaker = item.get('speaker')
                        if isinstance(speaker, dict):
                            speaker = {k: speaker.get(k) for k in ('id', 'name', 'source')}
                        else:
                            speaker = None
                        entry['segments'].append({'timestamp': item.get('timestamp'), 'text': item['text'], 'speaker': speaker})
                    entry['transcript_source'] = {'member': member, 'selection': 'refined' if refined else 'live', 'speaker_labels': 'unverified'}
            results.append(entry)
    return results


def usage_baseline(data, archive_timestamp):
    stats = data['main_db'].get('stats') or {}
    numeric = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
    stat_keys = ('total_words', 'total_duration', 'total_non_empty_duration', 'words_per_minute', 'day_streak', 'week_streak', 'words_this_week')
    daily_keys = ('desktop_word_count', 'mobile_word_count')
    category_keys = ('desktop_apps', 'mobile_apps', 'desktop_apps_word_counts', 'mobile_apps_word_counts')
    daily = []
    for row in data['main_db'].get('user_daily_insights', []):
        item = {'date': row.get('date')}
        item.update({k: row[k] for k in daily_keys if numeric(row.get(k))})
        for k in category_keys:
            if isinstance(row.get(k), dict):
                item[k] = {name: count for name, count in row[k].items() if isinstance(name, str) and numeric(count)}
        daily.append(item)
    profiles = data.get('usage_db', {}).get('voice_profile', [])
    latest = max((v for v in profiles if isinstance(v.get('created_at'), str)), key=lambda v: v['created_at'], default=None)
    voice_keys = ('word_count_milestone', 'headline', 'superpower_title', 'superpower_description', 'peak_time_label', 'peak_time_description', 'peak_time_top_app', 'catch_phrase', 'catch_phrase_description', 'persona', 'most_used_word', 'most_removed_word', 'total_words_at_generation', 'created_at', 'modified_at')
    return {'schema_version': 1, 'kind': 'historical_wispr_baseline',
            'source': {'member': 'data.json', 'archive_member_timestamp': archive_timestamp, 'timestamp_timezone': 'unspecified ZIP timestamp', 'scope': 'Wispr export snapshot'},
            'stats': {k: stats[k] for k in stat_keys if numeric(stats.get(k))},
            'daily_usage': daily,
            'voice_profile': {'source': 'usage_db.voice_profile', 'status': 'historical product-generated narrative; unverified', 'fields': {k: latest.get(k) for k in voice_keys}} if latest else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, help='Wispr export zip')
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as z:
        entries = [x for x in z.infolist() if x.filename == 'data.json']
        if len(entries) != 1 or entries[0].file_size > MAX_DATA_BYTES:
            raise ValueError('Expected one reasonably sized data.json')
        data = json.loads(z.read(entries[0]))
        archive_timestamp = '%04d-%02d-%02dT%02d:%02d:%02d' % entries[0].date_time
    main_db = data['main_db']
    prefs = main_db['preferences']['preferences']
    profile = {'schema_version': 1, 'source': 'Wispr Flow export data.json',
               'auto_cleanup_level': prefs.get('auto_cleanup_level'),
               'personalization_styles': prefs.get('personalization_styles', {}),
               'polish_instructions': prefs.get('polish_instructions', {})}
    dictionary = [{'word': row.get('word'), 'replacement': row.get('replacement')}
                  for row in main_db.get('dictionary', [])
                  if not row.get('is_deleted') and isinstance(row.get('word'), str) and row['word'].strip()]
    examples = []
    counts = {'records': 0, 'eligible': 0, 'excluded': 0}
    for index, row in enumerate(data['usage_db']['polish']):
        counts['records'] += 1
        initial, polished = row.get('polish_initial_text'), row.get('polished_text')
        if (row.get('status') != 'succeeded' or row.get('polish_undone') is not False
                or not isinstance(initial, str) or not initial.strip()
                or not isinstance(polished, str) or not polished.strip()):
            counts['excluded'] += 1
            continue
        counts['eligible'] += 1
        if len(examples) < MAX_EXAMPLES:
            examples.append({'source': {'member': 'data.json', 'table': 'usage_db.polish', 'index': index},
                             'input': initial, 'output': polished})
    meetings = meetings_from_export(data, args.archive)
    baseline = usage_baseline(data, archive_timestamp)
    private_dir(DEST)
    write_private(DEST / 'profile.json', profile)
    write_private(DEST / 'dictionary.json', {'schema_version': 1, 'entries': dictionary})
    write_private(DEST / 'evaluation.json', {'schema_version': 1, 'selection': 'first eligible in export order',
                                            'examples': examples})
    write_private(DEST / 'usage-baseline.json', baseline)
    write_private(DEST / 'meetings.json', {'schema_version': 1, 'meetings': meetings})
    print(f"Imported historical usage for {len(baseline['daily_usage'])} days and {int(baseline['voice_profile'] is not None)} voice profile.")
    print(f"Imported {len(meetings)} nondeleted meetings and {sum(len(m['segments']) for m in meetings)} transcript segments.")
    print(f"Imported settings, {len(dictionary)} active dictionary entries and {len(examples)} evaluation pairs. "
          f"Polish records: {counts['records']}; eligible: {counts['eligible']}; excluded: {counts['excluded']}.")
    print('Private output:', DEST)


if __name__ == '__main__':
    main()
