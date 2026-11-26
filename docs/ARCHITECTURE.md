# Architecture

This document describes how Flow turns speech into pasted text, how Opt+1 polishes a selection, and how meetings are captured. Every stage names the file that implements it. Where a number is a deadline or threshold, the value comes from the code at the time of writing; check the file before relying on it.

The Swift module is called `Voice` for compatibility with older builds; the product is `Flow` (`Package.swift`).

## Components

| Layer | Main files |
|---|---|
| App shell, menus, settings, pill | `Sources/Voice/App/VoiceApp.swift`, `Sources/Voice/Views/` |
| Hotkeys and fn key | `Sources/Voice/Services/HotkeyService.swift`, `FnKeyTap.swift` |
| Audio capture | `Sources/Voice/Services/AudioCaptureService.swift`, `CaptureDSP.swift`, `MicrophoneFailover.swift` |
| Recording coordination | `Sources/Voice/Services/RecordingCoordinator.swift` |
| Speech recognition | `TranscriptionService.swift`, `TranscriptionEngine.swift`, `SpeechModelCatalog.swift`, `SpeechModelLoader.swift`, `GraniteTranscriber.swift`, `MoonshineTranscriber.swift` |
| Text preparation | `DictationTextPreparation.swift`, `DictationFinalPass.swift`, `Sources/Voice/Utils/TextFormatter.swift`, `DictationParagraphs.swift` |
| Cleanup models | `Qwen3Polisher.swift`, `S1MiniPolisher.swift`, `WhisperNowTunedPolisher.swift` (DOSE1), `GeneralCleanupModel.swift`, `CerebrasPolisher.swift`, `GroqPolisher.swift`, `HyperbolicPolisher.swift`, `NVIDIAPolisher.swift`, `RemoteCleanup.swift` |
| Guards and referees | see [DECISION-MODELS.md](DECISION-MODELS.md) |
| Rule passes | `RealWordFixer.swift`, `TypoRepair.swift`, `LowConfidenceRecheck.swift`, `TinyNextScorer.swift`, `PolishPostprocessor.swift`, `RestartCorrectionPreprocessor.swift`, `EntityFreezer.swift` |
| Paste | `Sources/Voice/Utils/CursorPaster.swift`, `PasteReadback.swift`, `PasteSafety.swift` |
| Opt+1 | `PolishTransaction.swift`, `OptOneReferee.swift`, `OptOneLayout.swift` |
| Meetings | `MeetingCaptureService.swift`, `SpeakerDiarizer.swift`, `MeetingCalendarService.swift`, `MeetingRecoveryService.swift`, `MeetingExporter.swift`, `MeetBridgeServer.swift` |
| Storage | `StorageService.swift` (GRDB, SQLite, FTS5) |
| Local logs | `FlowRunLog.swift`, `DictationTrace.swift`, `Telemetry.swift` (see [DATA.md](DATA.md)) |

## Dictation pipeline

