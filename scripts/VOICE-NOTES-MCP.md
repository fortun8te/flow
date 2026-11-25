# VOICE meeting notes MCP

`voice-notes-mcp.py` is a local, read-only stdio MCP server. It offers `list_meetings`, `search_meetings`, and `get_meeting`; the latter pages transcript segments with `limit` and `offset`. The list and search tools also support pagination. Search matches literal text in titles, pinned notes, summaries and transcripts. Only rows explicitly marked `meeting` are returned. Audio and export paths are omitted.

Version 1.0.1 adds nullable `sourceApp` to list, search and detail records. The value is the stored source marker, not a verified claim of authorship. `wispr-flow-export-v1` means imported from the prepared Wispr Flow export. A missing column in an older database or a missing value returns `null`; clients should show Source unavailable and must not infer source from a title, filename or transcript. The server does not migrate the database. This additive metadata field does not add recording or settings controls.

Run with Python 3:

```sh
python3 scripts/voice-notes-mcp.py
```

The default database is `~/Library/Application Support/Voice/voice.db`. To use a different database, pass `--database /path/to/voice.db` when starting the process. The MCP client must launch this command using stdio and newline-delimited JSON-RPC. No network service is opened. A missing or incompatible database returns a generic tool error and is not created or migrated.

The server gives a connected client access to private meeting contents. Enable it only in a client you trust, and review that client's data handling. This script does not configure or enable any client, account, or cloud connector. Only meeting records are exposed, but the server trusts VOICE's `kind` classification; it cannot identify a dictation incorrectly saved as a meeting. SQLite may need access to existing WAL/shared-memory files to read the current database.

Run the temporary-database protocol and privacy tests with:

```sh
python3 -m unittest discover -s Tests -p 'test_voice_notes_mcp.py' -v
```
