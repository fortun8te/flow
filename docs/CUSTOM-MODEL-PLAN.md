# A custom correction model for Flow

Research checked **26 November 2026**. This is an implementation and experiment plan, not a trained model or a claim of measured improvement. Training estimates below assume a local **RTX 5080 with 16 GB VRAM**; deployment measurements must be taken on the **M1 Max with 32 GB memory**.

For the staged implementation, exact observation/label contract, experiment configurations, commands, hardware pilots and release gates, follow [CUSTOM-MODEL-EXPERIMENTS.md](CUSTOM-MODEL-EXPERIMENTS.md). This research explains the model choice; that runbook is the working plan to execute it.

## Recommendation

Build a small **candidate ranker that understands speech-recognition errors**, with an explicit option to leave the word alone. Keep sentence cleanup as a separate task. First calibrate the existing scorers on reviewed Flow examples; then compare a custom 2–5M parameter ranker against them. Fine-tune the existing S1-mini or DOSE1 cleanup route separately if sentence-level errors dominate.

This gives Flow its own learned correction policy without making every word pass through another generative model. A model becomes useful when it reduces corrections the user has to make, while preserving words that were already right. Owning the weights alone does not establish that.

## What the current models actually do

| Component | Verified role | Consequence for a replacement |
|---|---|---|
| TinyFix | A 1.9M parameter pair of GRUs scores candidate words using 16 words before and four after. Its vocabulary contains 20,000 words. [1] | Replace it with a candidate scorer, preserving exact spans and the `KEEP` option. It is not the sentence cleanup model. |
| TinyNext v2 | A 12.5M parameter transformer, 512-token context, 8K byte-level tokenizer. Upstream uses it for autocomplete; Flow uses sentence likelihood to rank alternatives. [2] | A specialist ranker could score alternatives directly instead of computing a full vocabulary distribution for every token. This is an architectural hypothesis to benchmark. |
| S1-mini | A 596M parameter Qwen3-derived English ASR normalizer. It expects a specific system prompt and control line, with thinking disabled. [3] | Suitable for punctuation, disfluencies, self-corrections and formatting. It is much larger than the word scorers. |
| DOSE1 / WhisperNow | Flow's separate sentence cleanup route; private DOSE1 weights are not in this repository. Public WhisperNow LFM3 is a 1.7B fine-tune. [4] | Useful comparison or personalization base for whole-transcript cleanup, not a tiny replacement for TinyFix. |

Relevant implementation: `RealWordFixer.swift`, `TinyNextScorer.swift`, `SoundAlikeCheck.swift`, `LowConfidenceRecheck.swift`, `S1MiniPolisher.swift`, `WhisperNowTunedPolisher.swift` and `TypoFixModel.swift` under `Sources/Voice/Services/`. In particular, `TypoFixModel` is the selected-text generative editor, despite its similar name.

TinyFix's author identifies candidate coverage and vocabulary as major remaining limits. Larger embeddings, BERT distillation and several other changes did not improve its benchmark beyond run variation. Its reported precision is measured on its own typing benchmark, not Flow dictations. [1] Measure how often the intended word is even proposed before spending compute on a bigger scorer.

## Three realistic ways to make it ours

### 1. Learn when existing corrections should be applied

Train a logistic model or small MLP on features already available or inexpensive to capture: score margin, alternative rank, ASR confidence, acoustic evidence when available, phonetic distance, whether the word is protected, nearby unknown words, input mode and dictionary evidence. Predict whether the best alternative should replace the original.

Use separate dictation and typing calibration. Keyboard distance is useful for typing and weak evidence for speech. A language model's preferred sentence is also weak evidence that the recognizer heard the wrong word.

This first model retains TinyFix/TinyNext as features. It is the cheapest way to discover whether most errors come from the acceptance policy rather than the language representation. Treat missing confidence as missing, not zero. Do not translate a scorer's margin into a claimed probability until calibration is measured on Flow validation data.

### 2. Train a dedicated 2–5M parameter ranker

Proposed first architecture: two compact context encoders plus a candidate encoder and small feature head. Keep the original word as candidate zero; add up to eight supported alternatives. A byte/character candidate encoder can represent uncommon spellings without assigning every unfamiliar term the same unknown-word embedding. Compare this against a word-only baseline before adopting it.

The output is one score per candidate. It cannot invent a sentence or edit outside the supplied span. Training examples include correctly recognized words, actual reviewed errors, deliberately difficult alternatives, and cases where the answer is absent from the candidate list. The last category must teach `KEEP` or abstention.

For general language coverage, train on licensed public text with synthetic confusions, then adapt on Flow corrections with a retained public replay mixture. A few thousand personal examples can specialize an existing representation; they do not replace broad language training from random weights. Start with a small public-data run to verify the pipeline, then increase data only when validation benefits.

