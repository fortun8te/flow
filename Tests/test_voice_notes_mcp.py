import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/voice-notes-mcp.py'

class NotesMCPTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / 'voice.db'
        with sqlite3.connect(self.db) as db:
            db.executescript('''
                CREATE TABLE meetings(id TEXT, title TEXT, date TEXT, duration REAL, pinnedNote TEXT, kind TEXT, audioFilePath TEXT);
                CREATE TABLE segments(id TEXT, meetingId TEXT, speaker TEXT, text TEXT, startTime REAL, endTime REAL);
                CREATE TABLE summaries(meetingId TEXT, overview TEXT, keyDecisionsJson TEXT, actionItemsJson TEXT, openQuestionsJson TEXT);
                INSERT INTO meetings VALUES ('meeting-1','Project','2026-01-01',60,'meeting note','meeting','PRIVATE_PATH');
                INSERT INTO meetings VALUES ('dictation-1','Hidden','2026-01-02',10,'DICTATION_SECRET','dictation','PRIVATE_PATH');
                INSERT INTO segments VALUES ('1','meeting-1','A','hello team',0,2);
                INSERT INTO segments VALUES ('2','meeting-1','B','second segment',2,4);
                INSERT INTO segments VALUES ('3','dictation-1','A','DICTATION_SECRET',0,1);
                INSERT INTO summaries VALUES ('meeting-1','project overview','["decision"]','[]','[]');
            ''')
        self.proc = subprocess.Popen([sys.executable, str(SCRIPT), '--database', str(self.db)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.counter = 0

    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.tmp.cleanup()

    def request(self, method, params=None):
        self.counter += 1
        self.proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params or {}}) + '\n')
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def call(self, name, args=None):
        return self.request('tools/call', {'name': name, 'arguments': args or {}})['result']

    def data(self, result):
        return json.loads(result['content'][0]['text'])

    def test_protocol_and_privacy(self):
        self.assertEqual(self.request('initialize', {'protocolVersion':'2025-03-26'})['result']['protocolVersion'], '2025-03-26')
        self.assertEqual(self.request('ping')['result'], {})
        self.assertEqual(len(self.request('tools/list')['result']['tools']), 3)
        listed = self.call('list_meetings')
        self.assertEqual([m['id'] for m in self.data(listed)['meetings']], ['meeting-1'])
        self.assertIsNone(self.data(listed)['meetings'][0]['sourceApp'])
        self.assertNotIn('PRIVATE_PATH', json.dumps(listed))
        self.assertEqual(self.data(self.call('search_meetings', {'query':'DICTATION_SECRET'}))['meetings'], [])
        match = self.data(self.call('search_meetings', {'query':'HELLO'}))['meetings'][0]
        self.assertEqual(match['id'], 'meeting-1')
        self.assertEqual(match['transcriptMatch'], {'text': 'hello team', 'startTime': 0})
        self.assertNotIn('transcriptMatch', self.data(listed)['meetings'][0])
        self.assertEqual(self.data(self.call('search_meetings', {'query':'decision'}))['meetings'][0]['id'], 'meeting-1')
        self.assertTrue(self.call('get_meeting', {'id':'dictation-1'})['isError'])
        result = self.data(self.call('get_meeting', {'id':'meeting-1', 'limit':1}))
        self.assertEqual(result['summary']['keyDecisions'], ['decision'])
        self.assertEqual(result['segments'][0]['text'], 'hello team')
        self.assertEqual(result['nextOffset'], 1)
        self.assertIsNone(result['sourceApp'])
        self.assertNotIn('PRIVATE_PATH', json.dumps(result))
        self.assertTrue(self.call('list_meetings', {'limit':101})['isError'])
        self.assertTrue(self.call('list_meetings', {'database':'/tmp/other'})['isError'])
        self.assertEqual(self.request('bad/method')['error']['code'], -32601)

    def test_source_app_is_additive_and_read_only(self):
        with sqlite3.connect(self.db) as db:
            db.execute('ALTER TABLE meetings ADD COLUMN sourceApp TEXT')
            db.execute('UPDATE meetings SET sourceApp=? WHERE id=?',
                       ('wispr-flow-export-v1', 'meeting-1'))
            db.execute('UPDATE meetings SET sourceApp=? WHERE id=?',
                       ('DICTATION_SOURCE_SECRET', 'dictation-1'))
        before = self.db.read_bytes()
        listed = self.data(self.call('list_meetings'))
        searched = self.data(self.call('search_meetings', {'query': 'hello'}))
        detail = self.data(self.call('get_meeting', {'id': 'meeting-1'}))
        for result in (listed['meetings'][0], searched['meetings'][0], detail):
            self.assertEqual(result['sourceApp'], 'wispr-flow-export-v1')
            self.assertNotIn('PRIVATE_PATH', json.dumps(result))
            self.assertNotIn('DICTATION_SOURCE_SECRET', json.dumps(result))
        self.assertEqual(before, self.db.read_bytes())
        with sqlite3.connect(self.db) as db:
            db.execute('UPDATE meetings SET sourceApp=NULL WHERE id=?', ('meeting-1',))
        self.assertIsNone(self.data(self.call('get_meeting', {'id': 'meeting-1'}))['sourceApp'])

    def test_database_is_unchanged_and_missing_is_not_created(self):
        before = self.db.read_bytes()
        self.call('list_meetings')
        self.assertEqual(before, self.db.read_bytes())
        missing = Path(self.tmp.name) / 'missing.db'
        p = subprocess.run([sys.executable, str(SCRIPT), '--database', str(missing)], input=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'list_meetings'}})+'\n', text=True, capture_output=True, check=True)
        self.assertTrue(json.loads(p.stdout)['result']['isError'])
        self.assertFalse(missing.exists())

    def test_empty_captures_are_reversible_and_filter_before_pagination(self):
        with sqlite3.connect(self.db) as db:
            db.executescript("""
                ALTER TABLE meetings ADD COLUMN finalText TEXT;
                ALTER TABLE meetings ADD COLUMN sourceApp TEXT;
                INSERT INTO meetings VALUES ('empty','Empty capture','2026-01-06',1,NULL,'meeting',NULL,NULL,NULL);
                INSERT INTO meetings VALUES ('short','Short real note','2026-01-05',3,NULL,'meeting',NULL,NULL,NULL);
                INSERT INTO meetings VALUES ('imported','Short import','2026-01-04',2,NULL,'meeting',NULL,NULL,'wispr-flow-export-v1');
                INSERT INTO meetings VALUES ('preserved','Saved recording','2026-01-03',0,NULL,'meeting',NULL,'Saved words',NULL);
                INSERT INTO segments VALUES ('s','short','A','one real line',0,2);
            """)
        before = self.db.read_bytes()
        page = self.data(self.call('list_meetings', {'limit': 1}))
        self.assertEqual(page['meetings'][0]['id'], 'short')
        self.assertEqual(page['nextOffset'], 1)
        page = self.data(self.call('list_meetings'))
        self.assertEqual([m['id'] for m in page['meetings']], ['short', 'imported', 'preserved', 'meeting-1'])
        page = self.data(self.call('list_meetings', {'includeEmpty': True}))
        self.assertEqual(page['meetings'][0]['id'], 'empty')
        self.assertEqual(self.data(self.call('search_meetings', {'query': 'Empty capture'}))['meetings'], [])
        page = self.data(self.call('search_meetings', {'query': 'Empty capture', 'includeEmpty': True}))
        self.assertEqual(page['meetings'][0]['id'], 'empty')
        self.assertEqual(self.data(self.call('get_meeting', {'id': 'empty'}))['segments'], [])
        self.assertTrue(self.call('list_meetings', {'includeEmpty': 1})['isError'])
        self.assertEqual(self.db.read_bytes(), before)

    def test_full_speaker_roster_survives_transcript_pagination(self):
        with sqlite3.connect(self.db) as db:
            db.executescript("""
                ALTER TABLE meetings ADD COLUMN participantNamesJson TEXT;
                ALTER TABLE segments ADD COLUMN speakerId INTEGER;
                UPDATE meetings SET participantNamesJson='["Dana"]' WHERE id='meeting-1';
                UPDATE segments SET speaker='Unknown', speakerId=2 WHERE id='1';
                UPDATE segments SET speaker='Dana', speakerId=3 WHERE id='2';
            """)
        detail = self.data(self.call('get_meeting', {'id': 'meeting-1', 'limit': 1}))
        self.assertEqual(detail['participantNames'], ['Dana'])
        self.assertEqual(detail['speakers'], [
            {'speakerId': '2', 'speaker': 'Unknown'}, {'speakerId': '3', 'speaker': 'Dana'},
        ])
        self.assertEqual(detail['segments'][0]['speakerId'], '2')

if __name__ == '__main__':
    unittest.main()
