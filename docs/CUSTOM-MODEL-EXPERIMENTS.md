# Custom-model experiments: collection to deployment

Working plan, **26 November 2026**. Train on the **RTX 5080 / 16 GB VRAM / 128 GB host RAM**; measure the deployed app on the **M1 Max / 32 GB memory**. No training run, model conversion or hardware speed measurement is claimed by this document. Architecture research and primary sources are in [CUSTOM-MODEL-PLAN.md](CUSTOM-MODEL-PLAN.md).

The first experiment is an acceptance calibrator over existing word scores. A custom candidate ranker follows only if the remaining failures justify it. Sentence normalization is a separate S1-mini experiment. The intended result is fewer user corrections with fewer harmful edits, not merely a new model name.

## 1. What exists, and what must be implemented

| Capability | Current state | Next acceptance check |
|---|---|---|
| Private run collection and independent transcript labels | Implemented in `FlowRunLog.swift` and `scripts/export_flow_runs.py` | A complete stable snapshot exports without integrity diagnostics; unreviewed output never becomes a target |
| Candidate observations, including KEEP | Implemented in `WordDecisionEvidence.swift`, the collector and scorer hooks | Inspect a private replay containing both applied and rejected alternatives; verify span/score correspondence |
| Candidate review and supervised feature builder | **To implement** | Reviewed labels bind to the exact observation; repeated runs, missing answers and ambiguous alignments are handled explicitly |
| CPU calibrator and CUDA ranker trainer | **To implement** | A reproducible train-only pilot produces a versioned checkpoint and held-out predictions |
| Local cleanup HTTP replay and comparison | Implemented in `scripts/run_flow_candidate.py` and `scripts/flow_hillclimb.py` | Same frozen cases, actual artifacts, prompt/template contract, hardware and failure accounting |
| S1 data conversion and training | Existing historical dataset builders are specific to imported Wispr data; a reviewed Flow adapter and portable CUDA trainer are **to implement** | No reshuffle or promotion of observed edits; exact S1 message format and assistant-only loss |
| Native S1 replay | `CleanupReplayHarness.swift` and `S1MiniPolisher.swift` exist; `supportedVariants` currently permits only `stock` | A custom candidate selector must verify/load the intended artifact before a tuned model can pass this gate |
| Native custom ranker | **To implement** | Python/export/Swift numerical parity, unchanged protected spans, bounded memory and correct fallback |

Do not use a command invented for a future trainer. The commands below invoke existing tools; configuration examples for future trainers are explicitly marked as contracts to implement. Nothing here automatically changes the installed model.

## 2. Establish a usable corpus first

Keep all observations, labels, checkpoints and results outside the repository. Respect `voice.privacyMode`, `flow.saveRunRecords` and secure-field scrubbing; see [DATA.md](DATA.md). Do not enable collection on behalf of an experiment that has been opted out.

From the repository root, export a stable source snapshot and review the resulting queue. A changing or malformed source blocks supervision; repair the complete snapshot without deleting inconvenient feedback.

```sh
umask 077
FLOW_TRAIN_ROOT="$HOME/flow-train"
python3 scripts/export_flow_runs.py \
  --source "$HOME/Library/Application Support/VOICE/training" \
  --out "$FLOW_TRAIN_ROOT/runs"
```

Use the explicit label format documented in [TRAINING.md](TRAINING.md), then rerun against the **same output directory**:

```sh
python3 scripts/export_flow_runs.py \
  --source "$HOME/Library/Application Support/VOICE/training" \
  --out "$FLOW_TRAIN_ROOT/runs" \
  --labels "$FLOW_TRAIN_ROOT/reviewed-labels.jsonl"
```

Keep the previous successful export and its `split-lock.json` when creating a new numbered experiment snapshot. Do not create a new split registry for each experiment. Stop writers or otherwise freeze the source before copying a snapshot, and validate the copied files before use. The exporter has a transaction lock and manifest hashes; those are integrity checks, not permission to train on a partially copied directory.

