# Harness reliability and validation record

This records the broad follow-up audit after commit `533db16c4c449132337916ee9fe78ae8235aae08`. It separates reproducible fixes and measured harness work from native application/model results that still need a Mac and installed weights. The changes do not establish that every bug is gone or that Flow beats another product.

## Which harness answers which question?

| Path | What its result establishes | What it does not establish |
|---|---|---|
| `export_flow_runs.py` | A reviewed, input-bound, isolated dataset snapshot, or an explicitly blocked export | Raw collection, unchanged output or an observed edit is not independent approval |
| `flow_hillclimb.py` | Paired quality/latency screening over the same complete reviewed cases | No automatic model promotion or semantic-equivalence proof |
| `run_flow_candidate.py` + `flow_engine_tune.py` | Local HTTP replay and controlled engine-setting screening with retained attempts | HTTP cannot attest the server's loaded weights or measure native paste latency |
| `CleanupReplayHarness.swift` | Native preparation and post-ASR cleanup replay using application components | It omits live field capture, paste/readback, remote cleanup, key-release timing and the privacy-disabled D1 path |
| `flow_competition.py` | Screening of declared same-audio native product captures and blind review | Capture/blinding declarations are not attested; the report never announces a competitive win |
| `test_portable_swift.py` | Actual Foundation production source exercised by XCTest on Linux or macOS | No AppKit, Accessibility, MLX/Metal, FluidAudio, or complete application build |

Use [TRAINING.md](TRAINING.md), [COMPETITIVE-HILLCLIMB.md](COMPETITIVE-HILLCLIMB.md), and [INFERENCE-OPTIMIZATION.md](INFERENCE-OPTIMIZATION.md) for complete command and schema contracts.

## Failures reproduced and corrected

### Evidence and learning integrity

An imported run could carry its own `reviewedLabel` and enter supervision without an external label file. An ambiguous duplicate JSON key could replace `undo` with `edited`. Reused run/Changes-card identifiers could lose the alias referenced by an Undo. These now fail closed: raw observations cannot approve themselves, JSON keys are unique, and ambiguous feedback owners are quarantined.

Recording identity is now useful even when a row is unreviewed or retracted. Such a row can link two examples to the same audio and reveal train/validation/test overlap; it never supplies a training target. Conflicting reviewed targets retain their family links before exclusion. Dataset loading validates every supervised split, actual row counts, hashes, source identities, review provenance, constraints and family isolation. Declared split-lock history must match its retained bytes and case assignments. Legacy snapshots without a declared lock remain readable only when their actual contents pass validation; they cannot prove historical isolation.

Source snapshots include change time and device identity, and label files are checked for replacement or mutation while reading. A changed label snapshot is refused before replacing the previous export. Existing rollback/Undo evidence and corrupt-source supervision blocking remain in force.

### HTTP requests and engine tuning

The former per-socket-operation timeout let slow-drip responses run far beyond the declared request budget. The new loopback transport shuts down the socket at the request deadline, cancels/joins its watchdog, keeps no request worker running, and never retries the failed sample. Successful samples reuse their connection. A timed-out server may still be computing internally: drain it before changing configurations; a client disconnect does not prove GPU cancellation.

Bounded response/configuration parsing, strict JSON, exact completion shape, explicit status/usage checks and HTTP framing validation prevent malformed or incomplete output from passing as a successful cleanup. Model artifact manifests hash all listed files and retain their declared/resolved bindings; changed bytes or symlink targets invalidate the run. Run locks prevent output collisions, input/dataset paths cannot become output files, and incomplete runs retain `running`/`aborted` state rather than old successful predictions.

Engine tuning now checks each case's tail latency in controls and candidates, in addition to medians and aggregate p95. It rejects measured deadline overruns and token-cap violations even if imported evidence omitted an error. An explicitly reviewed newline-only target uses the shared layout-aware empty-output rule. A changing reported server model makes a comparison inconclusive; consistently missing model identity remains unavailable evidence.

### Native replay durability and identity

The native JSONL reader now splits only on LF bytes. Literal U+2028, U+2029 and NEL inside a JSON string remain text; CRLF record endings also decode correctly. Invalid input identifies its physical line without copying the transcript into the diagnostic. Missing text, blank/duplicate job IDs, negative limits, unreadable files and corrupt journals are refused.

The native output uses `PrivateDataFile`: 0600 files, 0700 newly created directories, no symlink/special-file writes, bounded coordination, complete writes and checked synchronization. Existing general-purpose output-directory permissions remain unchanged; the CLI does not chmod the user's whole chosen directory to make one result private. App-owned stores retain their existing private-directory default. A separate session lease owns the output across asynchronous model calls, so two proof processes cannot resume/write the same journal concurrently. A new append cannot join a crash-truncated tail. Resumption refuses a corrupt journal and preserves its original bytes; it does not silently discard evidence.

