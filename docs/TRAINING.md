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

Without a reviewed-label file the supervised files are empty. This is intentional. Schema-2 scoped corrections carry `feedbackSource: "observed-edit"`, `targetScope: "pasted-span"` and the corrected insertion span in `editedText`. The exporter exposes that span as `proposedTarget`; it still needs review. Legacy field-wide edits are never used as targets. Undo/rejection invalidates supervision even if a reviewed label exists. Conflicting run IDs and conflicting targets for the same normalized input are excluded.

```sh
python3 scripts/export_flow_runs.py --out "$HOME/flow-train/runs"
```

Review the source and the proposed target, then create a private JSONL label file. Each line must contain the run's `id`, its exact `inputHash` copied from the export, a reviewed full-span `target`, `source: "human-reviewed"`, and `scope: "pasted-span"` for dictation or `"selection"` for Opt+1. Do not use the entire document surrounding a dictation as its target. An invented example of the shape is:

```json
{"id":"example-run","inputHash":"COPY_THE_EXPORTED_INPUT_HASH","target":"The violet kettle is on shelf 2.","source":"human-reviewed","scope":"pasted-span","mustContain":["violet kettle","shelf 2"],"mustNotContain":["copper kettle"]}
```

`mustContain` and `mustNotContain` are optional literal lists. Use them for protected names, identifiers and requirements that automated heuristics cannot infer. They must agree with the reviewed target and become part of the case hash. An altered label cannot silently reuse predictions for the earlier case.

```sh
python3 scripts/export_flow_runs.py \
  --labels "$HOME/flow-train/reviewed-labels.jsonl" \
  --out "$HOME/flow-train/runs"
```

Each export rebuilds the snapshot instead of appending training rows. Repeating it after an Undo removes that target from the current corpus. Retain the complete reviewed-label file between exports; omitting it produces an observation-only snapshot. Files are replaced atomically with mode 0600 in a 0700 output directory. The manifest is written last, and evaluators verify the supervised file hashes before consuming them.

Malformed JSON/UTF-8/schema, unreadable files, unknown record kinds, or files that change during reading block supervised export. A damaged line might contain an Undo, so skipping it cannot safely preserve an earlier positive label. The exporter writes diagnostic observations, empties all three supervised files (including a previous export), marks the manifest blocked and returns a failure exit code. Freeze a complete source snapshot or wait for the app's write to finish, repair any corruption without dropping feedback, then rerun. The replay and comparison tools refuse blocked snapshots.

### Stable training and evaluation splits

The split policy assigns about 80% of text families to training, 10% to validation and 10% to final testing. It groups case/spacing/punctuation variants of the input, identical corrected targets, runs sharing a recording identity, and any connected families. Repeated copies of the same example receive one training row rather than additional weight. The same target with several ASR-error variants stays in one split. Existing records supply `audioPath`; imports can supply `audioSHA256`, `sourceRecordingID` or `recordingID` (directly or in settings). The exporter hashes those identifiers and never opens audio files. Copies or renamed audio files need the same content hash or stable source recording id to be recognized as one recording.

Always reuse the output directory and preserve `split-lock.json`. Historical family links remain in the lock even after source logs rotate. If new evidence connects a previously trained family to a held-out family, the connected component is quarantined. The exporter does not silently turn trained text into a clean evaluation case. Deleting the lock from an existing snapshot fails closed.

Export uses a nonblocking process lock for the whole output transaction, so concurrent exporters cannot overwrite each other's split history. A second writer gets a clear error and must rerun after the first finishes. `.export.lock` stays in place; its presence alone is normal, and the OS releases ownership when a process exits or crashes. Do not delete it while an exporter is running. The previous manifest's split-lock hash is checked before reusing history; an edited/reset lock must be restored with its matching snapshot. Export runs on macOS/Linux. A missing source directory fails before changing any export.

This catches exact/normalized overlap, not all semantic paraphrases or overlap with a base model's pretraining. Review new evaluation families for near-duplicates, keep a separate fresh chronological release set, and keep the final test set out of prompt search, parameter tuning, teacher generation and training. The candidate gate cannot prove that an external training process respected these boundaries.

### Replay a candidate locally

`scripts/run_flow_candidate.py` replays the frozen reviewed cases against an already-running local OpenAI-compatible cleanup server. It sends only the raw input and the supplied system prompt, never the reviewed target. It does not launch a server, install weights, change Flow settings, or retry a failed request. Only loopback endpoints are allowed; HTTP redirects and proxy routing are disabled.

