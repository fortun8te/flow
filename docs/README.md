# FLOW documentation

FLOW is the local-first macOS voice app in this repository. Start with the [project README](../README.md#quick-start) to build it.

| If you want to understand… | Read |
| --- | --- |
| What happens between recording speech and pasting text | [Architecture](ARCHITECTURE.md) |
| Which speech and cleanup models run, and what happens when a model is missing | [Engines and model setup](ENGINE.md) |
| How FLOW checks a rewrite before applying it | [Decision models](DECISION-MODELS.md) |
| What FLOW stores locally and how to control it | [Data and privacy](DATA.md) |
| How to run the evaluation tools with invented data | [Training and evaluation](TRAINING.md) |
| Which custom model to train, what data it needs, and how to compare it | [Custom model plan](CUSTOM-MODEL-PLAN.md) |
| How to collect candidate labels and run the first custom-model experiments | [Custom-model experiments](CUSTOM-MODEL-EXPERIMENTS.md) |
| How to measure and optimize cleanup inference without hiding failures | [Inference optimization](INFERENCE-OPTIMIZATION.md) |

For changes to the project, see [Contributing](../CONTRIBUTING.md). For dependency and model terms, see the [third-party notices](../THIRD_PARTY.md).