Initial review priorities are harmful edits, unchanged clean text, names, quantities, negation, code, repeated words, and unfamiliar terms. Sample ordinary successful-looking runs too: a failure-only corpus cannot estimate the real false-positive rate. An observed user edit is a review proposal; successful paste, no Undo, and a scorer's choice are not positive labels.

**Stage input matters.** A run's `input` is raw ASR or an Opt+1 selection. A word scorer sees a later immutable draft. Its offsets refer to that draft, not raw ASR or the final field. A cleanup target should describe the desired normalization before paste-boundary spacing. A pasted-span label can contain spaces or punctuation supplied by smart insertion; review or derive that stage-specific target explicitly and record the derivation. Do not silently teach a sentence model to predict neighboring field text it never receives.

## 3. The candidate observation contract

Production `WordDecisionEvidence` schema 1 is an optional `wordDecisions` array on a run record. Older run records remain readable. `runs-joined.jsonl` preserves the array; the transcript training-pair exports do not currently turn it into candidate training rows.

Each observation contains:

| Field | Meaning and invariant |
|---|---|
| `stage`, `mode`, `modelID` | Scorer, `dictation`/`typed`/`slips`, and the runtime model label |
| `context`, `contextSpan` | Exact source slice and its absolute UTF-16 location/length before that scorer edits the draft |
| `original`, `sourceSpan` | Exact judged span in that same draft; it must match the corresponding context code units |
| `candidates` | Actual scorer order, original at index zero; candidate text, finite `rawScore`, optional finite `adjustedScore`, finite numeric `features` |
| `chosenIndex` | Production rule's selection; zero means KEEP, with no claim of human approval |
| `margin`, `threshold` | Stage-specific decision value and actual required threshold; these are not probabilities |
| `schemaVersion` | Observation contract version, currently 1 |

Collection is capped at **64 observations per run**, **2,048 UTF-16 units of context**, **2–9 distinct candidates**, **128 UTF-16 units per candidate**, and **16 numeric features per candidate**. Invalid ranges, split surrogate pairs, non-finite values, missing KEEP and malformed evidence are omitted. Candidate uniqueness uses exact UTF-8 bytes; context/original matching uses exact UTF-16 units. Canonically equivalent Unicode strings can tokenize differently and must not be silently substituted.

The collector checks privacy and run-record preferences before collection and rejects late callbacks after finishing. Secure-field scrubbing removes the entire array. The writer also validates and bounds directly constructed records. These checks do not add model calls.

Current scorer features are deliberately limited:

| Stage | Scores and rule features now recorded | What is still absent |
|---|---|---|
| TinyFix | All original/alternative raw logits; adjusted rule values; `cost`, `knownMixup`, `rawMargin`, `unknownNearby`; actual threshold includes the unknown-neighbor penalty | Immutable artifact digest in the observation; independently reviewed choice |
| Sound-alike | Whole-context log-probabilities, difference from original, `learnedPair`, actual learned/default threshold | Token counts; acoustic evidence; independent reviewed choice |
| Low-confidence | Whole-context log-probabilities, difference from original, `asrFlagged` | Numeric confidence aligned to this particular occurrence; token counts; independent reviewed choice |

TinyFix's top-level `margin` stores its adjusted decision value; its raw difference is in the alternative's `rawMargin`. TinyNext stages use the difference in summed sequence log-probabilities. Do not mix these units or interpret the legacy `RealWordFixer.Fix.probability` heuristic as measured confidence.

The recorded context is original text. TinyFix still normalizes case, name tokens, sentence starts and newline tokens internally. Capture the exact candidate-generation/tokenization configuration before reproducing its model inputs. The runtime `modelID` values are role names, not proof of the weight file loaded. Every experiment must separately hash the installed model and tokenizer artifacts.

The collection cap is an engineering bound, not a representative sampling policy. Earlier stages or earlier words can consume it. Report coverage by stage and input length. A future offline feature pass can collect complete decisions from frozen reviewed examples using the same production logic. Never fill missing decisions with assumed KEEP labels.

