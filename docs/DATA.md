# Data Flow writes on your Mac

Flow keeps everything it writes on your Mac. This file lists each store, what it contains, where it lives, and how to stop or delete it. Paths are as coded at the time of writing; `Sources/Voice/` is the reference if they drift. Nothing in the code uploads these files. Cloud cleanup, which is opt-in, sends the text being cleaned to the chosen provider and nothing else (see [ENGINE.md](ENGINE.md)).

## Summary

| Store | Path under `~/Library/Application Support/` | Contains text? | Default | Turn off |
|---|---|---|---|---|
| Run records | `VOICE/training/runs.jsonl` (+ rotated `runs-*.jsonl`) | **Yes**: raw transcript, cleanup outputs, final text | On | `flow.saveRunRecords` off, or privacy mode |
| Dictation trace | `VOICE/traces/dictations.jsonl` | No: numbers and labels only | On | Privacy mode |
| Event log | `Voice/events.jsonl` | Event names and properties; word-repair events contain scores only | On | Privacy mode |
| Database | `Voice/voice.db` (SQLite, FTS5) | **Yes**: meeting transcripts, speakers, summaries, audio paths | Meetings only | Do not record meetings; delete the file |
| Audio | `Voice/audio/` (meeting `.wav`, dictation `.caf`) | **Yes**, as audio | Kept until pruned | Pruned by size (`StorageService.pruneAudioBySize`) |
| Learned words | Flow settings (`voice.autoDictionary`) | Words you corrected | On | Remove entries in the app |
| API keys and tokens | Login Keychain | Secrets | Only if you add them | Remove them in the Keychain |

Apple's paths are case-insensitive, so `VOICE` and `Voice` refer to the same folder on a default Mac install.

## Master switch: privacy mode

`voice.privacyMode` is an emergency "all off" switch. `Sources/Voice/App/VoiceApp.swift` describes it as the master kill switch: when it is on, every helper that checks it returns early. Run records (including the legacy `VOICE/training/dictations.jsonl` training log), dictation traces, events and queued Opt+1 evidence are not written. Delayed correction learning stops, the draft meaning check is off, and recording of meetings does not start. Writers recheck privacy mode at write time so a queued record cannot ignore a later opt-out. Turn it on from the app's settings. This prevents new collection; it does not erase existing files.

## Run records

`Sources/Voice/Services/FlowRunLog.swift` writes one record per dictation and per Opt+1 polish, as append-only JSON lines. A record holds:

- the raw input, and for dictation the recogniser's words with their confidence;
- each stage's output in order, with word changes and timing;
- guard and gate decisions, with reasons;
- the models and settings in use, and any timeout or fallback reason;
- the run schema/pipeline version, app version/build, and the source fingerprint when the candidate bundle provides one;
- the actual leased ASR model and its configured revision, with an explicit unknown value when it is not pinned;
- the app the text was going to;
- the final text.

Later lines link back by `id` for Undo, the "Original" toggle, and edits made straight after paste. Schema 2 corrections contain only the corrected insertion, with `targetScope: pasted-span` and `feedbackSource: observed-edit`. Flow anchors this to the exact verified UTF-16 insertion range, requires a stable change in the same focused field after keyboard activity, and cancels the observation when Flow makes another edit. Repeated text elsewhere in the field cannot be selected by substring matching. Older whole-field correction records remain readable but are not training targets.

The keyboard tracker stores only counters. It does not store key characters, key codes, or modifier values. External keyboard activity supports an observed correction; another app could synthesize input, so this is not a claim of independent human approval. The exporter puts these observations in a review queue. Paste verification and leaving model output untouched are delivery/retention observations, not positive training labels.

**Controls**

- Switch: `flow.saveRunRecords` (default on). To turn it off:
  ```sh
  defaults write <your bundle identifier> flow.saveRunRecords -bool NO
  ```