Results contain a `replay_key`. It binds the exact input JSONL bytes, semantic configuration, effective process preferences, executable bytes, ordered vocabulary, preferred spellings, learned replacements/spellings/conflicts, imported replacement/profile files and the general-model catalog. Audio preparation additionally hashes the actual source audio files, deduplicating repeated paths. Files are checked for replacement or change while hashing. Preference values retain type information, including dates and binary data, to avoid identity collisions with ordinary dictionaries.

Changing only the proof cap, input/output location, or permission to coexist with Flow does not change the experiment identity. Changing the underlying input bytes, audio, settings, personalization, mode, or executable does. Duplicate successful result IDs are refused; failed attempts may precede a later successful attempt with the same ID.

The identity uses the configuration values selected by the typed decoder, not a second interpretation of raw JSON: Foundation's decoders can choose different values for a duplicate key. It also uses effective defaults, including fallback domains. Before and after each attempted native case, a cheaper state fingerprint rechecks effective preferences, learned-dictionary revision, exact vocabulary bytes and personalization/catalog file identities. A change or unreadable state stops the batch. An already attempted call retains a failure row rather than publishing its text under the old key. Model status strings are excluded because they describe runtime readiness, not an experimental setting. Executable/audio hashing is not repeated for every case.

**Migration:** outputs produced before `replay_key` are not silently reused. Keep the old file and choose a fresh output for this version. A corrupt/truncated existing output also requires recovery or a new output. There is no implicit truncation or relabeling of old results.

The explicit native model selector accepts `s1-mini`, `qwen3`, `dose1`, and the legacy `whispernow-tuned` alias. Unknown selections fail instead of silently benchmarking S1. An explicitly requested missing DOSE1 also fails. Qwen replay must successfully prepare its complete local cache before running; it no longer claims readiness while all outputs are rule fallbacks. Every cleanup row retains the observed engine and selected route, including ordinary non-`live_finish` rows. Section refusal flags include every section, and an unedited layout-only path reports a skip rather than an empty status.

Native ASR/cleanup durations and ETA use `PipelineTimer`'s monotonic clock. Prepare and ASR-only runs return failure when any attempted clip fails while retaining each error row; ASR boost overrides reset on all exits. The long-prose/explicit-newline section decision now matches the live route's word threshold and model-owned transcript distinction.

Audio preparation no longer retains an unused second full recording-sized Float array in `CaptureReplay.Result.samples`. Diagnostic sample collection is explicit (`collectSamples: true`) for the DSP equivalence test. Normal replay still writes the converted CAF and computes its speech-presence metrics; this change does not claim a measured native RSS reduction or make the entire AVFoundation conversion streaming.

The native resume key is **not** a full loaded-model attestation. It does not hash every MLX/GGUF/tokenizer dependency or prove that model/audio bytes stayed unchanged during an inference. Keep those artifacts frozen during a native replay. Use a fresh output after a weight replacement and the manifest-based Python runner/native capture protocol for artifact-specific comparisons. Personalization is checked around each case, not locked against every external writer for the entire batch. The native replay also still differs from live deadline accounting and has no field/paste timing; its `cleanup_ms` cannot stand in for end-to-end latency.

### Runtime and vocabulary work

`SharedModelTask` releases completion-owned resources before publishing success or failure. A next CTC window therefore cannot receive a completed result while the old model lease still reports busy. Owner cancellation remains prompt without releasing the underlying work's lease early.

`CleanupModelCatalog` caches one indexed, immutable catalog per file revision. It rejects oversized/nonregular input and discards stale settings when a revision becomes invalid. Numeric settings reject booleans, retain exact integer byte sizes and require a representable server context size.

Prompt terms keep preferred spelling and input priority through deduplication, ranking ties and prompt-prefix limits. Phonetic ranking computes one score per term with unchanged scoring rules. The bounded cache keys exact vocabulary/suspect byte arrays, including field boundaries; canonical Unicode equivalence and bare hash collisions cannot substitute a different spelling. These changed prompt semantics advance run-record `pipelineVersion` to **6**; the record schema remains **2**.

Smart insertion now classifies Unicode opening/closing delimiters and quotation marks. Fullwidth and corner brackets do not gain unwanted interior spaces, and quoted list/heading/fence literals do not gain stray outer newlines. For example, inserting `blue` into `Use （） now` produces `Use （blue） now`; inserting `- literal` into `Use “” now` stays inside the quotes on the same line. This is tested boundary behavior, not a claim that every language's typography is fully modeled.

### Candidate packaging

Package validation refuses unresolved placeholders in plist keys or values, an incorrect leaf signer, failed/overdue signing commands, invalid executable paths and malformed permission JSON. A refused plist or signature stops verification before candidate execution. Denied or not-yet-requested permissions remain valid states; verification does not require granting access. These subprocess contracts were tested under controlled fixtures; actual macOS signing and launching remain a native gate.

## Reproducible performance evidence

The baseline for Python comparisons is `533db16c4c449132337916ee9fe78ae8235aae08`. Measurements use invented data, Python 3.12.14 and Linux x86_64. Both implementations retain equivalent evidence. They measure harness computation/allocation or fault behavior, not model inference, application memory or Mac latency.

