# Training and evaluation

This document describes the training, dataset and evaluation scripts in this repository, what each one needs, and what privacy rules apply. The reviewed-data export, local replay and candidate gate described below form an offline evaluation loop. Model training and native application validation remain separate steps. They need your own data and hardware; private dictation must stay private.

## Privacy rules first

- Training data is made from real speech. The run records described in [DATA.md](DATA.md) contain your transcripts and your recogniser's words. Keep them, and anything made from them, out of version control and out of shared storage.
- The examples in `training/t2/` (`seeds_public.py`, `seed_bank.py`, `gen_typing*.py`, `gen_dictation*.py`) are generated from invented templates and seed lists that their docstrings describe as not drawn from private dictation. Review them before publishing any generated output.
- `Tests/PolishEval/polish-eval-cases.json` holds invented dictations written for evaluation. Do not add real dictations to it.

## What is in the repository

### S1 cleanup dataset builders

- `training/build_s1_dataset.py` builds a chat-format training set for the S1-mini cleanup model from `train`, `valid` and `test` JSONL files in a folder you supply (`~/Library/Application Support/VOICE/WisprCleanupTuning-v2/` by default, as its header comment says). Those files are not included.
- `training/build_s1_dataset_v2.py` is the stricter v2 rule. A target may delete only fillers and adjacent duplicate words, plus a true self-correction (a cue such as "no wait" with the corrected value kept). Any other deletion, or any digit or content word the input does not contain, drops the pair. Pairs that keep numbers, names or a corrected value are duplicated so they weigh more. A small Dutch set is passed through unchanged. Output goes to `~/Library/Application Support/VOICE/S1Tuning-v2/`.
- Both scripts hold out a test split and a set of evaluation cases. They never train on those cases, and they use `Tests/PolishEval/polish-eval-cases.json` as the evaluation set.
- `training/eval_cases.py` runs a model (MLX, through `mlx_lm`) over the evaluation cases and reports the results.

### Synthetic data generators (`training/t2/`)

- `gen_typing.py` and `gen_typing_v2.py` create typed-text samples with simulated typos, slang and shorthand. Each sample is checked by `check_t2.py`.
- `gen_dictation.py` and `gen_dictation_v2.py` create spoken-style samples with fillers, self-corrections and spoken punctuation.
- `seed_bank.py` and `seeds_public.py` hold the seed phrases and templates. Their docstrings say the text was not taken from anyone's dictations, chats or notes. `t2_common.py` holds shared rates and helpers, with a fixed random seed for repeatable output.
- `check_t2.py` and `polish_contract.py` define the checks a sample must pass, and `POLISH_CONTRACT.md` describes the editing contract.
- The generator tests exercise the synthetic data pipeline.

Output goes to a `--out` path you choose, for example `samples/typing.jsonl`. The generators write under the directory you name, so keep that directory out of version control (see `.gitignore`).

### Run-record export

`scripts/export_flow_runs.py` separates observations from independently reviewed training targets. Its output is private and defaults to a folder outside the repository. A successful paste says only that text landed. It does not prove the cleanup was correct. Keeping an Opt+1 result or leaving text unchanged is likewise not a human label.

| File | Purpose |
| --- | --- |
| `runs-joined.jsonl` | Full runs plus linked follow-ups, for local analysis |
| `dictation-pairs.jsonl`, `opt1-pairs.jsonl` | Observations, proposed corrections, provenance, and explicit eligibility |
| `stage-pairs.jsonl` | Model/rule output changes for diagnostics; always unsupervised |
| `review-queue.jsonl` | Unlabelled, undone, conflicting or quarantined observations |
| `train.jsonl`, `valid.jsonl`, `test.jsonl` | Only explicit human-reviewed examples, grouped and deduplicated |
| `split-lock.json` | Persistent text-family membership and split assignment |
| `manifest.json` | File hashes/counts, dataset identity, label counts and malformed-input diagnostics |

