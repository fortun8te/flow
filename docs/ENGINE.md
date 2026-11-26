# Engines

This document covers Flow's speech recognition and text cleanup engines: which ones exist, how one is chosen, how local servers run, and what happens when an engine is missing or slow. For the order of stages, see [ARCHITECTURE.md](ARCHITECTURE.md). For the checks that decide whether an engine's output is used, see [DECISION-MODELS.md](DECISION-MODELS.md).

## Speech recognition

### Selectable recognisers

`Sources/Voice/Services/SpeechModelCatalog.swift` defines the stable identifiers. These are persisted, so they never change name:

| ID | Engine | Notes |
|---|---|---|
| `parakeet-v3` | Parakeet TDT 0.6B v3 via FluidAudio (Core ML) | Default (`SpeechModelCatalog.defaultID`) |
| `parakeet-ultra` | Parakeet Ultra via FluidAudio | Manifest in `Resources/ModelManifests/parakeet-ultra.json` |
| `phonon-2` | Phonon 2 via FluidAudio | Manifest in `Resources/ModelManifests/phonon-2.json` |
| `fluid-speech-pro` | Fluid Speech Pro (Core ML) | Same inputs and outputs as Parakeet v3. Off unless chosen; shows "not downloaded" until its folder is installed |

`Sources/Voice/Services/SpeechModelLoader.swift` loads `AsrModels` from a local directory with FluidAudio, choosing the model version from the identifier. `Sources/Voice/Services/TranscriptionService.swift` pre-warms the model once at launch. Starting a recording only resets state. Recognition then runs on the finished audio file through FluidAudio's URL-based API, which handles reading and resampling internally.

`Sources/Voice/Services/TranscriptionEngine.swift` defines the protocol that all engines implement. It has two surfaces: streaming (start, feed, stop, with partial results) and batch (`transcribe(audioChunk:chunkStartTime:)`, used for long meetings). Each engine keeps its own model state.

### Python speech servers (optional)

Two engines run as persistent Python subprocesses. Both speak newline-delimited JSON over stdin and stdout.

- **Granite 4.0 1B Speech** (`GraniteTranscriber.swift`, `Resources/granite_server.py`). It tries `mlx-community/granite-4.0-1b-speech-5bit` first and then the 8-bit variant.
- **Moonshine Tiny** (`MoonshineTranscriber.swift`, `Resources/moonshine_server.py`). It tries the Moonshine MLX conversions in turn.

Protocol: the server writes `{"status":"ready"}` or `{"status":"unavailable", ...}` at startup. The app writes `{"path":"/abs/path.caf"}` for each request and reads `{"text": ...}` or `{"error": ...}` back. If Python or the MLX packages are missing, the engine returns nil and Parakeet is used.

## Cleanup engines

Cleanup is the step after recognition that tidies punctuation, fillers and self-corrections. The route is chosen in `Sources/Voice/Services/Qwen3Polisher.swift` (`effectiveAutomaticCleanupModel`), reading the user setting `voice.cleanupModel`.

| Route value | Engine | Where | Default? |
|---|---|---|---|
| `whispernow-tuned` (shown as DOSE1) | Fine-tuned WhisperNow LFM3 1.7B, GGUF, served by `llama-server` | `WhisperNowTunedPolisher.swift` | Yes, when installed |
| `s1-mini` | S1-mini 4-bit, MLX | `S1MiniPolisher.swift` | Fallback when DOSE1 is not installed |
| `qwen3` | Qwen3 MLX (`mlx-community/Qwen3-1.7B-4bit`; a 4B DWQ model is also named in the code) | `Qwen3Polisher.swift` | Only when chosen |
| general model | Any GGUF listed in `cleanup-models.json`, served by `llama-server` | `GeneralCleanupModel.swift` | Only when chosen |

### DOSE1 and `llama-server`

DOSE1 is the default cleanup model. It is a fine-tune of the WhisperNow LFM3 1.7B base, and its weights are not distributed with this repository. You can use another GGUF through the general-model list.

- The server binds to `127.0.0.1` only.
- It starts on prewarm or first use, exits after a period of inactivity, and restarts after a crash with back-off.
- A shell watchdog stops it if Flow exits.
- The binary is looked up in this order: `voice.whispernowServerPath`, a copy bundled in `Flow.app` at `llama/llama-server`, `~/homebrew/bin`, `/opt/homebrew/bin`, `/usr/local/bin` (`WhisperNowTunedPolisher.swift`).
- Requests send the trimmed transcript as the only user turn, with greedy decoding and a repeat penalty of 1.05. The maximum token count is `max(64, ceil(2.5 × words))`. A reply of `EMPTY` means no speech.

### General models

`GeneralCleanupModel.swift` reads `~/Library/Application Support/VOICE/Models/cleanup-models.json`. Each entry's `id` can be selected with `voice.cleanupModel`, and the setting is read on every dictation. When a general model is missing, still loading, out of memory, slow, or fails the content guard, the dictation goes through DOSE1 as before. A model that fails to load is not retried for ten minutes.

### S1-mini

S1-mini is used for English recognition normalisation only. It is not a general editing model. The caller keeps the original transcript for every output that is not accepted. Its licence is Apache-2.0 with an additional naming term. The notice files are in `Sources/Voice/Resources/ModelNotices/S1-mini/`.

### Cloud routes (opt-in)

`CerebrasPolisher.swift`, `GroqPolisher.swift`, `HyperbolicPolisher.swift` and `NVIDIAPolisher.swift` send text to a hosted model. They run only when the user turns them on and supplies a key. Keys are stored in the Keychain (`SecretStore.swift`). Cerebras keys start with `csk-`, which the app checks. Each provider's data terms apply, and the text leaves the Mac in these routes.

### Optional LAN cleanup server

`RemoteCleanup.swift` can send long dictations to a second machine on the local network that runs the same model. It has a health check with a 0.5-second timeout and a token kept in the Keychain. Its default address is a placeholder (`http://127.0.0.1:8765`), so set your own server before turning it on. The server side is not part of this repository.

## Rule engines

- **TinyFix real-word swaps** (`RealWordFixer.swift`): a Swift port of the tinyfix model and its swap rules. Weights (`tinyfix.bin`) are not included, so the fixer needs them before it can run.
- **tinynext scorer** (`TinyNextScorer.swift`): a 12.5M-parameter causal language model run with Accelerate, used only to score candidate spellings in context. Weights (`tinynext-v2.q8`) are not included.
- **Typo repair** (`TypoRepair.swift`): keyboard-weighted edit distance over a frequency dictionary (`words.txt`, not included), with tinynext scoring each candidate.

## Packaging and pinning

- Swift dependencies are pinned in `Package.resolved`. FluidAudio is pinned exactly at 0.18.3.
- Model manifests in `Sources/Voice/Resources/ModelManifests/` pin each model's repository and revision and its cache path.
- The app requires macOS 26 and Swift tools 6.2 (`Package.swift`).

### Auxiliary local model recovery

TinyFix, TinyNext and the frequency lexicon may be installed under `~/Library/Application Support/Voice/Models/TinyFix`; bundled vocabulary/tokenizer files are used when absent from the external directory. TinyFix, TinyNext and CTC retry transient load failures after a bounded backoff without relaunching Flow. The run log distinguishes missing/cold auxiliary resources, no candidates, and model-scored candidates. TinyNext bounds activation storage by token rows; Opt+1 uses the selected installed typing model, keeps its server alive during inference, avoids per-chunk tokenization delays, and preserves original text in failed chunks.
