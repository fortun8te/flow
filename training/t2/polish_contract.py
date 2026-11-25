"""Opt-in selected-text Polish contract. No change to T1 or speech cleanup prompts.

Custom instructions are user data for editing selected text. They cannot override
meaning preservation, switch constraints, output-only behavior or role boundaries.
This wire format needs matching T2 training and serving capability before use.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any

CONTRACT = "t2-selected-text-polish-v1"
PREFIX = "[Polish request v1] "
MAX_EDITING_PROMPT_CHARS = 1000
MAX_TEXT_CHARS = 4000
SETTING_KEYS = ("concise", "clarity", "reorder", "structure", "maintain_your_tone")
DEFAULT_SETTINGS = dict(zip(SETTING_KEYS, (True, True, True, True, True)))
SETTING_LABELS = dict(zip(SETTING_KEYS, (
    "Make more concise", "Reword for clarity", "Reorder for readability",
    "Add structure for readability", "Maintain your tone")))
# Prevent user text from becoming template structure on any registered base.
ROLE_MARKERS = ("<|", "|>", "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>")


def _safe_string(value: Any, limit: int, name: str, *, empty: bool) -> str:
    if not isinstance(value, str) or value != value.strip():
        raise ValueError(f"{name} must be a trimmed string")
    if len(value) > limit or (not empty and not value):
        raise ValueError(f"{name} length must be {'0' if empty else '1'}..{limit}")
    if any(ord(c) < 32 and c not in "\n\t" or ord(c) == 127 for c in value):
        raise ValueError(f"{name} contains a control character")
    if any(marker.lower() in value.lower() for marker in ROLE_MARKERS):
        raise ValueError(f"{name} contains a role separator")
    return value


def validate_request(request: dict) -> dict:
    if not isinstance(request, dict) or set(request) != {"contract", "settings", "editing_prompt"}:
        raise ValueError("Polish request needs exactly contract, settings and editing_prompt")
    if request["contract"] != CONTRACT:
        raise ValueError("unsupported Polish contract")
    settings = request["settings"]
    if not isinstance(settings, dict) or set(settings) != set(SETTING_KEYS):
        raise ValueError("Polish settings must explicitly include all five switches")
    if any(type(settings[k]) is not bool for k in SETTING_KEYS):
        raise ValueError("Polish switches must be booleans")
    prompt = _safe_string(request["editing_prompt"], MAX_EDITING_PROMPT_CHARS, "editing_prompt", empty=True)
    return {"contract": CONTRACT, "settings": {k: settings[k] for k in SETTING_KEYS}, "editing_prompt": prompt}


def make_request(settings: dict | None = None, editing_prompt: str = "") -> dict:
    return validate_request({"contract": CONTRACT, "settings": dict(DEFAULT_SETTINGS if settings is None else settings),
                             "editing_prompt": editing_prompt.strip()})


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def render(text: str, request: dict, *, supported_contract: str) -> str:
    if supported_contract != CONTRACT:
        raise ValueError("selected-text Polish requires an explicitly compatible T2 model")
    text = _safe_string(text.strip(), MAX_TEXT_CHARS, "selected text", empty=False)
    return PREFIX + canonical_json(validate_request(request)) + "\n" + text


def split(user: str) -> tuple[dict, str]:
    first, sep, text = user.partition("\n")
    if not first.startswith(PREFIX) or not sep:
        raise ValueError("missing versioned Polish envelope")
    request = validate_request(json.loads(first[len(PREFIX):]))
    if render(text, request, supported_contract=CONTRACT) != user:
        raise ValueError("noncanonical Polish content")
    return request, text


def provenance(request: dict) -> dict:
    request = validate_request(request)
    return {"contract": CONTRACT, "settings": dict(request["settings"]),
            "editing_prompt": request["editing_prompt"],
            "editing_prompt_sha256": hashlib.sha256(request["editing_prompt"].encode("utf-8")).hexdigest(),
            "request_sha256": hashlib.sha256(canonical_json(request).encode("utf-8")).hexdigest()}


SOURCE_SPLITS = {"train", "validation", "heldout"}


def _sha256_value(value: Any, field: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError(f"{field} must be a lowercase SHA256")
    return value


def source_partition_binding(source_record: str, source_record_sha256: str, source_family: str,
                             source_split: str, source_input_sha256: str) -> str:
    """Bind explicit reviewed partition metadata to its source row and exact input.

    The caller supplies the actual source-row hash after verifying the source.
    This digest detects changed metadata; it does not establish source authenticity
    or infer a seed family from a typo variant, record ID or input hash.
    """
    for field, value in (("source_record", source_record), ("source_family", source_family)):
        if not isinstance(value, str) or not value or value != value.strip():
            raise ValueError(f"{field} must be an explicit nonempty trimmed string")
    if not isinstance(source_split, str) or source_split not in SOURCE_SPLITS:
        raise ValueError("source_split must explicitly be train, validation or heldout")
    binding = {"source_record": source_record,
               "source_record_sha256": _sha256_value(source_record_sha256, "source_record_sha256"),
               "source_family": source_family, "source_split": source_split,
               "source_input_sha256": _sha256_value(source_input_sha256, "source_input_sha256")}
    return hashlib.sha256(canonical_json(binding).encode("utf-8")).hexdigest()


def resolve_source_partition(example: dict, registry: dict | None = None) -> tuple[str, str]:
    """Resolve only saved reviewed source metadata, never a generated family/split.

    Pass one shared registry across all input variants and settings variants.
    A source family is assigned exactly one pre-reserved partition. The source
    row's path/identifier and byte hash must be verified by admission separately;
    this source-only helper never reads or changes raw collection records.
    """
    if not isinstance(example, dict) or not isinstance(example.get("input"), str):
        raise ValueError("source partition requires an example with exact input text")
    evidence = example.get("evidence")
    if not isinstance(evidence, dict) or evidence.get("source_partition_reviewed") is not True:
        raise ValueError("source family and split require explicit reviewed source metadata")
    family, split = evidence.get("source_family"), evidence.get("source_split")
    input_sha = hashlib.sha256(example["input"].encode("utf-8")).hexdigest()
    if evidence.get("source_input_sha256") != input_sha:
        raise ValueError("source partition input hash differs from the exact reviewed input")
    expected = source_partition_binding(evidence.get("source_record"), evidence.get("source_record_sha256"),
                                        family, split, input_sha)
    if _sha256_value(evidence.get("source_binding_sha256"), "source_binding_sha256") != expected:
        raise ValueError("source family/split binding differs from the reviewed source record")
    if registry is not None:
        if not isinstance(registry, dict):
            raise ValueError("source family registry must be a dictionary")
        if family in registry and registry[family] != split:
            raise ValueError(f"source family {family!r} crosses reserved partitions")
        registry[family] = split
    return family, split


def validate_example(row: dict, *, require_teacher: bool = True) -> list[str]:
    """Validate a new-format pair, never infer switches/custom text from preview screenshots.

    Exact protected spans are an auditable minimum, not proof of semantic equivalence.
    Human review must cover all facts, uncertainty, commitments and negation scope.
    """
    errors = []
    required = {"id", "input", "target", "polish_request", "provenance", "protected", "evidence"}
    if not isinstance(row, dict) or set(row) != required:
        return ["example needs exactly " + ", ".join(sorted(required))]
    if not isinstance(row["id"], str) or not row["id"].strip():
        errors.append("id must be a nonempty string")
    if not isinstance(row["input"], str) or not isinstance(row["target"], str):
        return errors + ["input and target must be strings"]
    try:
        request = validate_request(row["polish_request"])
        render(row["input"], request, supported_contract=CONTRACT)
        _safe_string(row["target"], MAX_TEXT_CHARS, "target", empty=False)
        if row["provenance"] != provenance(request):
            errors.append("provenance must match all five switches and exact custom instructions")
    except (ValueError, TypeError, KeyError) as exc:
        errors.append(str(exc))
    if not isinstance(row["input"], str) or not isinstance(row["target"], str):
        return errors + ["input and target must be strings"]
    if not isinstance(row["protected"], list):
        errors.append("protected must be a list")
    else:
        for span in row["protected"]:
            if not isinstance(span, str) or not span or span not in row["input"] or span not in row["target"]:
                errors.append("protected span missing or changed")
    evidence = row["evidence"]
    if not isinstance(evidence, dict):
        errors.append("evidence must be an object")
    elif require_teacher and (evidence.get("kind") != "verified_teacher_pair" or
                             evidence.get("transform_verified") is not True or
                             evidence.get("settings_verified") is not True or
                             evidence.get("meaning_reviewed") is not True or
                             not isinstance(evidence.get("source_record"), str) or
                             not evidence.get("source_record", "").strip()):
        errors.append("requires a real verified transform, full settings and meaning review")
    if require_teacher:
        try:
            resolve_source_partition(row)
        except (ValueError, TypeError) as exc:
            errors.append(str(exc))
    return errors


def render_example(row: dict, chat, *, supported_contract: str) -> dict:
    """Render only reviewed teacher pairs with an explicitly enabled T2 contract.

    Returned metadata keeps full request provenance next to the model prompt.
    A new-format row cannot be converted to a legacy control line losslessly.
    """
    errors = validate_example(row)
    if errors:
        raise ValueError("; ".join(errors))
    rendered = chat.render_row(row["input"], row["target"], None,
                               polish_request=row["polish_request"], supported_contract=supported_contract)
    return {**row, **rendered, "task": "polish", "contract": CONTRACT}


def validate_rendered_row(row: dict, supported_contract: str, user: str) -> list[str]:
    """Trainer entry check: prompt, labels and stored provenance must describe the same pair."""
    if supported_contract != CONTRACT:
        return ["selected Polish row requires explicitly matching data contract"]
    example = row.get("selected_polish_example")
    errors = validate_example(example)
    if errors:
        return errors
    family, source_split = resolve_source_partition(example)
    if row.get("family") != "selected-polish:" + family or row.get("source_split") != source_split:
        errors.append("rendered family/split differs from the reviewed source partition")
    if row.get("polish_request") != example["polish_request"] or row.get("provenance") != example["provenance"]:
        errors.append("rendered request/provenance differs from verified example")
    if row.get("input") != example["input"] or row.get("completion", row.get("target")) != example["target"]:
        errors.append("rendered text/target differs from verified example")
    try:
        if user != render(example["input"], example["polish_request"], supported_contract=supported_contract):
            errors.append("rendered prompt differs from verified example")
    except ValueError as exc:
        errors.append(str(exc))
    return errors