| Measurement | Baseline | Updated | Exact scope |
|---|---:|---:|---|
| Median repeated-output scoring | 1,401.15 ms | 244.47 ms | 80 cases × 400 words × 6 identical attempts; five alternating trials; identical score results; 5.73× on this run |
| Peak extra serialization allocations | 26,715,677 bytes | 15,343 bytes | 5,000 already-materialized rows; identical 13,233,890-byte JSONL and hash; excludes input rows and RSS |
| Peak replay/write allocations | 76.630 MiB | 3.238 MiB | 250 cases × 12 attempts × 8,192-byte repeated output; identical 27,325,320-byte JSONL |
| Slow-drip request return time | 2,050.65 ms | 81.18 ms | One fault-injected request per implementation, 80 ms declared budget; both retain failure; includes scheduling/cleanup overhead |
| Warm catalog lookup median, 4 models | 45.09 ms | 15.02 ms | Swift 6.2.1 `-O`, 2,000 lookups, five alternating trials; 595-byte synthetic catalog |
| Warm catalog lookup median, 64 models | 618.31 ms | 15.00 ms | Same protocol, 9,097-byte synthetic catalog |
| Vocabulary score evaluations | 1,044 | 64 | Fixed 64-term production-helper regression; identical ranking; work count rather than timing |

Timing varies across runs. Identical-output sharing saves less memory when outputs differ, and score caching benefits repeated deterministic text rather than every possible workload. No score, attempt, timeout or slow sample is discarded to produce these measurements.

Reproduce Python measurements:

```sh
python3 scripts/benchmark_flow_evaluation.py --baseline-ref 533db16
python3 scripts/benchmark_replay_harness.py \
  --baseline 533db16c4c449132337916ee9fe78ae8235aae08 \
  --cases 250 --repetitions 12 --output-bytes 8192
```

The Swift catalog commands and all measured helper constraints are in [ENGINE.md](ENGINE.md). These scripts execute the trusted local baseline source; use the pinned revision from this repository.

## Verification and release boundary

Integrated verification on 2026-11-26 (Linux x86_64, Python 3.12.14, Swift 6.2.1 in Swift 5 language mode):

| Check | Result | Scope |
|---|---:|---|
| `Tests/test_*.py` | 225 passed | Export, replay, tuning, native-capture evidence, package contracts and existing Python helpers |
| `bench/test_*.py` | 37 passed | Existing benchmark metrics, alignment, artifact and worker-lifecycle regressions |
| `training/t2/test_*.py` | 39 passed | Synthetic training-data/contracts/tooling |
| `Tests/PolishEval/test_*.py` | 9 passed, 16 skipped | Legacy fixture-dependent evaluation; skipped assets are unavailable |
| Portable Swift XCTest | 273 passed, 27 suites | Actual Foundation production helpers, without app/model substitutes |
| Swift parsing | 354 source/test files passed | Syntax verification only; not native type checking or an app build |
| Python compilation | 15 changed/new files passed | Import-time syntax/bytecode compilation |
| Whitespace validation | `git diff --check` passed | Changed tracked source and documentation |

This totals **310 Python tests and 273 Foundation Swift tests passed**, with **16 explicit skips**. Native-only DSP/replay integration assertions were added or updated but are not included in the portable pass count.

Run the portable suites from the repository root:

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 -m unittest discover -s bench -p 'test_*.py'
python3 -m unittest discover -s training/t2 -p 'test_*.py'
python3 -m unittest discover -s Tests/PolishEval -p 'test_*.py'
python3 scripts/test_portable_swift.py --swiftc /path/to/swiftc
git diff --check
```

The portable Swift runner compiles actual production helpers, not application/model substitutes. Tests cover concurrency, leases, numeric limits, catalog invalidation, prompt ordering/ranking, private persistence, replay identities, layout, insertion boundaries, readback and correction evidence. Python tests include real temporary loopback servers for HTTP deadlines, connection reuse, framing and aborted-run behavior. Some legacy PolishEval fixtures are absent and those cases skip explicitly.

Before release, build and test the complete application on the target Mac, then exercise actual model loading and Metal/ANE work, capture/stop/cancel overlap, long recordings, dictionary changes, newline-only and multiline dictation, Opt+1, multiple editors, live Accessibility readback, and signed candidate verification. Measure warm/cold end-to-end latency, p95 tails, peak memory and quality on frozen reviewed audio. Keep the PR a draft until those native gates are satisfied.

The custom-model research and experiments remain in [CUSTOM-MODEL-PLAN.md](CUSTOM-MODEL-PLAN.md) and [CUSTOM-MODEL-EXPERIMENTS.md](CUSTOM-MODEL-EXPERIMENTS.md). Better collection becomes useful through independent review, stable splits, complete replay evidence, controlled interventions and a retained final holdout. These changes strengthen that loop; they do not train or automatically install a new model.