Without a reviewed-label file the supervised files are empty. This is intentional. An imported raw record's embedded `reviewedLabel` is discarded; only the separately supplied review file can attach an approved target. Schema-2 scoped corrections carry `feedbackSource: "observed-edit"`, `targetScope: "pasted-span"` and the corrected insertion span in `editedText`. The exporter exposes that span as `proposedTarget`; it still needs review. Legacy field-wide edits are never used as targets. Undo/rejection invalidates supervision even if a reviewed label exists. Conflicting run IDs and conflicting targets for the same normalized input are excluded. A reused run ID with a different Changes-card or recording identity is also a conflict: overwriting an older alias must not hide its Undo. Feedback that could refer to one run's ID or another run's Changes card leaves both observations awaiting review.

```sh
python3 scripts/export_flow_runs.py --out "$HOME/flow-train/runs"
```

Review the source and the proposed target, then create a private JSONL label file. Each line must contain the run's `id`, its exact `inputHash` copied from the export, a reviewed full-span `target`, `source: "human-reviewed"`, and `scope: "pasted-span"` for dictation or `"selection"` for Opt+1. Do not use the entire document surrounding a dictation as its target. An invented example of the shape is:

```json
{"id":"example-run","inputHash":"COPY_THE_EXPORTED_INPUT_HASH","target":"The violet kettle is on shelf 2.","source":"human-reviewed","scope":"pasted-span","mustContain":["violet kettle","shelf 2"],"mustNotContain":["copper kettle"]}
```

`mustContain` and `mustNotContain` are optional literal lists. Use them for protected names, identifiers and requirements that automated heuristics cannot infer. They must agree with the reviewed target and become part of the case hash. An altered label cannot silently reuse predictions for the earlier case.

For a case whose line layout has been explicitly reviewed, add `"requireExactLayout": true` to that label. This is a strict, opt-in contract for the target's exact newline characters and their positions between whitespace-separated tokens, boundary blank lines, indentation, Markdown hard-break spaces, and list, heading, quote, checkbox and code-fence prefixes. Ordinary interior word spacing, spelling and case remain separate quality measures. Adding or deleting words before a break moves its position and also requires review under this strict contract. Use it for spoken line/paragraph commands, nested lists, code indentation and existing user formatting; do not enable it automatically on unreviewed observations.

For example, a reviewed target of `"Tasks:\n  - Carry the kettle.  \n  - Lock the door."` can require its indentation and hard breaks even while word accuracy is being improved. A reviewed `"new line"` recording may use `"target": "\n"` only with `"requireExactLayout": true`; empty strings and spaces-only targets remain invalid. All such examples still require the same human review and scope/input binding. The exporter preserves this policy through deduplication and binds it into `caseHash`, so enabling it requires fresh predictions and native audio-review bindings. Existing cases with the flag absent or false keep their prior case hashes.

Both the local hillclimb and native competition reports include `reviewedLayoutCases` and `exactLayoutRate` (`null` when none were reviewed). Any retained attempt that breaks a required layout receives a `changed_layout` critical failure and blocks eligibility, even when word error improves. This adds no automatic labels, training run, model promotion or competitor-performance claim.

```sh
python3 scripts/export_flow_runs.py \
  --labels "$HOME/flow-train/reviewed-labels.jsonl" \
  --out "$HOME/flow-train/runs"
```

Each export rebuilds the snapshot instead of appending training rows. Repeating it after an Undo removes that target from the current corpus. Retain the complete reviewed-label file between exports; omitting it produces an observation-only snapshot. Files are replaced atomically with mode 0600 in a 0700 output directory. JSONL serialization hashes and writes one row at a time, avoiding a second full serialized corpus in memory while preserving the same bytes and hashes. A serialization failure leaves that file's previous complete contents intact. The manifest is written last, and evaluators verify the supervised file hashes before consuming them. This remains a sequence of atomic file replacements, not a filesystem-wide atomic transaction; a partial snapshot fails validation.

Malformed JSON/UTF-8/schema, unreadable files, unknown record kinds, or files that change during reading block supervised export. JSON objects with duplicate keys and non-finite numbers are rejected, including nested duplicates and numeric overflow such as `1e999`: an ordinary JSON decoder could otherwise let a later `followup` key replace an earlier Undo. A damaged line might contain an Undo, so skipping it cannot safely preserve an earlier positive label. The exporter writes diagnostic observations, empties all three supervised files (including a previous export), marks the manifest blocked and returns a failure exit code. Source checks include device/inode, size and nanosecond modification/change times. A review file that changes while it is being consumed also refuses export before replacing the previous snapshot. Freeze complete stable source and label snapshots or wait for the app's write to finish, repair any corruption without dropping feedback, then rerun. The replay and comparison tools refuse blocked snapshots.