## 4. Candidate labels and features: the next implementation

Implement a separate private review file; do not write gold labels back into runtime observations. A proposed review row must contain:

- `runID`, observation index, and `observationSHA256` over the canonical serialized observation;
- the SHA-256 of the exact `runs-joined.jsonl` snapshot, source run lineage and inherited split/group ID;
- `source: "human-reviewed"`, `scope: "word-span"`, reviewer timestamp, and reviewed exact replacement text;
- `acceptableCandidateIndices`, when the answer is represented, or an explicit `answerAbsent`/`ambiguous` disposition;
- protected literals or a meaning-failure category when applicable.

The builder must verify the hashes, candidate order, span and input identity before consuming a label. A model-generated answer is only a proposal until reviewed. A full-transcript label does not establish every word decision automatically: repeated words, multiword edits and downstream cleanup can make alignment ambiguous. Quarantine those cases rather than guessing.

The general export `datasetID` hashes supervised transcript files. It does **not** by itself bind `runs-joined.jsonl` candidate observations. Define a separate candidate-corpus identity over observation bytes, review bytes, feature version and the inherited split registry.

For the calibrator, select the best non-KEEP candidate using the frozen baseline rule, then predict whether applying that candidate is correct. KEEP is correct only when the reviewer says the original is acceptable. If the intended answer is missing, label the policy to abstain and count the example as a coverage failure; do not describe it as correctly recognized text.

Start with these numeric features: raw candidate-minus-original score, adjusted decision value, gap to the next candidate, threshold excess, candidate count, character-length difference, and the logged stage-specific features above. Use separate models or explicit stage/mode indicators. Fit scaling and any clipping ranges on train only. Represent absent optional features with a missingness indicator; missing ASR confidence is not zero confidence. `asrFlagged` means the current recognizer flagged a word form, not a calibrated occurrence-specific probability.

Do not derive acoustic evidence from spelling similarity. Optional later features require actual new data: occurrence-aligned ASR confidence/timing, alternative acoustic scores, phonetic distance with a named algorithm/version, and TinyNext token counts. The last feature can help study the length preference in summed log-probabilities; changing score normalization is a separate ablation.

## 5. Split before learning or generating variants

Inherit the exporter's persistent 80/10/10 train/valid/test family assignments. It joins normalized inputs, targets, known recording identities and historical family links; connecting old train and held-out families quarantines the component. Preserve `split-lock.json` and its matching manifest.

All candidates, alternate ASR decodes, synthetic corruptions, teacher proposals and later observations from the same recording/document family inherit one split. Create synthetic training variants **after** assigning the original public source/document. Keep public licenses and provenance. Check semantic near-duplicates manually or with a separately validated detector; the current exact/normalized grouping does not establish their absence.

Within train, reserve deterministic family groups for inner cross-validation if a calibrator needs parameter selection. Use valid to choose among the declared candidate variants. Freeze one configuration before opening final test results. Keep a fresh chronological release set as a separate check on changing vocabulary and workloads. Do not refresh a model using its recent test failures and then claim that same set is untouched test data.

## 6. Experiments in order

Keep recognizer, dictionary snapshot, guards, formatter, workload and hardware fixed when comparing one component.

| Experiment | Change | Question answered |
|---|---|---|
| B0 | Current full pipeline, pinned weights/settings | What is the real baseline? |
| B1 | Disable word scorers; retain other stages | Are word corrections helping overall? |
| C0 | Current candidates/scores + calibrated acceptance | Is most harm in the acceptance rule? |
| R0 | Custom ranker, exactly the baseline candidate sets | Does a new representation rank better? |
| R1 | Same ranker + separately versioned phonetic/dictionary candidates | Is candidate coverage the remaining limit? |
| S0 | Unmodified S1 and installed DOSE1, separately pinned | Which sentence normalizer wins on this workload? |
| S1 | S1 LoRA, same prompt/template/routing/guards as S0 | Does personalization improve normalization? |

