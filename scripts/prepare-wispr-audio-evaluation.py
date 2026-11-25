#!/usr/bin/env python3
"""Prepare a small, private saved-audio evaluation manifest without extracting a ZIP.

Historical ASR, formatted and edited text are separate unverified hypotheses.
They are never silently promoted to human references or training instructions.
"""
import argparse
import collections
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import tempfile
import wave
import zipfile

DEFAULT_OUTPUT = Path.home() / 'Library/Application Support/VOICE/WisprAudioEvaluation'
MAX_JSON_BYTES = 50 * 1024 * 1024
MAX_AUDIO_BYTES = 50 * 1024 * 1024
MINIMUM_FREE_BYTES = 4 * 1024 ** 3
SUCCESS = {'formatted', 'raw_transcript', 'succeeded', 'success', 'completed'}
HISTORY_FIELDS = (
    'transcriptEntityId', 'asrText', 'formattedText', 'editedText', 'timestamp',
    'status', 'language', 'detectedLanguage', 'hasRevertedAI', 'usedFallbackAsr',
    'usedFallbackFormatting', 'desiredAsr', 'desiredFormatted', 'speechDuration',
    'duration', 'editedTextStatus', 'transcriptOrigin', 'isDeleted', 'deletedAt',
)


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def source_split(identifier):
    return 'tuning' if int(digest(identifier)[:8], 16) % 5 == 0 else 'evaluation'


def private_directory(path):
    path = path.expanduser().absolute()
    for component in reversed([path, *path.parents]):
        if component.is_symlink():
            raise ValueError('Refusing a symlink in the output path')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid() or not stat.S_ISDIR(path.stat().st_mode):
        raise ValueError('Output directory must belong to this user')
    path.chmod(0o700)
    return path


def write_private(path, value):
    if path.is_symlink():
        raise ValueError('Refusing a symlink output file')
    fd, temporary = tempfile.mkstemp(prefix='.evaluation-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as file:
            json.dump(value, file, ensure_ascii=False, sort_keys=True, indent=2)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def unique_member(archive, name, maximum):
    matches = [item for item in archive.infolist() if item.filename == name]
    if len(matches) != 1 or matches[0].file_size > maximum:
        raise ValueError('Missing, duplicate or oversized archive metadata')
    return matches[0]


def safe_audio_name(name):
    parts = PurePosixPath(name).parts
    return (len(parts) == 3 and parts[0] == 'dictations'
            and parts[1] not in ('', '.', '..') and '\\' not in name
            and re.fullmatch(r'audio-[A-Za-z0-9_-]+\.wav', parts[2]) is not None)


def normalize_history(row):
    """Known source field names only; never read screenshots, URLs, context or audio blobs."""
    identifier = row.get('transcriptEntityId') or row.get('id')
    if not isinstance(identifier, str) or not identifier:
        return None
    aliases = {'asrText': 'raw_asr_text', 'raw_asr_text': 'raw_asr_text',
               'formattedText': 'formatted_text', 'formatted_text': 'formatted_text',
               'editedText': 'edited_text', 'edited_text': 'edited_text'}
    result = {'id': identifier, 'status': row.get('status'),
              'deleted': bool(row.get('isDeleted') or row.get('is_deleted')
                              or row.get('deletedAt') or row.get('deleted_at')),
              'texts': {}, 'metadata': {}}
    for key, target in aliases.items():
        value = row.get(key)
        if isinstance(value, str):
            if len(value) > 100_000:
                result['oversized_text'] = True
            else:
                result['texts'][target] = value
    for key in HISTORY_FIELDS:
        if key not in aliases and key not in ('transcriptEntityId', 'status', 'isDeleted', 'deletedAt'):
            value = row.get(key)
            if value is None or isinstance(value, (bool, int, float)):
                if not isinstance(value, float) or math.isfinite(value):
                    result['metadata'][key] = value
            elif isinstance(value, str) and len(value) <= 200:
                result['metadata'][key] = value
    # Generic export aliases are only supported for explicit metadata, never inferred.
    for key in ('language', 'detected_language', 'noise_condition'):
        if isinstance(row.get(key), str) and len(row[key]) <= 40:
            result['metadata'][key] = row[key]
    return result


def history_rows(data, reference_db=None):
    rows = []
    source = {'kind': 'export_usage_db_history', 'rows': 0}
    if reference_db is not None:
        database = reference_db.expanduser().absolute()
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute('PRAGMA query_only=ON')
            columns = {row['name'] for row in connection.execute('PRAGMA table_info(History)')}
            if 'transcriptEntityId' not in columns:
                raise ValueError('Reference database lacks the supported History schema')
            fields = [field for field in HISTORY_FIELDS if field in columns]
            # Identifiers are selected only from the constant whitelist above.
            cursor = connection.execute('SELECT ' + ','.join('"' + f + '"' for f in fields) + ' FROM History')
            for row in cursor:
                if len(rows) >= 100_000:
                    raise ValueError('Reference history is too large')
                rows.append(dict(row))
        source = {'kind': 'local_wispr_history_read_only', 'rows': len(rows),
                  'selected_columns': fields, 'snapshot': 'single read-only SELECT; no migration'}
    else:
        usage = data.get('usage_db', {})
        candidate = usage.get('history', []) if isinstance(usage, dict) else []
        if isinstance(candidate, list):
            rows = [row for row in candidate if isinstance(row, dict)]
        source['rows'] = len(rows)
    indexed = collections.defaultdict(list)
    for row in rows:
        normalized = normalize_history(row)
        if normalized:
            indexed[normalized['id']].append(normalized)
    normalized_rows = [row for group in indexed.values() for row in group]
    source['selected_fields_sha256'] = digest('\n'.join(sorted(
        json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(',', ':')) for row in normalized_rows)))
    return indexed, source


