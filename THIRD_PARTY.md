# Third-party components

Flow's own code is MIT licensed (see [LICENSE](LICENSE)). Everything below keeps its own licence. "Included" means the file or code is in this repository. "Not included" means you must obtain it yourself, and its licence applies when you do.

Licences marked *verify* were not confirmed against the upstream licence file in this export. Check the upstream source before you ship a build that contains the component.

## Swift packages (pinned in `Package.resolved`)

Licence names checked against the licence files in the resolved SwiftPM checkouts.

| Package | Version | Used for | Licence | Status |
|---|---|---|---|---|
| FluidAudio (FluidInference) | 0.18.3 | Speech recognition, diarization | Apache-2.0 | Dependency, fetched by SwiftPM |
| GRDB.swift | 6.29.3 | SQLite storage and FTS5 | MIT | Dependency |
| GzipSwift | 6.0.1 | Compression | MIT | Dependency (transitive) |
| KeychainAccess | 4.2.2 | Keychain access | MIT | Dependency |
| mlx-swift | 0.29.1 | Apple MLX runtime | MIT | Dependency (transitive) |
| mlx-swift-examples | 2.29.1 | MLXLLM, MLXLMCommon | MIT | Dependency |
| swift-collections | 1.5.0 | Data structures | Apache-2.0 | Dependency (transitive) |
| swift-jinja | 2.3.5 | Chat templates | Apache-2.0 | Dependency (transitive) |
| swift-numerics | 1.1.1 | Numerics | Apache-2.0 | Dependency (transitive) |
| swift-transformers | 1.0.0 | Hugging Face tokenisers and hub | Apache-2.0 | Dependency (transitive) |