1. **Start.** A hotkey press starts `RecordingCoordinator`. Microphone audio goes to a file through `AudioCaptureService` before Accessibility target inspection and optional assistant warmups. System-audio capture has its own asynchronous startup. A short press that is released before the hold threshold is discarded silently (`HotkeyService.swift`).
2. **Recognition.** `TranscriptionService` runs the selected recogniser on the finished file. The default is Parakeet TDT 0.6B v3 through FluidAudio. It returns timed segments with per-word confidence (`TranscriptionService.swift`, `TranscriptionEngine.swift`).
3. **Preparation.** `DictationTextPreparation.prepare` joins the segments, repairs sentences broken by the recogniser (`DictationFinalPass.joinBrokenSentences`), and formats the text with `TextFormatter.formatSegments`. It rejects empty input and text that is mostly non-Latin script. It also reads a trailing "press Enter" command (`TrailingPressEnter.swift`). A trailing stop word is removed only when the spoken stop word ended the recording.
4. **Restart and entity protection.** `RestartCorrectionPreprocessor` resolves spoken self-corrections ("two, no wait, one") before the model sees the text. `EntityFreezer` swaps emails, URLs, code, contractions and domains for sentinel tokens before the model sees the text, and restores them verbatim afterwards.
5. **Cleanup.** The cleanup model runs on the text in sections, with a shared deadline (see below). A section's output is used only if `WhisperNowContentGuard.trip` returns no failure, the output is not shortened beyond the coverage rule, and `Qwen3Polisher.reviewIdentifiersPreserved` finds the identifiers unchanged. Otherwise that section keeps its source text. The route is chosen in `Qwen3Polisher.effectiveAutomaticCleanupModel`: DOSE1 by default, S1-mini if DOSE1 is not installed, or the Qwen3 or general model the user picked.
6. **Finalise.** `DictationTextPreparation.finalize` runs `DictationFinalPass.apply` (fillers, stutters, list markup), the user's own replacements (`WisprImportService.applyReplacements`), American spelling (`AmericanSpelling.swift`), and restores the case of filenames that appear once in the source.
7. **Rule repair.** `RecordingCoordinator` runs `RealWordFixer` (homophones such as their/there). `LowConfidenceRecheck` then looks at words the recogniser flagged below confidence 0.6, and `DictationReferee` records the judgement of each check.
8. **Layout.** `TextFormatter` and `DictationParagraphs` apply list and paragraph layout.
9. **Paste.** `CursorPaster` captures the live field/selection, and `SmartInsertion` resolves boundary spaces, quotes, brackets, punctuation and partial-word/literal insertion. A dispatch receipt retains the exact inserted text and UTF-16 range. `PasteReadback` reads the field back to decide whether it landed. An unknown result never triggers a second paste.
10. **Record.** The run is written to the local run log and the trace, with numbers and labels only in the trace (see [DATA.md](DATA.md)).

### Deadlines and fallbacks

| Limit | Value | Behaviour when hit | Where |
|---|---|---|---|
| Default dictation budget | 1.8 s + 15 ms per word, capped at 6 s, plus any explicitly selected general-model allowance | Cleanup for the remaining sections is skipped; each timed-out section keeps its source text | `DictationDeadline` in `DictationTrace.swift`, `DictationTextPreparation.swift` |
| Per-section model time | the model's own request time (4 s + 30 ms per word, for DOSE1), capped by what remains of the deadline | Section keeps its source text | `DictationTextPreparation.swift`, `WhisperNowTunedPolisher.timeout(for:)` |
| Minimum useful remainder | 50 ms | Treated as timed out | `DictationTextPreparation.swift` |
| Draft second opinion | 150 ms | Maximum wait for the local meaning check (`DraftDecisionGate.swift`) |
| Remote cleanup health check | 0.5 s | A failed check means the local path runs (`RemoteCleanup.swift`) |
| Accessibility messaging | 0.6 s | A slow read falls back to the other outcome (`AccessibilityBudget.swift`) |
| Opt+1 shortcut budget | 8 s | Time budget for the shortcut (`PolishTransaction.swift`) |
| Opt+1 selection size | 6,000 characters | Refused | `PolishTransaction.swift` |
| Failed model load | not retried for 10 minutes | Dictation goes through DOSE1 | `GeneralCleanupModel.swift` |

A dictation is never lost because a model failed. If every cleanup step fails, the formatted transcript is pasted.

