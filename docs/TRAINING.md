# Training and evaluation

This document describes the training, dataset and evaluation scripts in this repository, what each one needs, and what privacy rules apply. The scripts are not a turnkey pipeline. They expect data that you produce from your own dictation, and that data must stay private.

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

`scripts/export_flow_runs.py` turns run records (see [DATA.md](DATA.md)) into training pairs. Its output is private, and it defaults to a folder outside the repository.

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
```

The end-to-end polish replay uses the debug Flow executable. Some tests need optional fixtures or models and report a skip when those are absent.

## Hardware notes

The dataset builders and generators run on any machine with Python 3. Model training and evaluation with `mlx_lm` need Apple silicon. Some training was done on a separate CUDA machine. The scripts kept here do not depend on it.
