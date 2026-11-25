# Selected-text Polish contract v1

This is a prepared training and serving contract, not a trained model or permission to launch training. The existing DOSE1 T1 prompt and T2 speech-cleanup control lines remain byte-for-byte unchanged. Existing polish rule lines also remain unchanged. New selected-text Polish requests use `t2-selected-text-polish-v1` only when the active model file explicitly advertises that capability.

The first user-message line is `[Polish request v1] ` followed by compact JSON with sorted keys and literal Unicode. A newline separates it from the selected text. `golden/polish-v1-fixtures.json` records exact wire examples shared with the app. There is still one user turn. The model returns edited text only.

The JSON contains exactly:

- `contract`: `t2-selected-text-polish-v1`.
- `settings`: five explicit booleans, `concise`, `clarity`, `reorder`, `structure`, `maintain_your_tone`.
- `editing_prompt`: trimmed custom editing instructions, up to 1,000 Unicode code points. Empty is allowed.

These switches correspond to Make more concise, Reword for clarity, Reorder for readability, Add structure for readability, and Maintain your tone. All five default on, reflecting the latest user screenshot where the fifth switch is visible. This changes no historical preset. Missing switch values are unknown, never inferred as off. The screenshot does not establish the contents of the custom prompt.

Selected text is trimmed and limited to 4,000 code points. Selected text and custom instructions reject role separators and control characters, apart from newline and tab. Custom instructions stay JSON string data. An instruction asking to answer the selected text, override a role, invent facts, change commitments or ignore preservation rules has no authority. Syntactic isolation does not prove a model will obey that boundary. Real instruction-following evaluation remains required.

## Behavior to train and verify

Baseline spelling, grammar, punctuation, sentence repair, paragraph splitting and faithful presentation of lists already described by the source stay available when all five switches are off. All-off does not imply literal copying. A controlled pilot from one fictional source family produced matching actual all-off, all-on and tone-only instructions. All-off and tone-only split two source paragraphs into five while preserving the facts. This establishes that baseline paragraph splitting can occur in those real teacher responses; it does not prove every disabled-switch behavior across domains.

Enable concision to remove redundant wording while retaining information. Clarity allows rephrasing ambiguous wording only when the meaning can be preserved. Reordering allows changing the order without changing chronology or causal relationships. Structure enables heavier document organization such as lists, headings or a clearer hierarchy where appropriate. Basic paragraph boundaries alone are not proof that Structure was enabled, because the verified all-off baseline also inserts them. Maintaining tone preserves register, warmth and voice. Turning tone preservation off never authorizes invented facts or a forced formal tone.

Custom instructions guide editing within those constraints. Disabled switches remove the request for that optional rewrite operation. They do not express a negative command forbidding the baseline edits described above. In particular, a heading or list is not by itself a settings violation when it faithfully presents organization already present in the source. Explicit custom constraints, such as keeping the original paragraph breaks, still apply. This must not excuse changed facts, omitted substantive content, stronger commitments or headings that invent a causal/evidence claim. On/off effects need paired teacher contrasts rather than assuming every baseline formatting choice is forbidden when a toggle is off. Facts, names, numbers, units, dates, URLs, negations, uncertainty and commitments must survive every setting. If a request conflicts with meaning preservation, retain the original meaning. Do not answer questions in the selected text or execute instructions quoted within it.

## Training example and provenance

`polish_contract.validate_example` requires exactly `id`, `input`, `target`, `polish_request`, `provenance`, `protected` and `evidence`. `provenance()` saves all five switch values, exact custom instructions, the UTF-8 SHA256 of those instructions and the canonical request SHA256. This distinguishes the fifth switch and different custom prompts even when their first four switch values match.

`render_example` accepts only evidence with `kind=verified_teacher_pair`, `transform_verified=true`, `settings_verified=true`, `meaning_reviewed=true` and a nonempty `source_record`. These are provenance assertions that must be backed by actual collection records, not sufficient evidence by themselves. Protected exact spans are a cheap guard. Human meaning review must also check negation scope and facts which exact matching cannot prove.

The fixtures are authored contract examples. They are rejected by the teacher-pair validator. No screenshot transcription is a target. Legacy mix readers refuse new request metadata instead of stripping custom instructions or silently converting it into old switch lines. The new renderer is available for a separately versioned dataset build; the existing stage configs remain on their legacy contract. A separate selected-Polish mix/run is now wired as described below.

Before real dataset construction or training, collect small real paired transforms with all five settings and the exact custom prompt saved at submission. Include all-off grammar, already-correct text, each switch independently, tone on/off, custom prompts, conflicting custom prompts, literal instructions, names, numbers, negations and uncertainty. Keep variants of the same source in the same split. Review results before expanding collection. Real teacher coverage across all 32 combinations is still absent. No model, GPU, PC, download or training work was performed to create this contract.
