# Decision models and gates

Flow runs several small checks between recognition and paste. Each one decides whether a model's output may replace what was said, and each one falls back to the earlier text when it is unsure. This file lists every gate, its threshold, what happens on failure, and why it exists. Thresholds are taken from the code at the time of writing. Check the cited file before changing one, because several were tuned against private dictation data that is not in this repository.

Every check is deterministic or a small local model. None of them sends text anywhere.

## Summary

| Gate | File | Decides | Threshold | On failure |
|---|---|---|---|---|
| Content guard | `WhisperNowContentGuard.swift` | Whether a cleanup output kept the literal content | Coverage 0.5 | Source text is kept |
| Meaning integrity | `MeaningIntegrity.swift` | Whether negations and quantities are unchanged | Exact match of counts | Input is kept |
| Paste safety | `PasteSafety.swift` | Whether a cleanup output is safe to paste | Score 0.35 | Falls back |
| Dictation referee | `DictationReferee.swift` | Records a probability and reason for each check | Per judge | Explains; does not decide alone |
| Draft meaning check | `DraftDecisionGate.swift`, `DraftDecisionModel.swift` | Whether an edit changed the meaning | 150 ms wait | Normal guards decide |
| Real-word fixer | `RealWordFixer.swift` | Homophone swaps | Margin 5 | Word is kept |
| Low-confidence recheck | `LowConfidenceRecheck.swift` | Replacement for words the recogniser doubted | Confidence below 0.6; margin 10 nats | Text unchanged |
| Opt+1 referee | `OptOneReferee.swift` | Which model edits to keep for a polish | Word-group rules | Reverted to typed words |
| Paste readback | `PasteReadback.swift` | Whether the paste landed | Two reads | Unknown never pastes twice |
| Speaker clustering | `SpeakerDiarizer.swift` | Whether two voices are the same speaker | Distance 0.62 | Separate speakers |

## The content guard

`WhisperNowContentGuard.trip(source:output:)` returns the first failed check, or nil. It rejects output that:

- is empty;
- changes or drops a number, link, name or negation;
- changes the language of a sentence;
- keeps less than half of the content words in any sentence (`coverageThreshold = 0.5`).

`WhisperNowContentGuard.shortened` rejects output that is much shorter than its source, and `Qwen3Polisher.reviewIdentifiersPreserved` rejects output that alters identifiers such as paths and file names.

**Why.** A small cleanup model can silently drop a number, invert a negation or rewrite a name, and the user would only notice after pasting. The guard makes those failures visible and falls back to the transcript instead of trusting the model.

## Meaning integrity

`MeaningIntegrity.preservesMeaning(original:candidate:)` requires the same count of negations and the same quantities in both texts. A second check handles spoken corrections ("the 14th, no, sorry, the 15th"). In that case a retracted negation or quantity may disappear, but nothing new may be added.

**Why.** These checks are narrow on purpose. They do not try to prove semantic equivalence, so anything uncertain falls back to the input.

## Paste safety

`PasteSafety` combines a small logistic score over the content guard's measurements: how much content each sentence kept, how much the output dropped or added, its length against the source, and how much of the source was filler. An output counts as safe when it is no further from the reference than the guard's fallback and keeps every number, negation and link that fallback keeps. The threshold is `0.35`.

The score does not overrule the coverage rule. It is recorded in the trace so the threshold can be tuned later.

## Dictation referee

`DictationReferee` runs five judges and records each result with a short reason. Reasons never include transcript text.

| Judge | Looks at | Can do |
|---|---|---|
| language | Share of words in clearly English sentences | Skip English-only fixes |
| contentGuard | Transcript against cleanup output | Fall back |
| pasteSafety | Transcript against cleanup output | Fall back |
| finalPass | Text after the rule pass | Remove fillers |
| realWords | Each homophone swap | Fix homophones |

**Why.** The referee makes the decisions explainable. A dictation's record shows which judge acted and why.

## Draft meaning check

`DraftDecisionGate` asks the local `DraftDecisionModel` (a small optional process) whether an edit kept the meaning. It waits at most 150 ms (`timeout`). Only one request is in flight, and no draft is queued. The check is on by default (`voice.draftDecisionModelEnabled`) and is off in privacy mode. Capture start warms the worker on every recording path, and a long recording refreshes its idle timer. For sectioned dictations, one guarded section is reviewed while the next is cleaned; the final non-sectioned review uses the same word-scaled deadline as cleanup.

**Why.** It is a second opinion for edits that have already passed the guards. It has a strict deadline within the shared cleanup budget; its latency benefit or cost must be measured on the actual device.

## Real-word fixer