On every dictation start, Flow begins optional TinyFix, TinyNext/lexicon and D1 warmups while audio is being captured. A long recording refreshes the idle D1 worker without extending any pending request's watchdog. The CTC encoder is shared between batch and live recognition; a cold live preview starts without vocabulary rescoring rather than waiting for a download. On sectioned dictation, deterministic validation precedes D1 review, and review of one section overlaps cleanup of the next. The original section remains the fallback on a veto. TinyNext low-confidence contexts are scored in bounded batches rather than one model call per suspect. CPU-only word repairs run away from the main UI actor; a newer recording can proceed without an older repair clearing its preview or resetting its transcription session. Saved-dictation retries use the auxiliary reviewers as well. Each finishing dictation owns a cancellation token through delayed paste and readback; Escape cancels that token rather than the shared FIFO barrier. Parent cancellation also wakes a waiting model deadline immediately. The delivery slot remains held until readback finishes or its existing 3-second backstop expires, so a later paste cannot preempt an earlier typed fallback. Normal stop paths use the same atomic capture claim as the hotkey; history metadata is snapshotted at claim. The remote health check and request share one time budget and health is scoped to the endpoint and credential. D1 may use the remaining portion of its 150 ms budget (at least 50 ms), and low-confidence repair uses actual ASR suspects rather than formatter hints.

## Opt+1 polish

`PolishTransaction` describes one polish. It captures the selection, asks the local model once, and replaces the selection once. It reports one of five outcomes: `changed`, `noChangesNeeded`, `couldNotImprove(reason:)`, `unavailable(reason:)` or `textChangedWhilePolishing`. If the selection changed while the model was thinking, nothing is replaced.

`OptOneReferee` aligns the model's edit with the typed text, group by group. Spelling, casing, apostrophes and splits pass. A changed number, link, name or negation, an added or dropped word, or a reworded phrase is reverted to the typed words, and each revert carries a reason. The deterministic repair then fixes what the model left. Undo restores the original only if the text still matches what Flow wrote.

## Meeting pipeline

- `MeetingCaptureService` records meeting audio. `CallAppDetector` recognises call applications.
- `MeetBridgeServer` listens on `localhost:59423`. The Chrome extension in `Extension/` posts to it when a `meet.google.com` call starts or ends, so capture can start and stop automatically. It starts only when meeting detection is enabled (`VoiceApp.swift`, `BackgroundActivityGate.meetingDetectionEnabled`).
- `SpeakerDiarizer` assigns speakers with a clustering threshold of 0.62 (`SpeakerDiarizer.swift`).
- `MeetingRecoveryService` scans for orphaned meeting audio on launch and surfaces it for recovery.
- Transcripts, speakers and summaries are stored by `StorageService` in a local SQLite database with an FTS5 index (`voice.db`). `MeetingExporter` writes exports.

## Companion integration (optional)

A companion app can drive Flow over distributed notifications and read Flow's status keys (`FlowCommandListener.swift`, `FlowBroadcast`). Flow runs without it. The companion is not part of this repository, and the notification names and `Companion` labels in the code are placeholders from the public export.

## Storage and privacy switches

- `voice.privacyMode` is the master switch. When it is on, run records are not written and the other local helpers stop (`VoiceApp.swift`, `BackgroundActivityGate`).
- Run records have their own switch, `flow.saveRunRecords` (default on). See [DATA.md](DATA.md).
- API keys live in the Keychain (`SecretStore.swift`, `KeychainAccess`).
- The database and audio files live under `~/Library/Application Support/Voice/`. Automatic audio pruning is disabled; both pruning entry points are compatibility no-ops. Explicitly captured audio remains until explicitly removed. See [DATA.md](DATA.md) for the archive's scope, including privacy mode.

### Concurrent model ownership

General cleanup admits one request per llama-server and publishes model readiness before its shared startup task completes. A settings change cannot tear down an active request. Batch CTC builds are keyed by the exact dictionary and settings; cold loads do not block final recognition, and a warm dictionary rebuild can be joined for up to 120 ms. Each CTC decode retains its own guard vocabulary. Multi-window dictation overlaps the next TDT decode with the preceding CTC rescore while preserving the original window order and keeping at most one outstanding CTC task.