Use the same candidates for a scorer-only comparison. Separately test an expanded candidate generator using phonetic confusions and reviewed dictionary entries. Otherwise a candidate-generation improvement can be mistaken for a better neural model.

A 10–30M subword encoder is a later experiment if vocabulary and context remain the limiting factors. It requires a new runtime/export path. The 2–5M design has a smaller integration and latency burden.

### 3. Personalize sentence cleanup

Compare S1-mini LoRA against the currently installed DOSE1 and the unmodified S1 baseline on identical reviewed examples. Use supervised fine-tuning with loss on target text, preserve the model's input contract, retain good unchanged examples, and stop on held-out quality rather than training loss. LoRA trains a small set of added parameters while freezing the base; adapters can be merged before deployment. [5]

For S1, begin with rank 8 or 16, short batches, gradient checkpointing as needed, 512–1,024-token examples, and a small learning-rate sweep rather than assuming one recipe wins. These are starting hypotheses, not tuned settings. Compare a 1.7B LoRA only if its quality advantage justifies its measured end-to-end latency.

S1's licence includes an explicit naming requirement for derivatives and integrations. A personalized build must continue identifying **S1-mini by Superwhisper**. [6] A separate Flow-branded model trained from Qwen3-0.6B-Base is another route, but requires learning the normalization behavior instead of inheriting it. The base is published under Apache-2.0. [7]

SmolLM2-135M is a useful larger context-scorer baseline: open weights, Apache-2.0, established transformer tooling. It is over ten times TinyNext's parameter count and should earn that cost on Flow's task. Its general benchmarks cannot establish correction quality. [8]

## How difficult and expensive is training?

The following are **planning ranges**, not device benchmarks or guaranteed data requirements. They exclude gathering and reviewing labels, downloading public corpora, conversion and full replay evaluation.

| Experiment | Initial reviewed data target | Compute planning range | Practical difficulty |
|---|---|---|---|
| Calibrator over current scores | 500–2,000 diverse decisions, with both harmful edits and safe `KEEP` cases | Seconds to minutes on CPU | Low training cost; reliable labels are the main work |
| Personal 2–5M ranker | 2,000–10,000 reviewed decisions plus substantially more unchanged/synthetic examples and broad public replay | Roughly 30 minutes–6 hours per initial GPU experiment | Moderate: dataset construction, candidate coverage and native export need engineering |
| S1-mini LoRA | 2,000–10,000 reviewed transcript/target pairs, plus a retained public mixture | Roughly 20 minutes–3 hours per initial GPU experiment | Moderate; existing Flow inference and conversion paths reduce integration work |
| 1.7B cleanup LoRA | The same frozen comparison data | Roughly 1–6 hours per initial GPU experiment | More activation memory and deployment latency to measure |

These sizes are plausible on 16 GB with suitable batches; that does not guarantee a particular library/kernel combination will work. Before a long run, verify CUDA support, execute 100–200 representative optimizer steps, record peak VRAM and examples/second, and estimate the remainder from measured throughput. CPU preprocessing may dominate a tiny model's training time. Local compute needs no rental charge; electricity and human review remain costs.

Useful published scale references, all **author-reported on different GPUs**:

- TinyFix: approximately 1 hour 45 minutes on one A10G. [1]
- TinyNext v2: 56 minutes on one A100 for 3 billion tokens. [2]
- Public WhisperNow LFM3: a full fine-tune of 60,836 rows for three epochs took 105 minutes on an H100 80 GB. This is not a 16 GB full-training recipe. [4]

A tiny specialist trained from scratch is realistic. Pretraining a broadly capable 0.6B–1.7B language model from scratch is a different project; start from released base weights for sentence cleanup.

## Data that supports improvement

Keep recognition, cleanup, insertion and user feedback distinct. A successful paste proves delivery; a field containing the pasted text does not prove the language was correct. No undo is not an explicit positive label. Undo indicates dissatisfaction, but does not establish that the entire raw ASR transcript is the desired answer.

For reviewed correction examples retain: source run ID, original text span and offsets, candidate list, scores, ASR confidence, accepted candidate, exact inserted span, subsequent corrected span, feedback provenance, model/checkpoint identity, relevant settings and latency. A correction label must refer to the inserted span, not unrelated text elsewhere in the field. Audio retention and collection must continue respecting existing privacy settings.

Split by originating recording/document and duplicate group before generating synthetic variants or stage examples. Keep a fixed regression set and a fresh chronological holdout. Put all near-duplicates and descendants of one source on the same side. Tune on development data only; repeated searches on the final test set turn it into development data.

