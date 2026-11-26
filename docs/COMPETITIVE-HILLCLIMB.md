# Hillclimb toward a better personal dictation system

**Target:** Flow should produce more immediately usable dictations than Wispr Flow on Michael's real workload, while preserving meaning, recognizing personal vocabulary, inserting into the correct field, and meeting an explicit latency budget. This document defines how to measure that target. **There are no real Flow-versus-Canto-2 results in this repository.**

## What we are comparing

[Wispr introduced Canto-2 on 24 November 2026](https://wisprflow.ai/post/introducing-canto-2). It is Wispr's speech-recognition model inside Flow. Wispr reports 69% accuracy on hard dictionary terms and 92% on easy terms with a 1,000-term dictionary; those are vendor results on its own evaluation, not measurements of this project. Its [release notes](https://wisprflow.ai/whats-new) describe a regional rollout. Record the installed app/build and retained model-attribution evidence; an installed Wispr app alone does not establish that a session used Canto-2.

The competitive unit is the entire delivered dictation: recognition, dictionary handling, cleanup, insertion and recovery. `scripts/flow_competition.py` consumes locally supplied native captures under a frozen same-audio protocol. It does not operate either app, record the microphone, access a Canto API, download weights or upload data. Capture, configuration and review metadata are operator declarations, not device or server attestation. All committed fixtures use invented audio bytes and outputs.

Keep three experiments separate:

| Question | Tool and evidence |
|---|---|
| Did a cleanup/rule/model change improve independently reviewed text? | `flow_hillclimb.py`, frozen reviewed inputs/targets and complete candidate outputs |
| Did an engine setting make the same cleanup workload faster? | `flow_engine_tune.py`, repeated control/candidate/control runs, identical artifacts and observed output equivalence |
| Is native Flow better for these dictations than native Wispr? | `flow_competition.py`, identical audio/context/vocabulary, full insertion timing and blind output review |

An HTTP cleanup win cannot be reported as a product latency win. A text-only test cannot establish ASR accuracy. Exact target match is useful but does not replace a human judgment of whether the result is ready to send.

## Freeze useful personal coverage

Export a complete reviewed dataset with [TRAINING.md](TRAINING.md). The competition tool selects every `kind: dictation` case in the requested validation/test split. It keeps the full dataset identity, including the other split files, and rejects partial mappings. Review each reference against its actual recording before looking at the competing outputs. Targets must preserve what the speaker meant; copying Wispr's output or accepting Flow's untouched output is not independent ground truth.

Include these slices in the private audio map. They are an experiment-design checklist; the script does not invent missing coverage or guarantee a balanced sample:

| Slice | Measure and inspect |
|---|---|
| Personal names, projects and jargon | Annotate required spellings with `mustContain`; count missed or damaged terms |
| Common words near dictionary names | Annotate unspoken terms with `mustNotContain`; check false insertion separately from term recall |
| Large dictionary and overlapping names | Keep the same term list for both products, including prefix collisions and unrelated distractors |
| Numbers, dates, amounts and negation | Preserve values, signs, order, negation scope and corrected intent |
| Self-corrections and restarts | Keep the final intended value without dropping unrelated content |
| Code, filenames, URLs and email addresses | Preserve exact literals, casing and structure where required |
| Short and long speech; quiet and noisy audio | Include failures and long-tail delays, not only the easiest successful clips |
| Mid-field insertion, selections and existing words | Check both cursor boundaries, punctuation, spacing, selection replacement and target ownership |
| English, Dutch and mixed technical names | Report the supported workload explicitly; do not infer broad multilingual superiority |

Freeze dictionary and field-context files alongside each audio file. The context must specify the target app, existing field text, selection range, cursor position and editing mode. Include an explicit empty context/dictionary file when none applies. Use the same audio bytes and replay route for both products, not a second spoken take or a compressed/transcoded copy. Hashing a configuration file binds its contents; the operator must also apply those settings to the actual app.

Keep all private files outside the repository. Use validation for iteration. Freeze one candidate before opening the final test results, then confirm on a fresh chronological release set. New recordings that share audio or a known text family remain one independent family; repetitions do not count as new evidence.

## Freeze a native match

Create a private `protocol.json`. This is an **example policy**, not an observed performance result; replace the environment and choose budgets before collecting outputs:

```json
{
  "schemaVersion": 1,
  "measurement": "key-release-to-verified-insertion",
  "clock": "monotonic_ns",
  "clockSessionID": "REPLACE-with-one-capture-session-id",
  "order": "paired-alternating-rounds",
  "initialState": "ready",
  "repetitions": 3,
  "timeoutMs": 10000,
  "maxP95Ms": 2000,
  "environment": {
    "hardware": "REPLACE-with-exact-Mac-and-RAM",
    "os": "REPLACE-with-OS-build",
    "power": "REPLACE-with-power-source-and-profile",
    "targetApp": "REPLACE-with-editor",
    "targetAppVersion": "REPLACE-with-editor-build",
    "audioRoute": "REPLACE-with-fixed-same-file-replay-route",
    "network": "REPLACE-with-connection-and-observed-conditions"
  }
}
```

`initialState` is `ready` or `cold`. For a ready experiment, warm each product with separate unscored examples before the measured rounds; retain those observations with the experiment notes. For a cold experiment, restore the declared cold state before every measured attempt and include release-to-insertion behavior under that state. Compare cold and ready experiments separately. The protocol accepts 3–50 repetitions; three samples are pilot evidence, and a noisy or near-budget result needs a longer run.

Create `audio-map.jsonl`, with one row per selected case:

```json
{"id":"CASE_ID","caseHash":"CASE_SHA256","audioPath":"audio/recording.caf","contextPath":"context/case.json","vocabularyPath":"dictionary.json","slices":["personal-terms","mid-field"],"audioReview":{"source":"audio-human-reviewed","reviewerID":"REVIEWER_ID","reviewedAt":"2026-11-26T12:00:00+01:00","audioSHA256":"ACTUAL_AUDIO_SHA256","caseHash":"CASE_SHA256","targetMatchesAudio":true,"independentOfSystems":true}}
```

Paths are relative to the audio-map file, or absolute. `caseHash` comes from the reviewed export; compute `audioSHA256` from the exact bytes the reviewer listened to. The freezer hashes all three local files, rejects changes during reading, verifies the review binding, and writes a `matchID` covering the cases, dataset, protocol, files and slices. It never copies audio or transcript text into the match. Slice labels are stored in the private match, so use category labels rather than dictation excerpts.

```sh
FLOW_MATCH="$HOME/flow-train/native-comparison"
python3 scripts/flow_competition.py freeze \
  --dataset-dir "$HOME/flow-train/runs" --split valid \
  --audio-map "$FLOW_MATCH/audio-map.jsonl" \
  --protocol "$FLOW_MATCH/protocol.json" \
  --out "$FLOW_MATCH/match.json"
```

## Capture complete attempts and review blind

Collect both products in the same monotonic clock session. Cases are ordered by case ID. In round zero, capture Wispr then Flow for each case; in round one, Flow then Wispr; continue alternating by round. Wait for an attempt to complete or time out before the next. The tool checks event order and rejects overlapping or reordered release/completion intervals. Retain the full capture trace so the events and settings can be audited.

Each product's JSONL file contains one row per case with these fields:

| Field | Required content |
|---|---|
| `id`, `matchID`, `caseHash` | Exact frozen case and match identity |
| `audioSHA256`, `contextSHA256`, `vocabularySHA256` | Exact values from the frozen match |
| `systemID`, `protocolID` | Canonical identity digest and frozen protocol digest |
| `attempts` | Every measured repetition, in sample-index order |

Every attempt retains `sampleIndex`, actual `output`, `outputSHA256`, integer `keyReleasedNs` and `completedNs`, derived `elapsedMs`, `outcome` (`inserted`, `failed` or `timeout`) and boolean `insertionVerified`. Verified insertion requires readback of the intended change in the intended field; a clipboard update or a dispatched paste event is insufficient. A failed attempt still retains any produced output and measured elapsed time. Timeout attempts cannot report a duration shorter than their declared deadline. Never replace a failure with a retry, fastest sample, empty success or zero latency.

For each attempt, a reviewer who cannot see the product identity judges the recording, target field context and delivered result. Bind optional `humanReview` to:

```json
{"source":"blind-human","blindToSystem":true,"reviewerID":"REVIEWER_ID","reviewedAt":"2026-11-26T13:00:00+01:00","matchID":"MATCH_SHA256","caseHash":"CASE_SHA256","outputSHA256":"EXACT_OUTPUT_SHA256","readyToSend":true,"meaningPreserved":true}
```

`readyToSend` includes spacing, punctuation, casing and insertion correctness; `meaningPreserved` includes relationships, negation scope and intent beyond lexical checks. Missing review produces descriptive metrics only. The tool can verify binding and completeness, not whether an operator genuinely blinded the review.

Each capture file needs a companion `<file>.manifest.json`. Required fields are `schemaVersion: 1`, `capturesSHA256` of the exact JSONL bytes, `identity`, `systemID`, `matchID`, `protocolID`, `environmentID`, `clockSessionID`, `captureType: native-dictation`, `retainedAllAttempts: true`, `cases`, `attempts`, and timezone-aware `startedAt`/`completedAt`. `identity` contains `product` (`wispr` or `flow`), exact `version`, `build`, `collectorID`, and a nonempty `configuration` object. Include Flow's commit and ASR/cleanup artifact hashes, prompts and relevant flags in its configuration. `systemID` is SHA-256 of the canonical identity; `environmentID` uses the frozen protocol's environment. Canonical JSON uses `export_flow_runs.canonical`.

An optional `modelName` is a declaration. To retain attribution evidence, add `identity.modelEvidenceSHA256` and a manifest `modelEvidencePath` relative to that manifest. The tool reads and checks that file, reporting **evidence-supplied**, never independently verified Canto-2. Keep screenshots/version records or provider confirmation alongside the private run. An unverified version can support a carefully labelled product comparison but cannot support a Canto-2-specific claim.

## Compare and choose the next change

```sh
python3 scripts/flow_competition.py compare \
  --dataset-dir "$HOME/flow-train/runs" \
  --match "$FLOW_MATCH/match.json" \
  --baseline "$FLOW_MATCH/wispr.jsonl" \
  --candidate "$FLOW_MATCH/flow.jsonl" \
  --out "$FLOW_MATCH/comparison.json"
```

The report contains identities, evaluator/dependency source hashes, counts, errors, review rates and timing aggregates without audio, transcript text or private local paths. It measures punctuation-sensitive **token-edit error**, not a conventional ASR WER leaderboard. Every retained attempt contributes to timing and quality. Required/forbidden literal failures distinguish missed personal terms and false insertions when annotated. Human review catches meaning and delivery failures that token metrics miss.

Eligibility requires at least 50 independent audio/text families, complete blind reviews for both products, at least 2% relative token-error improvement, a one-sided paired family sign-test at or below 0.05, no candidate critical failures, preservation of previous exact outputs and ready-to-send cases, preserved meaning, no declared-slice error regression, and candidate p95 within both the frozen absolute budget and 110% of Wispr's p95. The same latency limits now apply within every declared slice (`sliceP95WithinBudget`): a rare long-dictation or personal-term cohort cannot become much slower while remaining below the aggregate 95th percentile. This reuses the existing limits; it does not claim that small-slice estimates have high statistical precision. These are initial screening thresholds, not a confidence interval or proof of general superiority. The report always leaves `promoted: false` and `beatsCompetitor: false`. Exit status is zero for a successful freeze or eligible comparison, one for a valid comparison that does not qualify, and two for invalid evidence.

The verifier derives mandatory app/kind/protected-literal/reviewed-layout slices from the frozen reviewed cases. Rehashing a match does not permit dropping those slices, duplicating memberships, relabeling a slice hash, or adding unused definitions. Memberships are indexed once rather than rescanning every case for every slice. Strict JSON decoding refuses duplicate keys and non-finite numbers in evidence, protocols and manifests. Event timestamps must fit unsigned 64-bit nanoseconds, schema/workload counts must be integers rather than booleans, and both capture windows must admit one common mapping from their shared monotonic clock to UTC. Separate morning and evening capture windows therefore cannot claim to be alternating rounds merely by relabeling their monotonic events.

Use failures to select one intervention at a time:

1. If the correct word never reaches the candidate set, improve recognition/dictionary candidate recall first. Include ordinary-word negatives before increasing bias.
2. If the right candidate exists but selection is wrong, start with the acceptance calibrator in [CUSTOM-MODEL-EXPERIMENTS.md](CUSTOM-MODEL-EXPERIMENTS.md), then a small correction ranker with an explicit KEEP choice if justified.
3. If recognition is right but cleanup changes meaning or style, evaluate the separate sentence-cleanup fine-tune in [CUSTOM-MODEL-PLAN.md](CUSTOM-MODEL-PLAN.md). Training a full speech foundation model from scratch is not the first personal-data experiment.
4. If output is right but arrival is slow, profile loading, ASR, cleanup, rules and delivery separately, then follow [INFERENCE-OPTIMIZATION.md](INFERENCE-OPTIMIZATION.md).
5. If the result is correct in a file but wrong at the cursor, add a native editor regression and fix insertion/readback. Training weights will not fix field ownership.

Retain losing candidates and failure IDs as experiment evidence. Do not feed their outputs back as truth. Learn vocabulary from qualified corrections, review new labels, keep splits stable, compare on validation, and promote a frozen artifact only after the held-out and native checks. Collection becomes useful through this loop; collecting more unreviewed text alone does not make the model better.