Do not combine R1 with a new cleanup model in the first comparison. If a safety guard rejects a candidate, include the fallback in end-to-end metrics and separately record the model proposal. A more permissive guard must not hide a worse model.

### Calibrator configuration to implement

Use a logistic model first, with L2 candidates `0.001`, `0.01`, `0.1`, train-fitted standardization and stage/mode separation. Keep class prevalence representative during evaluation even if training balances rare harmful edits. Compare raw-score-only versus all-available-feature models. Select the operating threshold on valid by the harmful-edit budget and correction benefit, then freeze it. Report reliability bins, Brier score and calibration error as well as classification metrics. No probability should reach the runtime until its calibration has been measured on the intended mode.

Begin with 500–2,000 reviewed decisions spanning both actions and clean KEEP examples. This is a collection target, not a guarantee of sufficient power. If errors are too rare to estimate, collect more representative opportunities rather than lowering the gate.

### Ranker configuration to implement

Initial architecture hypothesis: a shared 20K×128 context embedding; separate 128-hidden GRUs for 16 left and four right tokens; a 32-dimensional byte embedding and 64-hidden candidate encoder; and a 128-hidden scoring head using context, candidate and optional numeric features. This is approximately a 3M-parameter design; calculate the exact count from the implemented module and record it. A word-only baseline isolates the benefit of the byte candidate representation.

Score original plus at most eight alternatives; use an explicit KEEP/abstain policy. Start with AdamW, learning-rate candidates `1e-4` and `3e-4`, weight decay `0.01`, gradient clipping `1.0`, a pilot microbatch of 64 decisions and a maximum of ten epochs with early stopping. These are proposed starting settings, not validated hyperparameters. Run seeds 7, 17 and 29 for the selected configuration, recording run variation. Candidate padding needs a mask and must never win an argmax or receive target probability.

First verify learning on a small licensed public-text/synthetic-confusion set; then adapt with 2,000–10,000 reviewed decisions plus correctly unchanged and public replay examples. Personal data alone is not a general-language pretraining corpus. Freeze vocabulary construction to training/public data. Never add test spellings to the vocabulary or confusion tables during evaluation.

### S1 configuration to implement

Use the exact `S1MiniPolisher.systemPrompt`, user control line and chat template. The current default control line is:

```text
[Styling: semi-formal] [Structure: prose] [Context: general]
```

The user message is that line, one newline, then the transcript. Native input sets `enable_thinking: false`. Train loss on the assistant target tokens only; mask system/user tokens and padding. Verify the mask on inspected token IDs and a tiny pilot before a long run. Retain explicitly reviewed unchanged examples and public normalization replay. Record how the target is separated from paste-boundary formatting.

Start with LoRA rank 8 and alpha 16, dropout 0.05, learning-rate candidates `2e-5` and `1e-4`, microbatch 1, accumulation 16, BF16 when the installed stack supports it, gradient checkpointing, and at most three epochs. Name the exact target modules after inspecting the pinned model; do not assume another architecture's projection names. Begin with a 512-token training length; use 1,024 only after the memory pilot. Do not truncate away the assistant target: route overlength examples to a reviewed longer bucket or exclude them with counts. Inference still follows the app's independent input/output limits.

S1 naming/notice obligations remain in force. A larger DOSE1/LFM experiment must first establish the base artifact and permitted training use. See [THIRD_PARTY.md](../THIRD_PARTY.md) and the model research sources.

## 7. Measure the pilot before budgeting training

On the CPU, time parse/validation, feature extraction, tokenization, and an entire calibrator fit separately. Use a representative train subset, including the longest examples. Record cache state, row count, elapsed time and peak memory. Do not attribute repeated JSON parsing or tokenization time to GPU training.

On the RTX 5080, record `nvidia-smi`, Python, PyTorch, CUDA/runtime, driver and dependency versions. Verify the installed build actually executes forward/backward/optimizer steps on the device. Host RAM does not increase the GPU's VRAM. Do not launch a full fine-tune based on a model's weight size alone.

