# Contributing to Flow

Thank you for looking at Flow. It is a local-first dictation app, so contributions have to respect one rule above the rest: **no real speech, transcripts or personal data in the repository.**

## Before you start

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the pipeline and [docs/DECISION-MODELS.md](docs/DECISION-MODELS.md) for the checks that stop bad output.
2. Read [THIRD_PARTY.md](THIRD_PARTY.md). If your change adds a dependency, vendored file or model, add it there with its licence and source.

## Privacy rules

- **Never commit real dictation.** That includes run records (`~/Library/Application Support/VOICE/training/`), traces, databases, audio, and anything exported from them. The `.gitignore` covers the common cases, but check `git status` before every commit.
- **Test fixtures must be invented.** Write sentences that a person would never say, such as "the blue kettle is on the second shelf". Do not copy a sentence from your own notes, chats or messages, even if it is only a typo example.
- **No secrets.** API keys, tokens, signing identities and personal paths do not belong in code, tests or docs. Use placeholders such as `YOUR-SIGNING-IDENTITY`.
- **No personal names or addresses** in comments, examples or screenshots. Use `Jordan Example`, `sample.user@example.com` and `/Users/example` style placeholders.
- **Logs stay local.** Anything you add to the run records, traces or events must be checked against [docs/DATA.md](docs/DATA.md). Traces hold numbers and labels only; never add text to them.

## Building and testing

```sh
swift package resolve
swift build
swift test
```

Some tests need fixture files that this repository does not include. Those tests skip themselves when a fixture is missing, so a skipped test is not a failure. See [Training and evaluation](docs/TRAINING.md#running-the-tests) for the Python test commands.

Tests that touch the speech or cleanup models need the model files, which are downloaded on first use (see the README).

## Making a change

- Keep the guard-and-fallback rule: a new model output must be checked before it replaces the text, and a failure must fall back to the earlier text.
- Add a deadline to anything that calls a model during a dictation. The dictation must still paste when the model is slow.
- If you change a threshold, say in the pull request why the old value was wrong, and how you measured the new one using invented data.
- Update the documentation in `docs/` when you change a stage, threshold, data store or switch. Cite the file path.
- Keep each change focused. Mention any change to the privacy switches (`voice.privacyMode`, `flow.saveRunRecords`) explicitly.

## Adding a speech or cleanup model

1. Add an identifier to `SpeechModelCatalog.swift` (speech) or a route to `Qwen3Polisher.effectiveAutomaticCleanupModel` (cleanup). Identifiers are persisted, so do not rename existing ones.
2. Pin the model's repository and revision in `Sources/Voice/Resources/ModelManifests/`.
3. Record its licence in [THIRD_PARTY.md](THIRD_PARTY.md). If the licence requires a notice, add it under `Sources/Voice/Resources/ModelNotices/`.
4. Document the route in [docs/ENGINE.md](docs/ENGINE.md).

## Style

- Swift: follow the style of the file you edit. Keep comments short and say why, not what.
- Python: standard library where possible. Give scripts a docstring that says what they read and write.
- Documentation: plain English, no invented features. Every claim should match the code.

## Licence

By contributing, you agree that your contribution is released under the MIT licence in [LICENSE](LICENSE).