`SharedModelTask` lets each caller cancel its wait without cancelling model preparation needed by the next dictation. Explicit owner shutdown invalidates the load; generation checks prevent a late completion from publishing readiness or replacing a newer server. WhisperNow, TypoFix, General, S1 and Qwen share this primitive. Qwen meeting/dictation callers also join the same 4B load. A ready selected General model skips unnecessary DOSE1 fallback preparation; cold General retains that fallback. Catalog number validation prevents integer conversion traps, and load headroom includes actual weight-file size when metadata omits it.

Successful and failed shared work releases its completion-owned resources before waking its consumers. This prevents the next CTC window from observing a completed task while its model lease is still busy. Explicit cancellation still wakes a waiter promptly without pretending that underlying native work has stopped. General-model selection uses one bounded, revision-aware catalog snapshot, and prompt vocabulary keeps preferred spellings and source priority through deduplication and phonetic-ranking ties. See [ENGINE.md](ENGINE.md) for measured helper-level work reductions and [HARNESS-VALIDATION.md](HARNESS-VALIDATION.md) for verification scope.

### Opt+1 and cleanup latency

At capture start Flow refreshes the selected cleanup engine. Launch/wake Opt+1 warmup does not start another large fallback editor if the selected typing model is installed. Section routing uses the existing 60-word threshold or section character limit; per-section request budgets include any selected general model allowance but cannot extend the outer deadline. The deadline primitive also checks the absolute monotonic cutoff before accepting a reply. Paragraph layout precomputes its sentence-boundary costs once. Existing explicit list lines are preserved; ordinary semicolon-delimited prose is not treated as code merely for using semicolons.

`PipelineTimer` measures elapsed work monotonically. Run/trace timings separate cleanup, final rules and word repair, delivery-queue wait, dispatch and readback; the completed readback cancels its timeout backstop. TinyNext scores exact-byte duplicate contexts once per call, checks cancellation between expensive steps, and refuses overflow instead of silently shortening context. See [INFERENCE-OPTIMIZATION.md](INFERENCE-OPTIMIZATION.md) for the field definitions, existing engine settings and controlled experiments. These changes are not a hardware speed claim.

### Context-aware insertion and correction evidence

`SmartInsertion.swift` contains the Foundation-only boundary rules. Preformatted text retains its casing. Non-preformatted text uses a conservative list of sentence starters when continuing a sentence, preserving names, acronyms and abbreviation periods. Partial selections within words, contractions and URL/email fragments stay joined. Unicode opening/closing categories cover fullwidth and corner brackets without adding interior spaces. Quotation-mark properties also keep literal list, heading and fence markers inside existing curly or corner quotes instead of adding unintended outer line breaks. Spaces travel in the same paste payload, preserving a single undoable paste.

When an editor hides its full field value, `CursorPaster` can read bounded `AXStringForRange` context for spacing. That partial context never upgrades delivery to verified. Fallback memory for unreadable fields is invalidated by clicks, app switches and external keyboard activity. The tracker stores counters only. Before sending keys, the paster rechecks submission ownership, field, caret and clipboard ownership. Invalid or overflowing UTF-16 ranges cannot authorize a typed fallback.

Only verified insertions can start `CorrectionLearner`. `CorrectionEvidence` derives the exact baseline from the receipt, then isolates changes inside the inserted range. Edits elsewhere, appended text, cleared fields and ambiguous ranges are excluded. A common notification invalidates pending observations before any Flow-authored paste, selected-text edit or typed fallback. Stable external edits are recorded as `observed-edit` proposals; they are not approved training labels. Schema 2 run records distinguish pipeline output, boundary-adapted insertion, feedback provenance and runtime identity.

The automatic dictionary deduplicates observations across polling, imports and restarts, requires user-edit corroboration before promoting replacements, and retains negative Undo evidence. The offline model improvement loop exports reviewed examples, keeps duplicate families in one persistent split, replays fixed cases and compares candidates through explicit quality/latency gates. It never changes installed models by itself. See [TRAINING.md](TRAINING.md) and [CUSTOM-MODEL-PLAN.md](CUSTOM-MODEL-PLAN.md).