def language_of(history):
    metadata = history.get('metadata', {}) if history else {}
    value = metadata.get('detectedLanguage') or metadata.get('detected_language') or metadata.get('language')
    return value if isinstance(value, str) and value else None


def duration_bucket(seconds):
    return 'under_5s' if seconds < 5 else '5_to_15s' if seconds < 15 else '15_to_45s' if seconds < 45 else '45s_or_more'


def prepare_manifest(archive_path, reference_db=None, max_clips=24, max_seconds=600):
    if type(max_clips) is not int or not 1 <= max_clips <= 96:
        raise ValueError('max-clips must be between 1 and 96')
    if not math.isfinite(max_seconds) or not 0 < max_seconds <= 3600:
        raise ValueError('max-seconds must be greater than zero and at most 3600')
    excluded = collections.Counter()
    candidates = []
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        if len(infos) > 50_000:
            raise ValueError('Archive has too many members')
        data_member = unique_member(archive, 'data.json', MAX_JSON_BYTES)
        raw_data = archive.read(data_member)
        data = json.loads(raw_data)
        if not isinstance(data, dict):
            raise ValueError('Unsupported export metadata')
        history, history_source = history_rows(data, reference_db)
        manifest_statuses = collections.defaultdict(list)
        manifest_entries = []
        export_manifest_truncated = None
        if any(item.filename == 'manifest.json' for item in infos):
            exported_manifest = json.loads(archive.read(unique_member(archive, 'manifest.json', MAX_JSON_BYTES)))
            if not isinstance(exported_manifest, dict):
                raise ValueError('Unsupported export manifest')
            export_manifest_truncated = exported_manifest.get('truncated')
            manifest_entries = exported_manifest.get('entries', [])
            if not isinstance(manifest_entries, list):
                raise ValueError('Unsupported export member entries')
            for row in manifest_entries:
                if isinstance(row, dict) and isinstance(row.get('arcname'), str):
                    manifest_statuses[row['arcname']].append(row.get('status'))
        names = collections.Counter(item.filename for item in infos)
        wav_count = 0
        for info in sorted(infos, key=lambda item: item.filename):
            if not info.filename.startswith('dictations/') or not info.filename.endswith('.wav'):
                continue
            wav_count += 1
            if names[info.filename] != 1 or not safe_audio_name(info.filename):
                excluded['unsafe_or_duplicate_member'] += 1
                continue
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode) or info.file_size > MAX_AUDIO_BYTES:
                excluded['symlink_or_oversized_audio'] += 1
                continue
            statuses = manifest_statuses.get(info.filename, [])
            if statuses and (len(statuses) != 1 or statuses[0] != 'included'):
                excluded['not_included_in_export'] += 1
                continue
            identifier = PurePosixPath(info.filename).parts[1]
            matched = history.get(identifier, [])
            if len(matched) > 1:
                excluded['ambiguous_history_join'] += 1
                continue
            row = matched[0] if matched else None
            if row and row['deleted']:
                excluded['deleted_history'] += 1
                continue
            if row and row.get('oversized_text'):
                excluded['oversized_history_text'] += 1
                continue
            if row and row['status'] not in SUCCESS:
                excluded['failed_dismissed_empty_or_unfinished_history'] += 1
                continue
            if row and not any(value.strip() for value in row['texts'].values()):
                excluded['empty_history_text'] += 1
                continue
            if reference_db is not None and row is None:
                excluded['unmatched_reference_database'] += 1
                continue
            try:
                with archive.open(info) as stream, wave.open(stream) as audio:
                    frames, rate = audio.getnframes(), audio.getframerate()
                    channels, sample_width = audio.getnchannels(), audio.getsampwidth()
                    if frames <= 0 or rate <= 0 or channels <= 0 or sample_width <= 0:
                        raise ValueError('Invalid WAV metadata')
                    seconds = frames / rate
            except (wave.Error, EOFError, ValueError, OSError):
                excluded['invalid_or_empty_wav'] += 1
                continue
            if not math.isfinite(seconds) or seconds < 0.25 or seconds > max_seconds:
                excluded['duration_outside_bounds'] += 1
                continue
            candidates.append({'source_id': identifier, 'archive_member': info.filename,
                'archive_crc32': info.CRC, 'archive_bytes': info.file_size,
                'duration_seconds': round(seconds, 6), 'sample_rate': rate,
                'channels': channels, 'sample_width_bytes': sample_width,
                'language': language_of(row), 'language_status': 'source_detected_unverified' if language_of(row) else 'unavailable',
                'noise_condition': row.get('metadata', {}).get('noise_condition') if row else None,
                'history': {'source': history_source['kind'], 'status': row['status'],
                            'texts': row['texts'], 'metadata': row['metadata']} if row else None,
                'human_reference': None, 'reference_status': 'historical_hypotheses_only' if row else 'unavailable',
                'eligible_for_ground_truth_metrics': False})

    # Union repeated source IDs, same CRC/size audio, and identical substantial
    # ASR text. This is a conservative leakage guard, not proof of audio identity.
    parent = {row['source_id']: row['source_id'] for row in candidates}
    def find(key):
        while parent[key] != key:
            parent[key] = parent[parent[key]]
            key = parent[key]
        return key
    def union(a, b):
        a, b = find(a), find(b)
        if a != b:
            parent[max(a, b)] = min(a, b)
    fingerprints = {}
    for row in candidates:
        keys = [('zip_crc32_size', row['archive_crc32'], row['archive_bytes'])]
        text = ((row['history'] or {}).get('texts') or {}).get('raw_asr_text', '')
        normalized = ' '.join(text.casefold().split())
        if len(normalized) >= 20:
            keys.append(('normalized_asr_text', digest(normalized)))
        for key in keys:
            if key in fingerprints:
                union(row['source_id'], fingerprints[key])
            else:
                fingerprints[key] = row['source_id']
    members = collections.defaultdict(set)
    for identifier in parent:
        members[find(identifier)].add(identifier)
    groups = collections.defaultdict(list)
    for row in candidates:
        group_id = digest('\n'.join(sorted(members[find(row['source_id'])])))
        row['dedupe_group'] = group_id
        groups[group_id].append(row)
    representatives = []
    for rows in groups.values():
        splits = {source_split(row['source_id']) for row in rows}
        # A source ID must not switch from held-out evaluation into tuning
        # when another export adds a duplicate. Hold mixed-split groups out.
        if len(splits) != 1:
            excluded['dedupe_group_crosses_stable_splits'] += len(rows)
            continue
        chosen = min(rows, key=lambda row: digest(row['archive_member']))
        chosen['split'] = splits.pop()
        chosen['dedupe_group_source_count'] = len({row['source_id'] for row in rows})
        representatives.append(chosen)
        excluded['deduplicated_audio_or_source'] += len(rows) - 1
    buckets = collections.defaultdict(list)
    for row in representatives:
        language = row['language'] or 'unknown'
        # Exact language labels remain in records; only bucket grouping is broad.
        language_group = language if language in ('en', 'nl') else 'other' if row['language'] else 'unknown'
        buckets[(row['split'], language_group, duration_bucket(row['duration_seconds']))].append(row)
    for rows in buckets.values():
        rows.sort(key=lambda row: digest(row['dedupe_group'] + ':' + row['archive_member']))
    selected, total = [], 0.0
    ordered_keys = sorted(buckets)
    while len(selected) < max_clips:
        added = False
        for key in ordered_keys:
            rows = buckets[key]
            while rows:
                row = rows.pop(0)
                if total + row['duration_seconds'] > max_seconds + 1e-6:
                    continue
                selected.append(row)
                total += row['duration_seconds']
                added = True
                break
            if len(selected) >= max_clips:
                break
        if not added:
            break
    selected.sort(key=lambda row: (row['split'], row['dedupe_group']))
    aggregate = {'archive_wav_members': wav_count, 'eligible_before_deduplication': len(candidates),
        'dedupe_groups': len(groups), 'selected_clips': len(selected), 'selected_audio_seconds': round(total, 6),
        'split_counts': dict(sorted(collections.Counter(row['split'] for row in selected).items())),
        'language_counts': dict(sorted(collections.Counter(row['language'] or 'unknown' for row in selected).items())),
        'selected_with_history': sum(row['history'] is not None for row in selected),
        'ground_truth_references': 0, 'excluded': dict(sorted(excluded.items()))}
    return {'schema_version': 1, 'kind': 'private_saved_audio_evaluation_manifest',
        'archive': {'size_bytes': Path(archive_path).stat().st_size, 'data_json_sha256': hashlib.sha256(raw_data).hexdigest(),
                    'export_manifest_truncated': export_manifest_truncated},
        'history_source': history_source, 'limits': {'max_clips': max_clips, 'max_audio_seconds': max_seconds},
        'selection': 'deterministic stratified round-robin by split, stored language and duration; not a representative random sample',
        'split_policy': 'SHA256 source ID modulo 5: bucket zero tuning, other buckets evaluation; exclude dedupe groups crossing splits; never tune on evaluation',
        'deduplication': 'source ID, ZIP CRC32+size and normalized ASR text >=20 characters; conservative grouping, not a cryptographic equality claim',
        'reference_policy': 'Raw ASR, product-formatted and edited text remain unverified historical hypotheses. No human reference is present. Do not call disagreement WER or train automatically.',
        'metadata_limits': 'No language/noise inference. Deleted/failure filters apply only when explicit source metadata is available. No screenshots, URLs, cursor/app context, credentials or audio blobs selected from the reference database.',
        'aggregate': aggregate, 'clips': selected}


