#!/usr/bin/env python3
"""Local read-only MCP server for VOICE meeting notes (newline JSON-RPC)."""
import argparse
import json
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

DEFAULT_DB = Path.home() / 'Library/Application Support/Voice/voice.db'
PROTOCOLS = {'2024-11-05', '2025-03-26', '2025-06-18'}


def schema(properties, required=()):
    return {'type': 'object', 'properties': properties, 'required': list(required), 'additionalProperties': False}

PAGE = {'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100, 'default': 20},
        'offset': {'type': 'integer', 'minimum': 0, 'maximum': 100000, 'default': 0}}
MEETING_PAGE = {**PAGE, 'includeEmpty': {'type': 'boolean', 'default': False}}
TOOLS = [
    {'name': 'list_meetings', 'description': 'List meeting notes, newest first. Set includeEmpty to show empty short captures.', 'inputSchema': schema(MEETING_PAGE)},
    {'name': 'search_meetings', 'description': 'Search meeting titles, notes, summaries and transcript text. Set includeEmpty to search empty short captures.', 'inputSchema': schema({'query': {'type': 'string', 'minLength': 1, 'maxLength': 200}, **MEETING_PAGE}, ('query',))},
    {'name': 'get_meeting', 'description': 'Get a meeting, its summary and a page of transcript segments.', 'inputSchema': schema({'id': {'type': 'string', 'minLength': 1, 'maxLength': 100}, **PAGE}, ('id',))},
]


def validate(name, args):
    spec = next((t for t in TOOLS if t['name'] == name), None)
    if spec is None:
        raise ValueError('Unknown tool')
    if not isinstance(args, dict):
        raise ValueError('Arguments must be an object')
    properties = spec['inputSchema']['properties']
    if set(args) - set(properties) or any(k not in args for k in spec['inputSchema']['required']):
        raise ValueError('Invalid arguments')
    for key, value in args.items():
        if key in ('limit', 'offset'):
            if type(value) is not int or not (1 <= value <= 100 if key == 'limit' else 0 <= value <= 100000):
                raise ValueError('Invalid pagination')
        elif key == 'includeEmpty':
            if type(value) is not bool:
                raise ValueError('Invalid includeEmpty')
        elif not isinstance(value, str) or not value.strip() or len(value) > (200 if key == 'query' else 100):
            raise ValueError('Invalid ' + key)
    return args.get('limit', 20), args.get('offset', 0)