### Stable training and evaluation splits

The split policy assigns about 80% of text families to training, 10% to validation and 10% to final testing. It groups case/spacing/punctuation variants of the input, identical corrected targets, runs sharing a recording identity, and any connected families. Repeated copies of the same example receive one training row rather than additional weight. The same target with several ASR-error variants stays in one split. Existing records supply `audioPath`; imports can supply `audioSHA256`, `sourceRecordingID` or `recordingID` (directly or in settings). The exporter hashes those identifiers and never opens audio files. Copies or renamed audio files need the same content hash or stable source recording id to be recognized as one recording.

Recording links from unreviewed and undone observations also participate in family history. For example, an unreviewed replay carrying both an old audio path and a content hash can establish that two reviewed cases came from the same recording. Its observed text does not become a target. Conflicting reviewed target links are retained as possible contamination evidence even though their examples are excluded. Removing supervision must not manufacture an apparently independent held-out family. Newly discovered bridges can therefore quarantine cases that an earlier export kept separate; review the resulting corpus before rerunning an experiment.

Always reuse the output directory and preserve `split-lock.json`. Historical family links remain in the lock even after source logs rotate. If new evidence connects a previously trained family to a held-out family, the connected component is quarantined. The exporter does not silently turn trained text into a clean evaluation case. Deleting the lock from an existing snapshot fails closed.

Export uses a nonblocking process lock for the whole output transaction, so concurrent exporters cannot overwrite each other's split history. A second writer gets a clear error and must rerun after the first finishes. `.export.lock` stays in place; its presence alone is normal, and the OS releases ownership when a process exits or crashes. Do not delete it while an exporter is running. The previous manifest's split-lock hash is checked before reusing history; an edited/reset lock must be restored with its matching snapshot. Export runs on macOS/Linux. A missing source directory fails before changing any export.

Loading a frozen dataset validates all three supervised files, including unselected training/test rows and row counts. Case IDs and source-run IDs cannot be reused, input/target/recording families cannot cross splits or claim different independent groups, and any stored input hashes and review provenance must agree with the exact input. When the manifest declares `splitLockSHA256`, the lock must exist, match that hash and agree with every case's family and split. Legacy schema-2 snapshots without that field remain readable if their actual rows pass the full overlap checks; those snapshots cannot establish historical split integrity, so preserve or restore the original history before extending them. Valid empty splits remain allowed. Case-file hashes describe the exact bytes parsed, even if a file changes after the verified read.

This catches exact/normalized overlap, not all semantic paraphrases or overlap with a base model's pretraining. Review new evaluation families for near-duplicates, keep a separate fresh chronological release set, and keep the final test set out of prompt search, parameter tuning, teacher generation and training. The candidate gate cannot prove that an external training process respected these boundaries.

### Replay a candidate locally

`scripts/run_flow_candidate.py` replays the frozen reviewed cases against an already-running local OpenAI-compatible cleanup server. It sends the raw input, the supplied system prompt, and any explicit user prefix, never the reviewed target. It does not launch a server, install weights, change Flow settings, or retry a failed request. Only loopback endpoints are allowed; HTTP redirects and proxy routing are disabled.

```sh
python3 scripts/run_flow_candidate.py \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --endpoint http://127.0.0.1:8080/v1/chat/completions \
  --model local-cleanup \
  --artifact "$HOME/models/baseline.gguf" \
  --prompt "$HOME/flow-train/cleanup-system.txt" \
  --runtime-id "server-build-EXACT; quant-Q8; flags-EXACT" \
  --environment-id "Mac-model-EXACT; chip-EXACT; RAM-EXACT; OS-EXACT; power-EXACT" \
  --out "$HOME/flow-train/baseline.jsonl"
```

