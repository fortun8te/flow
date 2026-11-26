# Cleanup inference optimization

Working procedure, **26 November 2026**. Optimize the deployed cleanup path on the **M1 Max / 32 GB**; use the **RTX 5080 / 16 GB** for separate CUDA experiments and training. This change adds runtime fixes and a repeatable comparison harness. **No hardware throughput, latency improvement, memory ceiling or trained checkpoint is claimed here.**

The procedure adapts the [inference-optimisation skill](https://github.com/sybil-solutions/inference-optimisation-skill/tree/fda968e7fc1996aa23c67139c755fe541c9d4be0), especially its [measurement methodology](https://github.com/sybil-solutions/inference-optimisation-skill/blob/fda968e7fc1996aa23c67139c755fe541c9d4be0/skills/inference-optimisation/references/methodology.md) and [engine gotchas](https://github.com/sybil-solutions/inference-optimisation-skill/blob/fda968e7fc1996aa23c67139c755fe541c9d4be0/skills/inference-optimisation/references/gotchas.md). The linked revision is an external reference, not an installed dependency. Flow's acceptance workload is dictation and selected-text cleanup. Generic chat or tool-call benchmarks do not establish performance on that workload.

## 1. Measure what delays the user

The primary application metric is **key release to verified delivery**, with failure rate and harmful-edit rate beside it. A higher generation rate alone can lose if loading, word repair, delivery queuing or readback takes longer. Keep these cases separate:

- Cold start after process launch or idle eviction; include actual weight loading and preparation.
- Warm requests, including the first real request after the authored warmup.
- Short dictation, long sectioned dictation, and Opt+1 selected-text repair.
- A new recording beginning while an older dictation is finishing.
- Recognition and cleanup sharing the Mac's memory bandwidth; replaying HTTP alone excludes this competition.

`VoiceApp.swift` records monotonic pipeline timings. `transcriptAtMs`, `handoffAtMs`, `pasteSentAtMs` and `deliveryCompleteAtMs` are offsets from key release. `cleanupMs`/`modelMs`, `postCleanupMs`, `deliveryQueueMs`, `deliveryMs` and `readbackMs` are durations. `postCleanupMs` includes the final rules, word judges, vocabulary and layout; it is not another model-only timing. `pasteAtMs` remains a legacy alias for delivery completion. An unverified completion or timeout must not count as a verified paste.

During microphone dictation, capture starts before Accessibility target inspection and optional model preparation. Selected cleanup, TinyFix, TinyNext/lexicon, D1 and eligible CTC preparation can overlap recording. This is preparation of existing models, not speculative cleanup of an unstable transcript. The system-audio capture route still has asynchronous startup and needs its own native measurement. Check first-audio latency and audio continuity while warming; moving work earlier does not make its CPU, GPU or memory cost disappear.

## 2. Current engine inventory

These are source defaults, not proposed faster settings. Record the actual binary, model, profile, adapters and flags used in each experiment.

| Path | Existing relevant settings | First question to measure |
|---|---|---|
| DOSE1 / WhisperNow | `llama-server`, context 8,192, one slot, GPU layers 99, Jinja template; request `cache_prompt=false`; optional LoRA adapter scale | Does cache reuse improve real short cleanup requests without breaking adapter/profile isolation? |
| TypoFix | Context 12,288 across three slots; GPU layers 99; flash attention on; `ngram-simple` speculation with `n=4`, `m=12`, max draft 12; three startup warmups; `cache_prompt=true`; greedy, thinking off, output cap 3,000 | Do three slots and this draft policy help the actual typing/Opt+1 overlap, including memory and tail latency? |
| General catalog model | Catalog context size (default 8,192), one slot, GPU layers 99; optional catalog binary/arguments; `cache_prompt=true`; greedy, thinking off | Which context and engine configuration meets the real request budget for the selected artifact? |
| S1 / Qwen MLX | Existing model-specific prompt, tokenizer, generation and quantization settings | How much is load/preparation versus generation, and does any converted artifact preserve native output? |
| TinyNext context scoring | Accelerate, existing int8 weights, bounded contexts and batches | How many distinct contexts are scored, and what portion of post-cleanup time remains? |

Source: `WhisperNowTunedPolisher.swift`, `T2CleanupRequest.swift`, `TypoFixModel.swift`, `GeneralCleanupModel.swift`, `S1MiniPolisher.swift`, `Qwen3Polisher.swift`, `TinyNextScorer.swift`. DOSE1's existing `bench/e1_adapter_speed.py` probes adapter/cache behavior; the repository does not contain a result proving that enabling its prompt cache is a win.

This pass makes shared model loads independently cancellable, publishes readiness before callers resume, rejects stale load completions, and avoids starting the DOSE1 fallback when the selected General model is already ready. It does not terminate an active fallback. S1 no longer rescans its cache metadata on each warm request. TinyNext deduplicates exact-byte contexts within a scoring call, stops cancelled work, and declines oversized contexts instead of silently judging a truncated one. `tinynext-batch` records requested and unique context counts. Existing quality thresholds stay unchanged.

### Bounded work and personalization during dictation

The vocabulary rescoring path captures one immutable set of trusted terms, guard names and threshold settings per transcription. All its chunks use that view; the next transcription can see newly learned words. Session reuse keys on the exact term bytes and acoustic settings, while guard evidence is supplied by the current recording snapshot. Adding a nonboostable name therefore updates the guard without requiring a new acoustic model session.

Optional CTC work shares an allowance of `min(6, 1.8 + 0.015 × decodedWindowWords)` seconds, minus time already consumed. Overlapping windows can contribute to the word count but cannot exceed the six-second cap. A timeout exhausts the remaining allowance for that recording. Flow falls back to primary ASR while a native CoreML operation finishes; its exclusive lease is released only when the underlying operation exits, so a timed-out waiter cannot start overlapping work on the same rescoring session. This bounds Flow's optional wait, not an uninterruptible CoreML kernel's physical execution time. It is separate from the cleanup/paste budget and is not a six-second full-pipeline SLO.

CTC remains overlapped with the following TDT window, with at most one pending CTC request. Pure insertions or deletions from auxiliary rescoring retain the primary ASR words. Shared model preparation has independently cancellable waiters. `asr-vocabulary` run notes identify preparation, busy, timeout, no-candidate and guarded-result paths without recording word text in those timing notes.

While recording, a utility task prepares imported snippet rules and the small personalization profile. Warm reads open/stat bounded regular files; decoding and regex compilation occur only on revision changes. Entity patterns are compiled once and resolve overlaps against original text, preserving enclosing code and reserving literal placeholder tokens. Positive correction classification and persistence move off the main actor after Accessibility evidence has been captured. Recent-history caches avoid repeated JSON decoding, and indexed history queries avoid full scans of growing recording tables. Measure these changes on-device with actual dictionaries; test completion times are not inference benchmarks.

## 3. Freeze the workload and environment

Use a frozen **validation** snapshot from [TRAINING.md](TRAINING.md). Keep the final test set out of engine search. Cover clean text that should stay unchanged, names and multiword dictionary terms, numbers and corrections, negation, URLs/code, long sections, and the editing modes you intend to support. Exact output equivalence is a useful lossless-optimization check, but a matching incorrect baseline remains incorrect; reviewed quality evaluation is still required.

For Flow versus a complete dictation product, use [COMPETITIVE-HILLCLIMB.md](COMPETITIVE-HILLCLIMB.md). That comparison binds actual audio, field context and vocabulary and measures release-to-verified-insertion timing. Keep it separate from the engine-only HTTP replay below.

Save an experiment record outside the repository containing:

- Flow commit/source fingerprint; server commit/build and command; model and every shard hash; tokenizer, chat template and adapter hashes; quantization.
- Hardware, OS, power source/profile, thermal state, background load, and the selected ASR engine.
- Context size, slots, batch/microbatch sizes, GPU offload, attention, KV precision, speculation, cache policy, output limit and deadline.
- Dataset identity, input length distribution, exact system prompt and user prefix, template kwargs, warmup and repetition counts.
- Cold/warm results, request failures, memory observations, output differences, and the decision, including rejected experiments.

Use AC power and a fixed power profile. Run only one competing model experiment at a time. Drain requests and stop only the process you own before swapping its configuration; do not pattern-kill all model servers. Keep working model/configuration copies for rollback. On Apple silicon, process RSS alone does not describe all unified-memory pressure; inspect system pressure/swap and the runtime's GPU allocation reporting as well. On CUDA, record VRAM and host-memory use separately. Treat a failed memory probe as missing evidence, not zero usage.

Measure sustained bandwidth on the actual machine before using a bandwidth/model-bytes estimate as an optimistic decode bound. Include KV reads and attention work at the tested context length. Prefill has a different compute/memory balance. Do not substitute advertised peak bandwidth, an assumed utilization factor or a different GPU's result for a measured ceiling. The current ceiling and memory-headroom measurements are **not measured**; fill them from the device before attempting aggressive engine changes. Do not raise kernel memory limits or alter system power settings automatically.

## 4. Run control, candidate, control

`scripts/run_flow_candidate.py` talks only to an already-running loopback OpenAI-compatible endpoint. It does not launch servers, install weights, alter Flow settings or retry a failed attempt. It runs complete dataset rounds instead of repeating a single prompt consecutively, and retains every attempt's output, latency, finish reason, error and available server token counts. An authored warmup is recorded separately. Use at least **six measured attempts per case**.

The client reuses its actual connection, with an absolute I/O watchdog covering headers and body. A slow drip cannot renew a per-socket timeout indefinitely: expiry shuts down the socket, joins the watchdog and records the failed attempt. There is no background request worker or retry. Oversized requests/responses, incomplete or ambiguous HTTP framing, duplicate/non-finite JSON and non-text completion shapes fail explicitly. Exact CRLF prompt/prefix bytes are preserved. See [TRAINING.md](TRAINING.md#replay-a-candidate-locally) for the 2 MiB payload/256 KiB configuration limits, verified multi-file artifact manifest, output reservation and aborted-run handling. HTTP cancellation does not establish that the server has finished internal GPU work; drain the owned process before changing its configuration.

Start from the exact replay command in [TRAINING.md](TRAINING.md), with the actual artifact, prompt, runtime identity and editing contract. Add:

```sh
--warmup-requests 1 --repetitions 6 --cache-prompt off
```

The cache flag is an example for the existing DOSE1 control. Use `on` for a control that already caches, or `server-default` to omit the request flag. The complete command is, for example:

```sh
FLOW_EXPERIMENT="$HOME/flow-train/engine-experiment"
mkdir -p "$FLOW_EXPERIMENT"
python3 scripts/run_flow_candidate.py \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --endpoint http://127.0.0.1:8080/v1/chat/completions \
  --model local-cleanup \
  --artifact "$HOME/models/baseline.gguf" \
  --prompt "$HOME/flow-train/cleanup-system.txt" \
  --runtime-id "REPLACE-with-exact-server-hardware-and-control-flags" \
  --environment-id "REPLACE-with-fixed-hardware-OS-and-power-profile" \
  --warmup-requests 1 --repetitions 6 --cache-prompt off \
  --out "$FLOW_EXPERIMENT/control-before.jsonl"
```

Replace the example paths and identities before running. Set the same explicit `--environment-id` in the before, candidate and after runs; engine comparison requires it to be nonempty and equal. This is a declared hardware/OS/power identity, not hardware attestation. Supply `--user-prefix-file FILE` when the model requires a control line, including its exact newline; `--chat-template-kwargs FILE` reads a UTF-8 JSON object file and is only appropriate for a server verified to support those arguments. The generic default HTTP request is not automatically the same as native S1, T2, DOSE1 or Opt+1 preprocessing. Match and inspect the exact contract before interpreting a result as evidence for that path.

Change **one** engine knob. Run the same workload into `candidate.jsonl`, changing its precise runtime ID and, when applicable, `--cache-prompt`. Restore the original control configuration and run again into `control-after.jsonl`. The two control identities must be identical. Do not change the environment identity, model, prompt, prefix, template kwargs, timeout, output limit, warmup policy or number of repetitions during this lossless engine comparison.

```sh
python3 scripts/flow_engine_tune.py \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --before "$FLOW_EXPERIMENT/control-before.jsonl" \
  --candidate "$FLOW_EXPERIMENT/candidate.jsonl" \
  --after "$FLOW_EXPERIMENT/control-after.jsonl" \
  --out "$FLOW_EXPERIMENT/engine-report.json"
```

The report verifies frozen dataset/prediction hashes, complete case alignment, attempt records, chronological nonoverlapping runs, stable outputs and matching workload/model/prompt identity. Only runtime identity and cache policy may vary for the candidate. Its initial screening policy requires:

- At least six attempts per case and a successful separate warmup.
- No empty, truncated, timed-out, malformed or failed attempt, and exact output agreement across all attempts and all three runs. Explicitly reviewed newline-only targets use the same narrow layout exception as the quality gate.
- No switch in reported server model identity within or between the runs. A consistently missing identity is reported as unavailable and does not attest model loading.
- At most 10% symmetric drift between controls in median, p95 and each case's median **and p95** latency.
- Candidate median latency at least 5% lower than **both** controls, no worse aggregate p95, and no case median **or p95** more than 5% slower than the faster control.

These are explicit pilot thresholds, not a confidence interval or a validated production SLO. Too few samples, control drift or request failures makes the result inconclusive. A candidate that changes output needs the reviewed quality gate in `flow_hillclimb.py`, plus native checks; it cannot claim a lossless engine win. A report can mark `eligibleForReview`; it always leaves `promoted: false`.

The added per-case p95 checks close a concrete gap in an aggregate-only tail gate: a short case can become twice as slow at its tail while a long case still determines the aggregate p95. Invented regression fixtures hold medians steady, double only a short case's tail, and verify rejection for candidate regression or an inconclusive result for control drift. The existing 5% per-case allowance now applies to both median and tail; it remains a screening policy, not an empirically established production threshold. Measured overruns and reported generation counts above the configured cap are failures even if a sample's status claims success.

The HTTP runner is nonstreaming. It measures request wall time and, only when **every successful sample supplies actual completion token usage**, reports `completionTokensPerRequestSecond`. That is completion throughput including request/prefill overhead. It is **not decode tokens/second or time to first token**. Missing usage stays missing. Do not count stream chunks, estimate tokens from characters or label whole-request elapsed time as decode time. A future streaming probe must timestamp first generated token separately and validate the server's usage semantics.

## 5. Order of experiments

1. **Remove repeated work.** Verify the shared-load, warm-cache, duplicate-context and dictionary changes first. Confirm cancellation releases obsolete work and that warmup does not delay the first audio frame.
2. **Prompt reuse.** Compare cache policy with the same prompt/template and adapters. Test different dictation inputs, adapter switches and mixed short/long requests; six repeats of one cached answer are not a realistic workload.
3. **Context and batching.** Measure one-slot dictation first. Try context and microbatch settings one at a time, within actual longest input and memory needs. A concurrency throughput win cannot justify worse single-dictation tail latency.
4. **Speculation.** Measure the existing TypoFix ngram draft policy against an explicit control. Record accepted draft tokens and verifier work when the engine exposes them. More draft tokens can add work; do not assume a bigger draft or MTP helps this small cleanup workload.
5. **Precision or model changes.** Different weight/KV precision, conversions and new models need quality evaluation, protected-literal checks and long-input stability. A changed weight artifact is outside the strict same-model engine gate. Use the model plan and reviewed quality gate before any default changes.

After a candidate clears replay, build the native candidate app on macOS. Verify selected-text behavior, sectioned deadlines, fallback/readback, rapid successive dictations, recording overlap, memory after idle eviction, and fresh chronological examples. Preserve the baseline artifact/configuration and restore it if any guard, delivery, audio or quality regression appears. Save failures and negative results alongside successes so the next experiment starts from evidence rather than repeating the same guesses.

For the custom-model path and honest implementation gaps, see [CUSTOM-MODEL-PLAN.md](CUSTOM-MODEL-PLAN.md) and [CUSTOM-MODEL-EXPERIMENTS.md](CUSTOM-MODEL-EXPERIMENTS.md).

## 6. Reproduce harness measurements

These measurements cover Python replay bookkeeping and a deliberately broken local HTTP response. **No cleanup-model throughput, native app latency, GPU memory use or on-device model-quality improvement was measured.**

Run from this checkout with the trusted baseline commit already present in local Git:

```sh
python3 scripts/benchmark_replay_harness.py \
  --baseline 533db16c4c449132337916ee9fe78ae8235aae08 \
  --cases 250 --repetitions 12 --output-bytes 8192
python3 -m unittest discover -s Tests -p 'test_flow_replay_transport.py'
python3 -m unittest discover -s Tests -p 'test_flow_engine_tune.py'
```

`benchmark_replay_harness.py` loads that local commit's runner/export code, creates invented deterministic outputs, retains every attempt, writes/hashes a temporary JSONL file, and removes it afterward. Its memory probe excludes preallocated case fixtures and uses Python `tracemalloc`, not process RSS or model-memory accounting. It also runs the old/new clients against the same fabricated server behavior: two response bytes every 20 ms with an 80 ms declared deadline. Request bodies are invented; no existing model server or personal data is used. Deadline watchdogs are cancelled and joined, which the transport regression tests check after successful and timed-out requests.

Observed on Linux, Python **3.12.14**, on 26 November 2026:

| Measurement | Baseline `533db16` | Updated harness |
|---|---:|---:|
| Cases / retained attempts | 250 / 3,000 | 250 / 3,000 |
| Peak traced Python allocations during replay + write/hash | 76.630 MiB | 3.238 MiB |
| Retained traced Python allocations after write/hash | 24.499 MiB | 2.920 MiB |
| Prediction JSONL bytes | 27,325,320 | 27,325,320 |
| Slow-drip elapsed time, 80 ms declared deadline | 2,044.04 ms | 81.08 ms |
| Requests sent for that failed slow-drip attempt | 1 | 1 |

Both memory runs produced SHA-256 `8cff051fa4f76048fa40580bb94b2a22f0585e167be9a932637af9364fe795ed`, confirming identical retained prediction bytes. Sharing identical immutable outputs and streaming the JSONL/hash cut peak traced allocation by about **95.8%** in this repeated-output workload. Gains depend on output repetition and corpus size; all distinct outputs still require their own evidence. Both slow-drip samples correctly retained a deadline failure, but the old client waited for the whole response before returning it. The updated client interrupts I/O at its deadline; observed return time includes thread scheduling and cleanup overhead. One fault-injection run is not a latency distribution or a model speed benchmark.

The real loopback integration test also verifies that one authored warmup plus six scored requests use one TCP connection, and that a failed connection is closed before the next independent request. It validates the resulting private prediction/manifest pair with `flow_engine_tune.load_run` rather than checking only an HTTP response.