def materialize_selected(archive_path, manifest, output, minimum_free_bytes=MINIMUM_FREE_BYTES):
    output = private_directory(output)
    audio_dir = private_directory(output / 'audio')
    clips = manifest['clips']
    required = sum(row['archive_bytes'] for row in clips)
    if shutil.disk_usage(output).free < minimum_free_bytes + required:
        raise ValueError('Not enough free space to materialize audio while preserving the reserve')
    with zipfile.ZipFile(archive_path) as archive:
        for row in clips:
            info = unique_member(archive, row['archive_member'], MAX_AUDIO_BYTES)
            if info.CRC != row['archive_crc32'] or info.file_size != row['archive_bytes']:
                raise ValueError('Archive changed after manifest preparation')
            destination = audio_dir / (digest(row['archive_member']) + '.wav')
            if destination.is_symlink():
                raise ValueError('Refusing a symlink audio destination')
            if shutil.disk_usage(output).free < minimum_free_bytes + info.file_size:
                raise ValueError('Disk reserve reached; original archive is preserved')
            fd, temporary = tempfile.mkstemp(prefix='.audio-', dir=audio_dir)
            hasher = hashlib.sha256()
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, 'wb') as target, archive.open(info) as source:
                    while block := source.read(1024 * 1024):
                        target.write(block)
                        hasher.update(block)
                if destination.exists():
                    existing = hashlib.sha256()
                    with destination.open('rb') as file:
                        while block := file.read(1024 * 1024):
                            existing.update(block)
                    if existing.digest() != hasher.digest():
                        raise ValueError('Existing audio differs; refusing overwrite')
                else:
                    os.replace(temporary, destination)
                destination.chmod(0o600)
                row['local_audio'] = 'audio/' + destination.name
                row['audio_sha256'] = hasher.hexdigest()
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--reference-db', type=Path, help='Explicit optional local Wispr flow.sqlite, read-only')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--max-clips', type=int, default=24)
    parser.add_argument('--max-seconds', type=float, default=600)
    parser.add_argument('--materialize', action='store_true', help='Copy only selected WAVs, with a 4 GiB free-space reserve')
    args = parser.parse_args()
    try:
        manifest = prepare_manifest(args.archive, args.reference_db, args.max_clips, args.max_seconds)
        output = private_directory(args.output)
        if args.materialize:
            manifest = materialize_selected(args.archive, manifest, output)
        write_private(output / 'manifest.json', manifest)
        print(json.dumps({'status': 'prepared', 'materialized': args.materialize, **manifest['aggregate']}, sort_keys=True))
    except (ValueError, OSError, sqlite3.Error, zipfile.BadZipFile, json.JSONDecodeError):
        # Exceptions and inputs may contain private paths or source text.
        print(json.dumps({'status': 'failed', 'reason': 'Evaluation preparation failed; sources were not modified.'}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