Load the candidate using your normal local engine, then repeat with its actual artifact, prompt and runtime identity and a different output path. `--artifact` identifies one actual model file. For sharded models or separate adapters/tokenizer/template files, use `--artifact-manifest FILE` instead. Its JSON format is `{"schemaVersion":1,"files":[{"path":"weights-01.safetensors","sha256":"ACTUAL_64_CHARACTER_SHA256"}]}`. List every required file with a unique relative path inside the manifest's directory; absolute paths, parent traversal and escaping symlinks are refused. The runner reads and hashes each member, refuses a mismatched shard, and checks that the manifest/model files have not changed during replay. It does not accept a manifest's hash claims without checking the bytes. The artifact must still match what the server loaded; an HTTP endpoint alone cannot attest the in-memory weights. Use comparable hardware, engine flags, and background load for both runs.

Request templates are explicit. The prompt and `--user-prefix-file FILE` preserve their exact UTF-8 bytes, including CRLF and trailing newlines; `--chat-template-kwargs FILE` sends a JSON object to servers that support that field. Configuration files are limited to 256 KiB each, and duplicate JSON keys or non-finite numbers are refused. Verify server support first. The S1 default user input starts with `[Styling: semi-formal] [Structure: prose] [Context: general]` and a newline, and its native chat template disables thinking. Passing only the raw transcript changes that task. Supplying the prefix alone still does not reproduce native S1: this runner uses a fixed token budget and does not execute Flow's guards, fallback stages or paste pipeline. Validate an actual candidate through the native application before release.

One authored warmup request runs by default and is recorded separately. `--warmup-requests 0` permits cold inspection, but it cannot pass the calibrated timing gate. A nonblocking lock reserves the output directory for one replay. Before requests begin, old predictions are cleared and the manifest is marked `running`; exceptions, interruption and warmup failure leave an empty prediction file and `aborted` manifest. Output paths cannot overwrite the supplied dataset, model or request configuration. `--repetitions 6` repeats the entire dataset six times in fixed order; it does not pick the fastest or best answer. All attempts are retained, including slow, empty, truncated and failed replies. Repeated output changes count as instability. The comparison's p50/p95 use every measured attempt, including failures, rather than the medians of each case. Identical immutable output strings share memory, and JSONL is written/hashed a row at a time without assembling the whole repeated corpus twice.

The client reuses a real HTTP connection across sequential requests and bypasses proxies and redirects. An absolute request watchdog interrupts a slow-drip header or body by shutting down its socket; it is joined on success or failure, and failed requests are never retried. The next independent attempt opens a new connection after a transport failure. Request and response bodies are capped at 2 MiB. Ambiguous framing, incomplete HTTP bodies, duplicate/non-finite JSON, multiple choices, tool/refusal replies and invalid completion shapes count as failures. A successful HTTP status cannot excuse a measured deadline overrun or reported completion count above the requested cap. `localhost` connects to IPv4 loopback explicitly; use `[::1]` for an IPv6-only server. A client disconnect cannot prove that a model server stopped its internal computation, so drain the owned server before changing experiment configurations.

Every prediction records the immutable configuration digest, case and dataset hashes, output, measured request latency and any failure. The configuration digest covers the supplied artifact, prompt, exact prefix, template options, runtime/environment identities, runner plus imported harness source, transport policy, temperature, token limit, timeout and prompt-cache request option. `--environment-id` declares hardware, OS and power regime separately from engine flags. Engine tuning requires that identity to be nonempty and identical in every run; it cannot attest the declaration itself. The companion manifest records the complete dataset/prediction hashes, actual start/end timestamps, warmup evidence and replay protocol. The server's reported model name is retained when supplied; engine comparisons reject a switch across samples or controls, while consistently missing evidence remains explicitly unavailable. `--cache-prompt on|off|server-default` makes a cache experiment explicit; support and semantics depend on the server. These timings cover nonstreaming HTTP cleanup calls, not the complete ASR-to-paste path. Optional token counts come only from the server's `usage` fields; missing counts remain unavailable.

### Compare and decide whether to keep a change

```sh
python3 scripts/flow_hillclimb.py \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --baseline "$HOME/flow-train/baseline.jsonl" \
  --candidate "$HOME/flow-train/candidate.jsonl" \
  --out "$HOME/flow-train/candidate-report.json"
```