Start with independently reviewed edits and explicitly checked unchanged examples. Teacher-generated targets are proposals for review, not ground truth. Keep public-data provenance and licences, and keep imported third-party reference output outside training unless its permitted use has been established.

## Experiments and promotion

Run paired replays of the current baseline, no word scorer, calibrated existing scorers and the custom ranker. Keep the recognizer, dictionaries, formatter and workload identical. Measure candidate recall first, then correction precision/recall and **new wrong edits per 1,000 previously correct words**. Also measure user correction distance, protected-token/number/negation changes, timeout/fallback rates and p50/p95 time from key release to verified insertion.

Use separate slices for dictation, typed text, names, code, numbers, homophones, language mixing, very short text and long input. A single combined score can hide a serious regression. For changes affecting spacing and cursor behavior, include insertion correctness independently of model quality.

Suggested initial acceptance policy: no new protected-content failures in the fixed suite, no worsening in paired harmful-edit counts, a meaningful reduction in correction effort, and p95 latency within the predeclared budget. Require sufficient coverage and confidence intervals; zero observed errors in a small sample is not proof of safety. As a rough statistical check, zero errors in N independent opportunities gives an approximately 3/N upper 95% bound, so a claim below one harmful edit per 10,000 opportunities needs about 30,000 clean opportunities, not 200 sentences. Real examples are correlated, so also inspect uncertainty grouped by recording.

Keep a versioned experiment manifest with code revision, dataset/split hashes, model/tokenizer hashes, settings, results and the previous approved artifact. Test the converted/quantized artifact through the actual Swift pipeline; Python scores alone are insufficient. Preserve the previous artifact and use a bounded shadow period before adopting a candidate. Promote only when the declared gates pass. Losing candidates remain useful failure examples, not new training truth.

## What still needs implementation and hardware validation

The repository has run logging, dataset builders, replay tooling and several model routes. It does not currently include a trained custom ranker, a portable CUDA trainer for it, its tokenizer/export contract, or a verified native benchmark for these proposed models. The private training recordings and installed DOSE1 artifacts are not available in this checkout. This research has not trained or swapped any model.

Candidate collection now has a concrete first step: `WordDecisionEvidence.swift` and `FlowRunLog.swift` retain bounded, validated candidate observations from TinyFix, sound-alike and low-confidence checks, including decisions to keep the original. The records include exact source spans, context, alternatives, scores, rule features and thresholds. They remain observations; the model's selected index is never a gold label. Independent candidate review, feature preparation and the trainer are still required. The runbook describes these remaining interfaces.

TinyNext v2 publishes float32 safetensors, tokenizer and training/export scripts. [9] TinyFix publishes its current quantized model and training script, but the root file listing does not include a matching full-precision training checkpoint. Separate `letters-v2`/`letters-v3` experiments include PyTorch files; they are not established drop-in replacements. [10] The upstream TinyFix training script also has a hard-coded remote corpus cache and upload calls. Localize its data/checkpoint handling before using private Flow examples. [11]

Prioritize the calibrator and candidate-recall report first. They determine whether the next useful experiment is better candidates, a custom ranker, or a personalized sentence cleanup model.

## Sources

1. [TinyFix model card](https://huggingface.co/paperweight/tinyfix): architecture, training, limits and author evaluation.
2. [TinyNext model card](https://huggingface.co/paperweight/tinynext): v2 architecture and training; v1 is a different model.
3. [S1-mini model card](https://huggingface.co/superwhisper/s1-mini): task, size and input contract.
4. [WhisperNow LFM3 model card](https://huggingface.co/category271/whispernow-lfm3-1.7b): training recipe, hardware and limitations.
5. [Hugging Face PEFT LoRA documentation](https://huggingface.co/docs/peft/main/package_reference/lora): adapter training and merging.
6. [S1-mini licence](https://huggingface.co/superwhisper/s1-mini/blob/main/LICENSE): additional naming term.
7. [Qwen3-0.6B-Base](https://huggingface.co/Qwen/Qwen3-0.6B-Base): base architecture and licence.
8. [SmolLM2-135M](https://huggingface.co/HuggingFaceTB/SmolLM2-135M): pretrained alternative and model scope.
9. [TinyNext v2 files](https://huggingface.co/paperweight/tinynext/tree/main/v2): checkpoints and reproducibility scripts.
10. [TinyFix files](https://huggingface.co/paperweight/tinyfix/tree/main), [letters-v2](https://huggingface.co/paperweight/tinyfix/tree/main/letters-v2), [letters-v3](https://huggingface.co/paperweight/tinyfix/tree/main/letters-v3): available artifacts.
11. [TinyFix training source](https://huggingface.co/paperweight/tinyfix/blob/main/train_realword.py): training implementation and remote cache/upload behavior.