def run_tool(db_path, name, args):
    limit, offset = validate(name, args)
    # URI mode=ro prevents creation and modification; no immutable flag, so live WAL is visible.
    uri = db_path.expanduser().resolve().as_uri() + '?mode=ro'
    with closing(sqlite3.connect(uri, uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        # Older databases lack this additive metadata column. Never migrate
        # a live store from a read-only client or infer provenance from titles.
        columns = {row['name'] for row in db.execute('PRAGMA table_info(meetings)')}
        source = 'm.sourceApp' if 'sourceApp' in columns else 'NULL'
        header = f'm.id, m.title, m.date, m.duration, m.pinnedNote, {source} AS sourceApp'
        if name == 'get_meeting':
            participants = 'm.participantNamesJson' if 'participantNamesJson' in columns else 'NULL'
            row = db.execute(f"SELECT {header}, {participants} AS participantNamesJson FROM meetings m WHERE m.kind='meeting' AND m.id=?", (args['id'],)).fetchone()
            if row is None:
                raise ValueError('Meeting not found')
            result = dict(row)
            try:
                names = json.loads(result.pop('participantNamesJson') or '[]')
            except (TypeError, ValueError):
                names = []
            result['participantNames'] = [name for name in names if isinstance(name, str) and name.strip()] if isinstance(names, list) else []
            summary = db.execute('SELECT overview, keyDecisionsJson, actionItemsJson, openQuestionsJson FROM summaries WHERE meetingId=?', (args['id'],)).fetchone()
            if summary:
                result['summary'] = {'overview': summary['overview']}
                for field, out in [('keyDecisionsJson', 'keyDecisions'), ('actionItemsJson', 'actionItems'), ('openQuestionsJson', 'openQuestions')]:
                    result['summary'][out] = json.loads(summary[field])
            else:
                result['summary'] = None
            segment_columns = {row['name'] for row in db.execute('PRAGMA table_info(segments)')}
            speaker_id = 'CAST(speakerId AS TEXT)' if 'speakerId' in segment_columns else 'NULL'
            speakers = db.execute(f'''SELECT {speaker_id} AS speakerId, speaker FROM segments
                                   WHERE meetingId=? AND length(trim(text, char(9,10,13,32))) > 0
                                   GROUP BY 1, 2 ORDER BY min(startTime), 1, 2''', (args['id'],)).fetchall()
            result['speakers'] = [dict(speaker) for speaker in speakers]
            rows = db.execute(f'SELECT speaker, {speaker_id} AS speakerId, text, startTime, endTime FROM segments WHERE meetingId=? ORDER BY startTime, id LIMIT ? OFFSET ?', (args['id'], limit + 1, offset)).fetchall()
            result['segments'] = [dict(x) for x in rows[:limit]]
            result['nextOffset'] = offset + limit if len(rows) > limit else None
            return result
        params = []
        where = "m.kind='meeting'"
        if not args.get('includeEmpty'):
            # Protect imported and substantive short meetings. Older stores
            # without finalText are ambiguous, so leave their captures visible.
            if 'finalText' in columns:
                where += f""" AND NOT (
                     m.duration >= 0 AND m.duration < 5
                     AND coalesce({source}, '') <> 'wispr-flow-export-v1'
                     AND length(trim(coalesce(m.pinnedNote, ''), char(9,10,13,32))) = 0
                     AND length(trim(coalesce(m.finalText, ''), char(9,10,13,32))) = 0
                     AND NOT EXISTS (SELECT 1 FROM segments s WHERE s.meetingId=m.id AND length(trim(s.text, char(9,10,13,32))) > 0)
                     AND NOT EXISTS (SELECT 1 FROM summaries u WHERE u.meetingId=m.id)
                )"""
        if name == 'search_meetings':
            # Literal substring search, no FTS query syntax or wildcard injection.
            term = '%' + args['query'].strip().replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
            where += " AND (m.title LIKE ? ESCAPE '\\' OR m.pinnedNote LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM segments s WHERE s.meetingId=m.id AND s.text LIKE ? ESCAPE '\\') OR EXISTS (SELECT 1 FROM summaries u WHERE u.meetingId=m.id AND (u.overview LIKE ? ESCAPE '\\' OR u.keyDecisionsJson LIKE ? ESCAPE '\\' OR u.actionItemsJson LIKE ? ESCAPE '\\' OR u.openQuestionsJson LIKE ? ESCAPE '\\')))"
            params.extend([term] * 7)
        rows = db.execute(f'SELECT {header} FROM meetings m WHERE {where} ORDER BY m.date DESC, m.id LIMIT ? OFFSET ?', (*params, limit + 1, offset)).fetchall()
        meetings = [dict(x) for x in rows[:limit]]
        if name == 'search_meetings':
            needle = args['query'].strip()
            for meeting in meetings:
                match = db.execute(
                    r"""SELECT text, startTime, instr(lower(text), lower(?)) AS position
                       FROM segments WHERE meetingId=? AND text LIKE ? ESCAPE '\'
                       ORDER BY startTime, id LIMIT 1""",
                    (needle, meeting['id'], term),
                ).fetchone()
                if match is not None:
                    start = max(0, match['position'] - 51)
                    end = min(len(match['text']), start + max(180, len(needle) + 80))
                    excerpt = match['text'][start:end].strip()
                    meeting['transcriptMatch'] = {
                        'text': ('…' if start else '') + excerpt + ('…' if end < len(match['text']) else ''),
                        'startTime': match['startTime'],
                    }
        return {'meetings': meetings, 'nextOffset': offset + limit if len(rows) > limit else None}


def handle(message, db_path):
    if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
        return {'jsonrpc': '2.0', 'id': message.get('id') if isinstance(message, dict) else None, 'error': {'code': -32600, 'message': 'Invalid Request'}}
    if 'id' not in message:
        return None
    response = {'jsonrpc': '2.0', 'id': message['id']}
    method = message['method']
    params = message.get('params', {})
    if not isinstance(params, dict):
        response['error'] = {'code': -32602, 'message': 'Invalid params'}
    elif method == 'initialize':
        requested = params.get('protocolVersion')
        response['result'] = {'protocolVersion': requested if requested in PROTOCOLS else '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'voice-meeting-notes', 'version': '1.0.1'}}
    elif method == 'ping':
        response['result'] = {}
    elif method == 'tools/list':
        response['result'] = {'tools': TOOLS}
    elif method == 'tools/call':
        try:
            result = run_tool(db_path, params.get('name'), params.get('arguments', {}))
            response['result'] = {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}]}
        except ValueError as e:
            response['result'] = {'isError': True, 'content': [{'type': 'text', 'text': str(e)}]}
        except (sqlite3.Error, OSError, json.JSONDecodeError):
            response['result'] = {'isError': True, 'content': [{'type': 'text', 'text': 'Meeting database could not be read.'}]}
    else:
        response['error'] = {'code': -32601, 'message': 'Method not found'}
    return response


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=Path, default=DEFAULT_DB, help='VOICE SQLite database path')
    args = parser.parse_args()
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            response = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}
        else:
            response = handle(message, args.database)
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()