The comparison fails on stale, duplicate, missing or extra predictions, non-finite latency, mismatched case hashes, mismatched complete dataset identities (including app/settings context), or mixed configuration identities. It measures token-edit distance to the independent target, exact-match rate, paired wins/losses, and p50/p95 latency. Default review eligibility requires all of these:

- At least 50 independent text families, not 50 repeats of one example.
- Matching replay protocols with successful warmup for both configurations.
- At least a 2% relative reduction in aggregate token-edit error.
- A one-sided paired sign-test result at or below 0.05 across independent families.
- No empty/runtime failures or detected changes to ordered numbers, negation count, URLs, emails, inline code, or the reviewed literal constraints.
- No new error on a case where the baseline already exactly matched the reviewed target; aggregate wins cannot outweigh damaging those cases.
- Candidate p95 cleanup latency no more than 10% above the baseline.
- No aggregate error regression in an app or editing mode with at least ten cases.

Every retained attempt still contributes its latency, completion status and failure evidence. A reply beyond its declared request deadline counts as a runtime failure even if an imported capture omitted its error flag. Repeated identical output text shares one exact-distance/guard computation within that case; its error distance is weighted by its actual repetition count, and different outputs retain their own checks and instability failure. This reduces offline evaluator work without selecting a preferred repeat or changing the quality denominator. `scripts/benchmark_flow_evaluation.py --baseline-ref COMMIT` runs an invented-data comparison against an earlier scorer, checks exact result equality and records serializer peak allocations. It measures evaluator/serialization cost, not model inference or application responsiveness.

The thresholds are initial screening policy, not a measured claim about Flow quality. Every report includes the exact policy. Small samples or tied quality cannot pass. These deterministic checks do not establish semantic equivalence: negation scope, relationships between entities, unannotated names, and many meaning changes still need human review. Token-edit distance also penalizes some harmless alternative phrasings. Review the reported regression case IDs locally and evaluate the actual editing contract.

The report records the baseline as `rollbackCandidateID`, the candidate/configuration identity, dataset identity and prediction hashes. It reports `eligibleForReview` and always leaves `promoted: false`; nothing changes the installed model. Preserve the model artifact and configuration for both baseline and candidate. A rejected candidate leaves the baseline in use.

Use validation to select among prompt/rule/parameter/model variants, then freeze one candidate and run the held-out test once before release. Repeatedly testing variants on the final test leaks evaluation information. Also run the Swift regression suite, replay end-to-end native dictations, and check guard/fallback/paste behavior and real hardware latency before changing Flow's default. A better standalone cleanup score does not establish better application behavior.

This loop makes collection useful over time: collect observed corrections and failures, review a batch, regenerate a versioned corpus, train or change one component, compare it with the current baseline, and keep only a verified improvement. Collection by itself does not train a model or guarantee improvement.

### Compare the complete dictation product

Use `scripts/flow_competition.py` and [COMPETITIVE-HILLCLIMB.md](COMPETITIVE-HILLCLIMB.md) to freeze actual audio/context/dictionary identities and compare complete Flow and Wispr captures. Its timing contract is key release to verified insertion, its targets are reviewed against audio, and its optional output reviews are blind and bound to exact output hashes. Missing reviews or incomplete evidence cannot qualify a candidate. The tool consumes locally supplied captures; it does not drive Wispr, access a Canto API, upload recordings or manufacture competitor results. Keep the HTTP cleanup gate for component experiments and the full-pipeline gate for product claims.

### Evaluation and preparation scripts (`scripts/`)

Several scripts compare Flow's cleanup against reference output, prepare evaluation sets from imported dictation history, and convert or package models. Their names describe their purpose. The ones that read imported dictation history expect that history to be on your own disk. Examples:

- `eval-cleanup-vs-wispr.py`: score cleanup output against reference text.
- `prepare-wispr-*.py`, `import-wispr-*.py`, `prepare-style-data.py`: prepare data from an imported dictation export.
- `make-candidate.py` is the build command for a Flow candidate app, and `candidate_check.py` holds the pre-install checks it uses. Invalid plist roots, unresolved `$(...)`/`${...}` keys or values, missing microphone usage text, unexpected leaf signing identity and failed signature verification stop the check before the binary runs. Signing checks and the no-launch permission probe each have a 30-second timeout. The probe must return a JSON object with a supported microphone state and boolean Accessibility state; denied or not-yet-requested permissions are valid probe results, while a list of key names is not.
- `fuse-convert-s1.sh`: turns a merged BF16 S1-mini into the 4-bit MLX folder Flow loads. `whispernow-to-gguf.sh`: converts a merged WhisperNow model to GGUF at several quantisation levels, then runs a sanity check.
- `provision-voice-models.py`: plans, or explicitly installs, the pinned public model artifacts from the manifests. It runs no models.

Most of these scripts keep their own configuration at the top of the file. Read the header before running one.

### Benchmark harness (`bench/`)

`bench/flow_bench.py` and the modules beside it benchmark recognition and cleanup engines. `bench/engines.json` lists the engines. The harness finds `llama-server` by name. Tests for the harness are in `bench/test_*.py`.

Scorer version 2 treats an error, empty output, missing/unknown finish reason, token-limit truncation, or invalid timing as a failed call, even if the returned text happens to match the reference. Failed attempts stay in the quality denominator and all-call timing distribution. Tables show failed-call and timing counts, plus separate successful-call timings in saved summary data. A call never attempted after a worker failure has unavailable latency, not an invented zero. A run with any failed calls exits unsuccessfully while preserving its results.

Suite IDs must align exactly: duplicate, extra or missing outputs fail. A run records the exact suite fingerprint, configuration/harness hashes, GGUF/template hashes or every MLX weight shard and tokenizer/configuration file. Rescoring requires the same frozen suite; legacy rows without that fingerprint require a rerun. Summary tables reject older scorer versions so a changed success definition cannot silently look like a model improvement. Optional artifact hash caching uses file identity and nanosecond modification/change times, checks for changes during hashing, and lives outside the repository.

The MLX worker emits a result after every case. Separate load and per-case watchdogs terminate and reap a hung worker, preserve earlier results, and mark the pending/unattempted cases as failures. It reads actual generation finish metadata instead of inferring completion from output length. The harness's exact token edit-distance implementation trims common ends and uses integer bitmasks to reduce Python scoring work; its tests compare against reference dynamic programming, including Unicode and long inputs. This changes evaluation cost without approximating the score.

These single-pass benchmark timings mix first-generation and later work and are labelled uncalibrated. For a proposed engine speed change, use the repeated replay runner with `scripts/flow_engine_tune.py` and the control/candidate/control procedure in [INFERENCE-OPTIMIZATION.md](INFERENCE-OPTIMIZATION.md). That tool verifies the run manifests, workload/model/prompt identity, every attempt, chronology, control stability and exact observed output equivalence. It cannot change the installed engine. Its six-sample minimum is pilot screening; nearest-rank p95 with six samples is the maximum, so noisy or near-budget results need longer runs. Whole-request completion throughput uses reported completion tokens divided by request time; it is not decode TPS or a TTFT measurement.

## What is not in the repository

The following are left out on purpose:

- model weights, LoRA adapters and GGUF files;
- dictation data, run records, evaluation outputs and any held-out split made from real speech;
- the round-by-round training harnesses that were used on one machine, and the Windows launchers. They hard-code private paths and host names, and they are not portable.

Rebuilding a model from scratch therefore needs your own data and your own hardware. The scripts above show the shape of each step.

## Running the tests

Run the app and script tests from the repository root.

```sh
swift test
python3 -m unittest discover -s Tests
python3 -m unittest discover -s training/t2
python3 -m unittest discover -s bench
python3 -m unittest discover -s Tests/PolishEval
python3 scripts/test_portable_swift.py --swiftc /path/to/swiftc
```

The portable Swift command checks Foundation-only logic on a machine with Swift installed; it does not replace building/testing the macOS app. The end-to-end polish replay uses the debug Flow executable. Some tests need optional fixtures or models and report a skip when those are absent.

## Hardware notes

The dataset builders and generators run on any machine with Python 3. Model training and evaluation with `mlx_lm` need Apple silicon. Some training was done on a separate CUDA machine. The scripts kept here do not depend on it.