- Privacy mode also stops run records. Both this switch and `flow.saveRunRecords` apply to the legacy training log as well, including queued writes.
- Secure text fields are recorded without their text (`FlowRunLog.withoutText`), including word-bearing decision values, auxiliary transcripts in settings, free-form fallback reasons and audio paths. Stage labels, timings and model identifiers remain. The legacy training copy also omits its text, audio path and fallback reason.
- The folder is created with mode 0700 and the file with 0600.
- The folder is excluded from iCloud and Time Machine backups.
- The file rotates at 24 MB and keeps the newest 12 rotated files (about 300 MB at most).

**Delete**: remove `~/Library/Application Support/VOICE/training/`.

These records contain your speech, so do not publish them. `scripts/export_flow_runs.py` exports observations and explicitly reviewed training pairs, with persistent split assignments and duplicate-family grouping. An Undo removes an earlier target. Its output must be kept private as well. See [TRAINING.md](TRAINING.md) for the review, replay and comparison commands.

## Dictation trace

`Sources/Voice/Services/DictationTrace.swift` writes one JSON line per dictation to `VOICE/traces/dictations.jsonl`, in a folder with mode 0700. Each line holds numbers and labels only: which engine ran, why a fallback was used, and the time of each stage in milliseconds from key release. Privacy mode is checked inside the writer.

## Event log

`Sources/Voice/Services/Telemetry.swift` appends JSON lines to `Voice/events.jsonl` and has no network code. Privacy mode is checked before enqueueing and again before writing. New event files use mode 0600; existing files have that mode reapplied. Word-repair events store scores, counts and positions; the actual word swaps belong in the separately controlled run record. The shared date formatter is confined to the serial writer queue.

## Database and meetings

`Sources/Voice/Services/StorageService.swift` keeps `voice.db` in the Voice folder, with a GRDB `DatabasePool` in WAL mode. It stores meetings, timed segments with speaker labels, summaries, and the path to each meeting's audio. An FTS5 index covers segment text and speakers, so meetings can be searched.

Meetings are recorded only when you start them, or when a call is detected and meeting detection is on. Browser detection is started by `MeetBridgeServer`, which listens on `localhost:59423` only when meeting detection is enabled.

**Delete**: quit Flow and remove `voice.db`, `voice.db-wal` and `voice.db-shm`. Remove the `audio` folder too, to delete the recordings.

## Audio

Meeting audio is saved as `meeting-*.wav` files in `Voice/audio/`, and dictation audio is saved as `.caf` files there too. `StorageService.swift` can prune audio by size with `pruneAudioBySize`. `pruneOrphanedAudio` currently deletes nothing: it returns 0 and keeps every file, because an unreferenced recording may be a recovery file or a capture still in progress. `MeetingRecoveryService.swift` looks for orphaned meeting audio on launch.

## Learned words

When you correct a word, Flow can learn the correction (`AutoDictionary.swift`). The short list shown in settings is kept under `voice.autoDictionary`. Learned entries are local and can be removed from the app. Repeated polling or history import of the same recording counts once. Retained Opt+1 output alone cannot promote a replacement or override a user-learned spelling. Older live entries supported only by passive model output return to pending review. Undo invalidates the corresponding evidence, including after restart.

The dictionary's version 2 store retains bounded per-entry observation identities and their sources, plus undone-operation identities. It preserves compatibility with older stores. This dictionary adaptation is separate from training a neural model; model training still requires reviewed labels and evaluation.

## Keys and tokens

API keys for cloud providers and the optional LAN cleanup token are kept in the login Keychain (`SecretStore.swift`, through KeychainAccess). Keys saved by earlier builds in UserDefaults are copied into the Keychain and removed from UserDefaults on the next read. A Cerebras key is recognised by its `csk-` prefix. The app shows only a masked form in logs (`Telemetry.maskKey`).

## Deleting everything

1. Turn on privacy mode, or quit Flow.
2. Remove `~/Library/Application Support/VOICE/` and `~/Library/Application Support/Voice/`.
3. Remove any keys in the Keychain under the Flow service names.
4. Reset Flow's own defaults if you want the settings gone too.

Flow does not keep copies anywhere else. A backup you made of these folders is your own copy and needs deleting separately.