`RealWordFixer` is a Swift port of the tinyfix model. It swaps a word only when the words on both sides make the intended word clear, and a swap needs the score margin to reach `5` (units as coded in `RealWordFixer.swift`). Dictation uses only spelling homophones (their/there/they're, your/you're, its/it's, then/than and similar). Acoustic pairs such as to/too/two, buy/by and sale/sell are left as heard, because the recogniser chooses between sound-alike words from the audio.

**Why.** The source comment records that, on the maintainer's dictations, the model was wrong more often than right on acoustic pairs. Spelling homophones are different: the written form is the only thing that can be wrong.

## Low-confidence recheck

`LowConfidenceRecheck` looks only at words the recogniser flagged with confidence below 0.6. For each one it lists near-word alternatives from the lexicon, scores each in its spoken context with tinynext, and swaps only when an alternative beats the written word by at least 10 nats. Names, capitalised mid-sentence words, acronyms, URLs, code, Flow's own dictionary and non-English sentences are never touched. Without the lexicon or the model, the text is returned unchanged.

**Why.** Recognition errors on uncommon words are common, but a wrong swap in a name or a term is worse than a visible error. The margin keeps the swaps conservative.

## Opt+1 referee

`OptOneReferee` aligns the model's edit with the typed text, group by group, so that splits and joins line up ("figu rei tout" against "Figure it out"). Spelling, casing, apostrophes and split or joined words are accepted. A changed number, link, name or negation, an added or dropped word, or a reworded phrase is reverted to what was typed, and each revert carries a reason. The deterministic repair then finishes what the model left.

**Why.** A polish should fix the text, not change its meaning. Judging each group keeps a good edit from being thrown away because of one bad word.

## Paste readback

`PasteReadback` compares the field before and after the paste and returns one of three verdicts:

- `verified`: the field holds exactly the intended edit and the caret sits after it;
- `notLanded`: the field and caret are exactly as before, both were readable, and the target is the same element;
- `unknown`: anything else.

A late readable miss keeps the recovery path available even if the first read was inconclusive. Flow can retry by typing only after both reads show that the paste failed and the target supports typed fallback.

The baseline field, selected range and post-paste caret must all be valid UTF-16 boundaries. A malformed range is unknown even when the visible field did not change. The paster also rechecks the target, field and caret immediately before typed fallback. A dispatch receipt is delivery metadata; only a verified readback establishes an insertion that correction learning may observe. Verification does not approve the wording for training.

## Speaker clustering

`SpeakerDiarizer` groups speech turns by voice embedding. Its clustering cut-off is `0.62` (`clusteringThreshold`, `SpeakerDiarizer.swift`).

## Order and fallbacks

Some gates decide, and others only explain. In the dictation path, the content guard decides per section, the referee records, and the paste readback decides whether a second paste is safe. If every cleanup step fails, the formatted transcript is pasted (see the deadlines table in [ARCHITECTURE.md](ARCHITECTURE.md)).

## What these gates are not

They are not a general quality metric. They catch specific, costly failures: lost numbers, flipped negations, invented names, lost text, and pastes that did not land. Output quality is measured separately, and the evaluation scripts are described in [TRAINING.md](TRAINING.md).

### D1 availability and scheduling

D1 installations are rechecked after a short backoff. Flow accepts the legacy candidate layout or `~/Library/Application Support/Voice/Models/D1/venv/bin/python` with the `d1-2B-mlx8bit` checkpoint directory next to `venv`. The network sandbox is unchanged. A ready, idle D1 may reserve 150 ms from the existing cleanup budget when at least 600 ms remains. Run records distinguish actual decisions from busy, cold, unavailable, invalid, timed-out, cancelled and skipped checks.

### Correction ownership across judges

Accepted TinyFix and sound-alike edits lock their exact UTF-16 occurrences, not every occurrence of the replacement word. Locks move when a later edit changes an earlier word's length. The low-confidence recheck respects those locks and the same dictionary terms; invalid, stale, overlapping and non-finite candidate edits never reach the final text. Completed run records ignore late asynchronous callbacks.

### Candidate evidence and inference bounds

TinyFix and TinyNext-based judges can record bounded original-first candidate lists, raw scores, rule features, margins and actual thresholds in `WordDecisionEvidence`. KEEP decisions are retained as observations alongside applied edits. These are not probabilities or independent labels; the legacy TinyFix `probability` field is an upstream heuristic, not calibrated confidence for Flow speech. Training requires separate review, as specified in [CUSTOM-MODEL-EXPERIMENTS.md](CUSTOM-MODEL-EXPERIMENTS.md).

TinyNext deduplicates contexts using exact UTF-8 bytes, preserving candidate order and byte-distinct Unicode. Missing/nonfinite scores, cancellation, token overflow and pathological token pieces make a context unscorable, so its original stays unchanged. Sound-alike and low-confidence passes reuse language classification within a sentence and validate window settings before slicing. Their acceptance thresholds are unchanged.
