import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
from unittest import mock
import wave
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-wispr-audio-evaluation.py'
SPEC = importlib.util.spec_from_file_location('wispr_audio_evaluation', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def wav(seconds, seed=1):
    result = io.BytesIO()
    with wave.open(result, 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(struct.pack('<h', seed) * int(seconds * 16_000))
    return result.getvalue()


class WisprAudioEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / 'export.zip'

    def tearDown(self):
        self.temp.cleanup()

    def make_archive(self, recordings, history=()):
        data = {'usage_db': {'history': list(history), 'polish': [
            {'polish_initial_text': 'NOT AN AUDIO REFERENCE', 'polished_text': 'SECRET POLISH'}]}}
        entries = []
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('data.json', json.dumps(data))
            for name, audio in recordings:
                archive.writestr(name, audio)
                entries.append({'arcname': name, 'status': 'included', 'category': 'audio'})
            archive.writestr('manifest.json', json.dumps({'entries': entries, 'schema_version': 1, 'truncated': False}))

    def history(self, identifier, **overrides):
        return {'transcriptEntityId': identifier, 'status': 'formatted',
                'asrText': 'A unique raw speech hypothesis ' + identifier,
                'formattedText': 'A product edit ' + identifier,
                'detectedLanguage': 'en', **overrides}

    def make_database(self, rows):
        path = self.root / 'references.sqlite'
        with sqlite3.connect(path) as database:
            database.execute('CREATE TABLE History(transcriptEntityId TEXT, status TEXT, asrText TEXT, formattedText TEXT, editedText TEXT, detectedLanguage TEXT, editedTextStatus TEXT, isDeleted INTEGER, screenshot BLOB, additionalContext TEXT, url TEXT, audio BLOB)')
            for row in rows:
                database.execute('INSERT INTO History VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', (
                    row['transcriptEntityId'], row.get('status'), row.get('asrText'),
                    row.get('formattedText'), row.get('editedText'), row.get('detectedLanguage'),
                    'NOT_EXTRACTED', int(row.get('isDeleted', False)),
                    b'PRIVATE_SCREENSHOT', 'PRIVATE_CONTEXT', 'PRIVATE_URL', b'PRIVATE_AUDIO_BLOB'))
        return path

    def test_readonly_local_join_keeps_hypotheses_separate(self):
        self.make_archive([('dictations/record-a/audio-0.wav', wav(2))])
        database = self.make_database([self.history('record-a', editedText='An unverified edit')])
        before = database.read_bytes()
        result = MODULE.prepare_manifest(self.archive, database)
        self.assertEqual(database.read_bytes(), before)
        clip = result['clips'][0]
        self.assertEqual(clip['history']['texts']['raw_asr_text'], 'A unique raw speech hypothesis record-a')
        self.assertEqual(clip['history']['texts']['formatted_text'], 'A product edit record-a')
        self.assertEqual(clip['history']['texts']['edited_text'], 'An unverified edit')
        self.assertEqual(clip['language'], 'en')
        self.assertIsNone(clip['human_reference'])
        self.assertFalse(clip['eligible_for_ground_truth_metrics'])
        self.assertNotIn('local_audio', clip)
        for private in ['PRIVATE_SCREENSHOT', 'PRIVATE_CONTEXT', 'PRIVATE_URL', 'PRIVATE_AUDIO_BLOB', 'SECRET POLISH']:
            self.assertNotIn(private, json.dumps(result))

    def test_no_history_is_audio_profiling_without_invented_labels(self):
        self.make_archive([('dictations/record-a/audio-0.wav', wav(2))])
        result = MODULE.prepare_manifest(self.archive)
        self.assertEqual(result['aggregate']['selected_clips'], 1)
        clip = result['clips'][0]
        self.assertIsNone(clip['history'])
        self.assertIsNone(clip['language'])
        self.assertIsNone(clip['noise_condition'])
        self.assertEqual(clip['reference_status'], 'unavailable')
        self.assertEqual(result['aggregate']['ground_truth_references'], 0)

    def test_filters_deleted_failed_empty_and_unmatched(self):
        identifiers = ['good', 'deleted', 'dismissed', 'empty', 'failed', 'pending', 'unmatched']
        self.make_archive([(f'dictations/{identifier}/audio-0.wav', wav(1, index + 1))
                           for index, identifier in enumerate(identifiers)])
        database = self.make_database([
            self.history('good'), self.history('deleted', isDeleted=True),
            self.history('dismissed', status='dismissed'),
            self.history('empty', asrText='', formattedText='', editedText=''),
            self.history('failed', status='error'), self.history('pending', status='processing')])
        result = MODULE.prepare_manifest(self.archive, database)
        self.assertEqual([clip['source_id'] for clip in result['clips']], ['good'])
        self.assertEqual(sum(result['aggregate']['excluded'].values()), 6)

    def test_deduplication_and_split_are_deterministic_and_bounded(self):
        recordings, history = [], []
        for index in range(16):
            identifier = f'record-{index}'
            seconds = [1, 6, 16, 46][index % 4]
            recordings.append((f'dictations/{identifier}/audio-0.wav', wav(seconds, index + 1)))
            history.append(self.history(identifier, detectedLanguage='nl' if index % 2 else 'en'))
        # Identical audio across different source IDs cannot leak into both splits.
        duplicate = next(f'duplicate-{i}' for i in range(100)
                         if MODULE.source_split(f'duplicate-{i}') == MODULE.source_split('record-0'))
        recordings.append((f'dictations/{duplicate}/audio-0.wav', recordings[0][1]))
        history.append(self.history(duplicate))
        self.make_archive(recordings, history)
        first = MODULE.prepare_manifest(self.archive, max_clips=8, max_seconds=100)
        self.assertEqual(first, MODULE.prepare_manifest(self.archive, max_clips=8, max_seconds=100))
        self.assertLessEqual(len(first['clips']), 8)
        self.assertLessEqual(sum(clip['duration_seconds'] for clip in first['clips']), 100)
        self.assertEqual(len({clip['dedupe_group'] for clip in first['clips']}), len(first['clips']))
        larger = MODULE.prepare_manifest(self.archive, max_clips=24, max_seconds=600)
        source_splits = {clip['source_id']: clip['split'] for clip in larger['clips']}
        for clip in first['clips']:
            self.assertEqual(source_splits[clip['source_id']], clip['split'])
        self.assertEqual(larger['aggregate']['excluded']['deduplicated_audio_or_source'], 1)

    def test_duplicate_group_crossing_source_splits_is_held_out(self):
        evaluation = next(f'e-{i}' for i in range(100) if MODULE.source_split(f'e-{i}') == 'evaluation')
        tuning = next(f't-{i}' for i in range(100) if MODULE.source_split(f't-{i}') == 'tuning')
        self.make_archive([(f'dictations/{evaluation}/audio-0.wav', wav(2)),
                           (f'dictations/{tuning}/audio-0.wav', wav(2))])
        result = MODULE.prepare_manifest(self.archive)
        self.assertEqual(result['clips'], [])
        self.assertEqual(result['aggregate']['excluded']['dedupe_group_crosses_stable_splits'], 2)

    def test_materialization_requires_reserve_and_uses_private_files(self):
        self.make_archive([('dictations/record-a/audio-0.wav', wav(2))])
        manifest = MODULE.prepare_manifest(self.archive)
        output = self.root / 'private'
        with mock.patch.object(MODULE.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1024})()):
            with self.assertRaises(ValueError):
                MODULE.materialize_selected(self.archive, manifest, output)
        self.assertEqual(list((output / 'audio').iterdir()), [])
        result = MODULE.materialize_selected(self.archive, manifest, output, minimum_free_bytes=0)
        clip = result['clips'][0]
        audio = output / clip['local_audio']
        self.assertEqual(audio.read_bytes(), wav(2))
        self.assertEqual(audio.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(len(clip['audio_sha256']), 64)
        MODULE.write_private(output / 'manifest.json', result)
        self.assertEqual((output / 'manifest.json').stat().st_mode & 0o777, 0o600)
        # Exact repeat verifies existing materialized content rather than replacing it.
        MODULE.materialize_selected(self.archive, manifest, output, minimum_free_bytes=0)

    def test_unsafe_member_and_output_symlink_are_refused(self):
        self.make_archive([('dictations/a/../bad.wav', wav(2))])
        result = MODULE.prepare_manifest(self.archive)
        self.assertEqual(result['aggregate']['selected_clips'], 0)
        self.assertEqual(result['aggregate']['excluded']['unsafe_or_duplicate_member'], 1)
        target = self.root / 'target'
        target.mkdir()
        link = self.root / 'link'
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.private_directory(link)


if __name__ == '__main__':
    unittest.main()