For each neural recipe, measure 20 warmup optimizer steps and 100–200 subsequent representative optimizer steps, including gradient accumulation. Include a long-input batch, validation pass and checkpoint write. Record peak allocated/reserved VRAM, actual examples/tokens, non-finite gradients, step-time median and range, data-loader wait, and checkpoint size. Lower microbatch or sequence length if memory is insufficient; record the change and rerun the pilot.

Use measured optimizer-step time to estimate remaining work:

```text
steps_per_epoch = ceil(actual_training_examples / effective_batch_size)
remaining_time ≈ remaining_optimizer_steps × measured_seconds_per_optimizer_step
                 + scheduled_validation_time + checkpoint_write_time
```

Adjust for the trainer's handling of incomplete batches and accumulation. Use measured high/low step times for a range. Record both elapsed and estimated times; an estimate is not a benchmark. Repeat the pilot when model size, context length, precision, batch policy or public replay mixture changes.

## 8. Save enough information to reproduce a result

Each experiment directory needs an immutable manifest with:

- git revision/source digest; dirty patch digest if applicable; trainer and feature-builder versions;
- source snapshot, observation, reviewed-label, train/valid/test and split-lock hashes;
- public corpus/license identifiers, sampling/augmentation rules and family lineage;
- model, tokenizer, vocabulary, confusion-list, prompt, template and configuration hashes;
- all hyperparameters, seeds, environment/hardware details and pilot measurements;
- optimizer/scheduler/RNG state, global step and base-model digest for resumable checkpoints;
- native converted artifact hashes, evaluation prediction hashes, results and approved baseline identity.

Write checkpoints to a temporary path and publish only after the complete manifest and hashes exist. Resume only when training data, feature schema, architecture and base weights match; otherwise start a new experiment. Keep `best-valid` separate from `last`, and never choose a checkpoint by final-test performance. Retain the previous approved artifact and its exact configuration.

## 9. Metrics that distinguish useful correction from harm

| Metric | Definition |
|---|---|
| Candidate recall | Reviewed erroneous eligible spans whose acceptable answer appears in the candidate set / reviewed erroneous eligible spans |
| KEEP preservation | Reviewed original-correct opportunities kept correct / reviewed original-correct opportunities |
| Harmful-edit rate | New wrong edits / independently reviewed original-correct opportunities; report per 1,000 and the raw numerator/denominator |
| Correction precision | Applied acceptable corrections / all applied corrections; wrong substitutions and changes to already-correct words are errors |
| Correction recall | Corrected reviewed error spans / all reviewed error spans; absent candidates remain misses |
| Abstention | KEEP decisions on missing-answer/uncertain cases, reported separately from originally correct KEEP |
| Final correction effort | Token/character edits from full pipeline output to reviewed desired output, plus exact match |
| Operational behavior | p50/p95, cold/warm separately, memory, timeout, cancellation, rejection and fallback rates |

Do not call candidate-only KEEP performance an all-word false-positive rate. To report harm per 1,000 previously correct words, independently review those words and measure the complete pipeline, including words never sent to a scorer. The first-64 observation cap cannot supply that denominator.

Use paired comparisons on the same cases. Group uncertainty/resampling by recording/document family; variants are not independent trials. Inspect dictation versus typing, each scorer, clean text, names, numbers, negation, code, language mixing and length buckets. Report small slice counts without claiming statistical certainty. Zero observed harm in a tiny sample is not evidence of a very low true harm rate.

## 10. Replay, conversion and adoption gates

Existing standalone cleanup replay can compare a correctly configured local server:

```sh
python3 scripts/run_flow_candidate.py \
  --dataset-dir "$FLOW_TRAIN_ROOT/runs" --split valid \
  --endpoint http://127.0.0.1:8080/v1/chat/completions \
  --model local-cleanup --artifact "$FLOW_TRAIN_ROOT/artifacts/baseline.gguf" \
  --prompt "$FLOW_TRAIN_ROOT/cleanup-system.txt" \
  --runtime-id "EXACT-server-build; EXACT-quantization; M1-Max; EXACT-flags" \
  --out "$FLOW_TRAIN_ROOT/baseline.jsonl"

python3 scripts/flow_hillclimb.py \
  --dataset-dir "$FLOW_TRAIN_ROOT/runs" --split valid \
  --baseline "$FLOW_TRAIN_ROOT/baseline.jsonl" \
  --candidate "$FLOW_TRAIN_ROOT/candidate.jsonl" \
  --out "$FLOW_TRAIN_ROOT/candidate-report.json"
```

The first command requires an already-running server with the stated artifact; run it again for the candidate with its own artifact/configuration/output. For S1, explicitly provide the control-line prefix and supported template arguments as described in [TRAINING.md](TRAINING.md); a server ignoring `enable_thinking` is not an equivalent replay. HTTP timings measure the cleanup request, not key-release-to-paste time, and the endpoint cannot prove which artifact the process loaded.

The current comparison tool screens complete transcript predictions. It is not a candidate-ranker evaluator. Implement the candidate metrics above before claiming C0/R0 wins. The existing transcript gate requires enough independent cases, paired evidence, quality improvement, baseline-exact preservation, no detected critical failures, acceptable p95 and no measured slice regression. Its `eligibleForReview` result never installs anything. Automated number/literal/negation checks cannot prove semantic equivalence; review regression examples.

For S1, `scripts/fuse-convert-s1.sh MERGED_DIRECTORY UNIQUE_CANDIDATE_NAME` is the existing Mac conversion path after a merged checkpoint exists. It verifies the expected stock layout/template and writes notices and a local artifact receipt. Run its recipe verification and inspect its pinned prerequisites first. This document has not executed conversion or established that a candidate can be selected by the current native loader.

Before deployment, add an explicit candidate path/manifest selector to native S1 replay: verify weights, tokenizer, template and base identity, load that directory, and record the loaded artifact digest in receipts. Never replace the stock cache merely to make a comparison work. `CleanupReplayHarness` currently rejects non-stock `s1_variant`; that failure is an implementation gate to resolve, not a reason to label a stock run as the candidate.

A custom ranker needs its own frozen inference/export contract: tensor names/shapes, candidate order/mask, tokenizer/normalization, special tokens, byte encoding, context order, feature scaling/missingness and score semantics. Test reference versus exported versus Swift scores on invented and private held-out inputs. Compare argmax, threshold actions and full outputs, including cases near the threshold. Quantization must pass the same harmful-edit gates; a small average numeric error can still flip an important decision.

On the M1 Max, measure the actual pipeline with pinned dictionary/recognizer/guards, comparable warm/cold conditions and no concurrent competing model server. Keep timeouts and malformed responses in the denominator. Check memory pressure, cancellation, fallback to original text, model unavailability, boundary-aware paste, and exact protected-token handling. Run the Swift tests and private native replay before switching defaults.

Adopt only a reviewed candidate that passes both model and application gates. Preserve the baseline path/configuration and verify that selecting it restores the previous behavior. Start with shadow comparison that cannot alter user text; do not treat shadow output as new training truth. A later collected regression becomes a review item, and any training use places that family outside future untouched release evaluation.

## Next deliverables

1. Collect a representative private batch with the new word observations; confirm KEEP and alternatives appear for each intended scorer and quantify cap/skip coverage.
2. Implement candidate review binding and a feature builder using the contract above, with hash/span/lineage tests.
3. Train the CPU calibrator and compare it against the frozen rule policy. Use the result and candidate recall to decide whether a ranker or better candidates is the next useful investment.
4. Build the ranker trainer only after that evidence; prepare reviewed S1 data and a native candidate selector independently if sentence cleanup remains the larger problem.
5. Run measured hardware pilots, conversion parity, held-out/native replay, human review and a reversible release decision.

Collection makes these experiments possible. Only measured, reviewed experiments establish that the system has improved.