FluidAudio also fetches the [NeMo Text Processing XCFramework v0.3.1](https://github.com/FluidInference/text-processing-rs/releases/tag/v0.3.1), an Apache-2.0 build dependency. The source repo does not contain the binary.

## Vendored in this repository

| Component | Path | Licence | Notes |
|---|---|---|---|
| TinyFix swap rules (port) and documentation | `Sources/Voice/Services/RealWordFixer.swift` | MIT (Caleb Fahlgren) | Attributed in the file header. Its licence text is `Sources/Voice/Resources/TinyFix/LICENSE.txt`. |
| tinynext tokenizer files (`tinynext-merges.txt`, `tinynext-vocab.txt`) | `Sources/Voice/Resources/TinyFix/` | MIT (Caleb Fahlgren) | Licence text in `tinynext-LICENSE.txt`. Vocabulary by token ID and merge order match the [MIT-licensed upstream tokenizer](https://huggingface.co/paperweight/tinynext/blob/0832c99ea70ead6c90fb86b09fcab91fd6ef6fdf/v2/tokenizer.json). |
| TinyFix vocabulary files (`wrong-word-vocab.txt`, `wrong-word-confusions.txt`) | `Sources/Voice/Resources/TinyFix/` | MIT | Both files match the [upstream TinyFix release](https://huggingface.co/paperweight/tinyfix/tree/5b1491e3e3a59ca75a51a952912ca1200b172d87). |
| `typo_dictionary.json` | `Sources/Voice/Resources/TinyFix/` | MIT | Three invented example pairs written for this export. |
| S1-mini model notices | `Sources/Voice/Resources/ModelNotices/S1-mini/` | Apache-2.0, plus an additional naming term | Keep both files with any distribution. The model is derived from Qwen3-0.6B. |
| Starter vocabulary and product spellings | `StarterDictionary.swift`, `ProperNounVocabulary.swift` | MIT | Short lists of public technical and product names selected for this export. |

## Not included (obtain separately)

| Component | Source | Licence | Why it is not here |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (Core ML) | [FluidInference conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), from [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC BY 4.0 | Downloaded at run time |
| Parakeet Ultra (Core ML) | FluidInference conversion of [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), derived from NVIDIA Parakeet TDT v3 | CC BY 4.0 for the base and pinned conversion | Downloaded at run time |
| Phonon 2 (Core ML) | [FluidInference conversion](https://huggingface.co/FluidInference/phonon-2-coreml) of Fermion Research's NVIDIA Parakeet TDT v3 derivative | CC BY 4.0 | Downloaded at run time |
| S1-mini 4-bit (MLX) | `mlx-community/S1-mini-MLX-4bit`, from Superwhisper | Apache-2.0 plus an additional naming term | Downloaded at run time. Keep the notice. |
| Qwen3 (MLX) | `mlx-community/Qwen3-*`, from [Qwen3](https://huggingface.co/Qwen/Qwen3-1.7B) | Apache-2.0 base model | Downloaded at run time |
| Granite 4.0 1B Speech (MLX) | [MLX conversion](https://huggingface.co/mlx-community/granite-4.0-1b-speech-5bit) of IBM Granite | Apache-2.0 | Downloaded at run time |
| Moonshine Tiny (MLX) | [Moonshine AI](https://huggingface.co/moonshine-ai/moonshine-tiny) and an optional MLX conversion | MIT for the upstream weights. Conversion licence still to verify. | Downloaded at run time |
| DOSE1 (WhisperNow LFM3 1.7B fine-tune, GGUF) | Not published here | Depends on the LiquidAI LFM3 base licence *verify* | Trained on private dictation; weights not distributed. Check the base licence before sharing any derivative. |
| TinyFix weights (`tinyfix.bin`) | paperweight/tinyfix on Hugging Face | MIT | Not included |
| tinynext v2 weights (`tinynext-v2.q8`) | paperweight/tinynext on Hugging Face | MIT | Not included |
| Word frequency list (`words.txt`) | Not included | Unclear. The typo repair notes say it comes from another project. | Licence not confirmed, so not vendored |
| `llama-server` (llama.cpp) | [llama.cpp releases](https://github.com/ggml-org/llama.cpp) | MIT | Not bundled by this repository. Flow looks for it on your system. |
| Fonts (ABC Diatype Trial, Tiempos Headline, Figtree) | Font vendors | ABC Diatype and Tiempos are commercial. Figtree is SIL OFL *verify* | Commercial fonts cannot be redistributed. Replace with licence-compatible fonts. |
| App artwork, sounds | Author | Not stated | Not included. Replace with your own assets. |
| Cloud APIs (Cerebras, Groq, Hyperbolic, NVIDIA) | Provider services | Provider terms | Opt-in. Each needs your own API key. |
## Optional Python tooling

These packages are installed separately. The links point to the packages whose licence metadata was checked. Wheel builds of NumPy and PyTorch list multiple licences for bundled code.

| Packages | Licence |
|---|---|
| [mlx](https://pypi.org/project/mlx/), [mlx-lm](https://pypi.org/project/mlx-lm/), [mlx-audio](https://pypi.org/project/mlx-audio/), [mlx-vlm](https://pypi.org/project/mlx-vlm/) | MIT |
| [datasets](https://pypi.org/project/datasets/), [transformers](https://pypi.org/project/transformers/), [peft](https://pypi.org/project/peft/), [huggingface-hub](https://pypi.org/project/huggingface-hub/), [safetensors](https://pypi.org/project/safetensors/), [sentencepiece](https://pypi.org/project/sentencepiece/) | Apache-2.0 |
| [librosa](https://pypi.org/project/librosa/) | ISC |
| [soundfile](https://pypi.org/project/soundfile/), [protobuf](https://pypi.org/project/protobuf/) | BSD-3-Clause |
| [NumPy](https://pypi.org/project/numpy/), [PyTorch](https://pypi.org/project/torch/) | See the licence expression and notices for the wheel you install |


## Attribution to other products

The FluidVoice review informed behavior changes independently implemented in FLOW. No FluidVoice source or assets were carried into this export.

The source mentions third-party products by name in identifiers, comments and dictionaries: for example Wispr Flow (an import format for dictation history), Superwhisper, and assorted model and service names. These are names only. No code from those products is included, and the names are not endorsement.