```sh
python3 scripts/run_flow_candidate.py \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --endpoint http://127.0.0.1:8080/v1/chat/completions \
  --model local-cleanup \
  --artifact "$HOME/models/baseline.gguf" \
  --prompt "$HOME/flow-train/cleanup-system.txt" \
  --runtime-id "server-build-EXACT; quant-Q8; Mac-model-EXACT; flags-EXACT" \
  --out "$HOME/flow-train/baseline.jsonl"
```

Load the candidate using your normal local engine, then repeat with its actual artifact, prompt and runtime identity and a different output path. For sharded models, supply a manifest containing hashes of every shard as `--artifact`. The artifact must match what the server loaded; an HTTP endpoint alone cannot verify that. Use comparable hardware, engine flags, background load and warm/cold state for both runs. Repeat latency measurements before deployment if the budget is close.

Every prediction records the immutable configuration digest, case hash, output, measured latency and any failure. The configuration digest covers the supplied artifact, prompt, runtime identity, temperature, token limit and timeout. The companion manifest records the complete dataset and prediction-file hashes. Timeout, truncated or malformed replies stay in the output as failures; they are not dropped from the denominator. These timings cover the HTTP cleanup call, not the complete ASR-to-paste path.

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
- At least a 2% relative reduction in aggregate token-edit error.
- A one-sided paired sign-test result at or below 0.05 across independent families.
- No empty/runtime failures or detected changes to ordered numbers, negation count, URLs, emails, inline code, or the reviewed literal constraints.
- No new error on a case where the baseline already exactly matched the reviewed target; aggregate wins cannot outweigh damaging those cases.
- Candidate p95 cleanup latency no more than 10% above the baseline.
- No aggregate error regression in an app or editing mode with at least ten cases.

The thresholds are initial screening policy, not a measured claim about Flow quality. Every report includes the exact policy. Small samples or tied quality cannot pass. These deterministic checks do not establish semantic equivalence: negation scope, relationships between entities, unannotated names, and many meaning changes still need human review. Token-edit distance also penalizes some harmless alternative phrasings. Review the reported regression case IDs locally and evaluate the actual editing contract.

The report records the baseline as `rollbackCandidateID`, the candidate/configuration identity, dataset identity and prediction hashes. It reports `eligibleForReview` and always leaves `promoted: false`; nothing changes the installed model. Preserve the model artifact and configuration for both baseline and candidate. A rejected candidate leaves the baseline in use.

Use validation to select among prompt/rule/parameter/model variants, then freeze one candidate and run the held-out test once before release. Repeatedly testing variants on the final test leaks evaluation information. Also run the Swift regression suite, replay end-to-end native dictations, and check guard/fallback/paste behavior and real hardware latency before changing Flow's default. A better standalone cleanup score does not establish better application behavior.

This loop makes collection useful over time: collect observed corrections and failures, review a batch, regenerate a versioned corpus, train or change one component, compare it with the current baseline, and keep only a verified improvement. Collection by itself does not train a model or guarantee improvement.

### Evaluation and preparation scripts (`scripts/`)

Several scripts compare Flow's cleanup against reference output, prepare evaluation sets from imported dictation history, and convert or package models. Their names describe their purpose. The ones that read imported dictation history expect that history to be on your own disk. Examples:

- `eval-cleanup-vs-wispr.py`: score cleanup output against reference text.
- `prepare-wispr-*.py`, `import-wispr-*.py`, `prepare-style-data.py`: prepare data from an imported dictation export.
- `make-candidate.py` is the build command for a Flow candidate app, and `candidate_check.py` holds the pre-install checks it uses.
- `fuse-convert-s1.sh`: turns a merged BF16 S1-mini into the 4-bit MLX folder Flow loads. `whispernow-to-gguf.sh`: converts a merged WhisperNow model to GGUF at several quantisation levels, then runs a sanity check.
- `provision-voice-models.py`: plans, or explicitly installs, the pinned public model artifacts from the manifests. It runs no models.

Most of these scripts keep their own configuration at the top of the file. Read the header before running one.

### Benchmark harness (`bench/`)

`bench/flow_bench.py` and the modules beside it benchmark recognition and cleanup engines. `bench/engines.json` lists the engines. The harness finds `llama-server` by name. Tests for the harness are in `bench/test_*.py`.

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
