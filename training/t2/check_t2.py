#!/usr/bin/env python3
"""Checker for DOSE1 T2 synthetic rows.

Proves, per row, that every protected value appears in the target exactly as intended, that
superseded values are gone, that no leftover fillers or correction cues reach the target, and
that identity rows are unchanged. Also checks the control line and the row schema.

Usage:  python3 check_t2.py samples/dictation.jsonl samples/typing.jsonl
Exit status 0 only if every row passes.
"""
from __future__ import annotations

import json
import hashlib
import os
import re
import sys
from collections import Counter
from typing import Dict, List, Tuple, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from t2_common import (CUE_REGEX, EM_DASH, EMPTY, FILLER_ONLY_POOL, FILLER_REGEX, parse_control_line, control_line)  # noqa: E402
import t2_common as C

ROW_KEYS = {"id", "task", "control_line", "input", "target", "protected", "ops"}
KINDS = {"name", "number", "money", "date", "time", "weekday", "url", "email", "negation",
         "literal_cue", "instruction_text", "superseded"}


JOINT_CONTRACT = 't2-joint-editing-v1'

def verified_cleanup_controls(row: dict, *, styling_override: Optional[str] = None) -> Optional[str]:
    """Keep provider switches, captured context and our automatic-format policy distinct."""
    settings = row.get("cleanup_settings")
    evidence = row.get("cleanup_settings_evidence") or {}
    if not isinstance(evidence, dict) or evidence.get("settings_verified") is not True:
        return None
    if evidence.get("schema_version") != 2:
        # The old aggregate assertion cannot distinguish observed switches from policy defaults.
        return None
    if not isinstance(settings, dict) or set(settings) != {"level", "styling", "structure", "context"}:
        raise ValueError("verified cleanup settings must explicitly include level, styling, structure and context")
    if not isinstance(evidence.get("source_record"), str) or not evidence["source_record"].strip():
        raise ValueError("verified cleanup settings need their actual source record")
    controls = evidence.get("controls")
    if not isinstance(controls, dict) or set(controls) != set(settings):
        raise ValueError("cleanup evidence must distinguish each switch, captured context and policy")
    expected_kinds = {"level": "observed_auto_cleanup", "styling": "observed_category_style",
                      "context": "captured_app_category"}
    for key, value in settings.items():
        item = controls[key]
        if not isinstance(item, dict) or item.get("verified") is not True or item.get("value") != value:
            raise ValueError("cleanup evidence does not verify its exact control value")
        if not isinstance(item.get("source_record"), str) or not item["source_record"].strip() or not re.fullmatch(r"[0-9a-f]{64}", str(item.get("record_sha256", ""))):
            raise ValueError("cleanup control evidence needs its saved record and hash")
        if key in expected_kinds and item.get("kind") != expected_kinds[key]:
            raise ValueError("cleanup control has the wrong provenance type")
    category = controls["context"].get("app_category")
    if category not in ("personal", "work", "email", "other") or settings["context"] != ("email" if category == "email" else "general"):
        raise ValueError("cleanup context must derive from the actual captured destination category")
    structure = controls["structure"]
    if settings["structure"] == "lists":
        if structure.get("kind") != "automatic_structure_policy" or structure.get("policy") != "wispr-default-auto-structure-v1":
            raise ValueError("lists means provider automatic-format permission, not an observed Wispr structure toggle")
    elif settings["structure"] == "prose":
        target = row.get("target", row.get("output", row.get("output_raw")))
        if (structure.get("kind") != "reviewed_prose_target" or structure.get("meaning_reviewed") is not True
                or not isinstance(target, str) or structure.get("target_sha256") != hashlib.sha256(target.encode()).hexdigest()):
            raise ValueError("prose requires its own reviewed target, not a fabricated provider switch")
    if row.get("style") and row["style"] != settings["styling"]:
        raise ValueError("historical style disagrees with its verified cleanup settings")
    # Validate the recorded values first, before any explicitly synthetic restyling override.
    observed = C.control_line("clean", **settings)
    return C.control_line("clean", **{**settings, "styling": styling_override}) if styling_override else observed


def validate_joint_row(row, contract, user):
    """Explicit task union, with no global Polish validation of clean speech rows."""
    if contract.get('joint_contract') != JOINT_CONTRACT:
        return ['missing explicit supported joint contract']
    task = row.get('task')
    if task == 'polish':
        from polish_contract import CONTRACT, validate_rendered_row
        if contract.get('selected_polish_contract') != CONTRACT or row.get('control_line') is not None:
            return ['joint Polish row requires selected contract and no cleanup header']
        return validate_rendered_row(row, CONTRACT, user)
    if task != 'clean':
        return ['joint row task must be exactly clean or polish']
    if row.get('polish_request') is not None or row.get('selected_polish_example') is not None:
        return ['cleanup row cannot contain a Polish envelope']
    if contract.get('cleanup_contract') != 't2-cleanup-control-v3':
        return ['joint clean row requires the cleanup contract']
    text, target, line = row.get('input'), row.get('completion', row.get('target')), row.get('control_line')
    if not isinstance(text, str) or not isinstance(target, str):
        return ['joint cleanup text and target must be strings']
    if line is None:
        if contract.get('allow_legacy_cleanup_replay') is not True:
            return ['untagged cleanup replay was not explicitly enabled']
        if text.startswith('[Polish request v1] ') or text.startswith('[Task: '):
            return ['legacy cleanup text cannot impersonate a task envelope']
        expected_user = text.strip()
    else:
        try:
            if parse_control_line(line).get('Task') != 'clean':
                return ['cleanup row has a non-clean header']
        except ValueError as exc:
            return [str(exc)]
        expected_user = line + '\n' + text.strip()
        if row.get('real'):
            try:
                if verified_cleanup_controls(row) != line:
                    return ['real controlled cleanup lacks matching per-control provenance']
            except ValueError as exc:
                return [str(exc)]
    if user != expected_user:
        return ['joint cleanup prompt differs from its exact source/header']
    if row.get('speech_fingerprint_required'):
        if not contract.get('speech_fingerprint') or row.get('speech_fingerprint') != contract['speech_fingerprint']:
            return ['production cleanup speech fingerprint does not match the joint contract']
    probe = {'id':str(row.get('id')), 'task':'clean', 'control_line':line or control_line('clean'),
             'input':text, 'target':target, 'protected':row.get('protected', []), 'ops':row.get('ops', [])}
    return ['%s: %s' % error for error in check_row(probe)]

def _boundary_find(value: str, text: str) -> bool:
    return re.search(r"(?<![A-Za-z0-9])" + re.escape(value) + r"(?![A-Za-z0-9])", text) is not None


def check_row(row: dict) -> List[Tuple[str, str]]:
    """Return a list of (check_name, message). Empty list means the row passes."""
    errs: List[Tuple[str, str]] = []
    if not isinstance(row, dict) or set(row) != ROW_KEYS:
        return [("schema", f"keys are {sorted(row) if isinstance(row, dict) else type(row).__name__}")]
    for key in ("id", "control_line", "input", "target"):
        if not isinstance(row[key], str):
            errs.append(("schema", f"{key} is not a string"))
    if errs:
        return errs
    try:
        ctrl = parse_control_line(row["control_line"])
    except ValueError as exc:
        errs.append(("control_line", str(exc)))
        ctrl = {}
    if ctrl and row["task"] != ctrl.get("Task"):
        errs.append(("control_line", f"task {row['task']!r} does not match control line"))

    inp, tgt = row["input"], row["target"]
    if not inp.strip():
        errs.append(("input", "empty input"))
    if EM_DASH in tgt:
        errs.append(("no_em_dash", "em dash in target"))

    if tgt == EMPTY:
        words = re.findall(r"[A-Za-z']+", inp.lower())
        stray = [w for w in words if w not in FILLER_ONLY_POOL]
        if stray:
            errs.append(("filler_only", f"target EMPTY but input has non-filler words: {stray[:3]}"))
        if row["protected"]:
            errs.append(("filler_only", "filler-only row must not carry protected values"))
    else:
        if not tgt.strip():
            errs.append(("target", "empty target"))
        if FILLER_REGEX.search(tgt):
            errs.append(("leftover_filler", "filler word left in target"))
        literal = any(e.get("kind") == "literal_cue" for e in row["protected"] if isinstance(e, dict))
        if CUE_REGEX.search(tgt) and not literal:
            errs.append(("leftover_cue", "correction cue left in target"))

    for entry in row["protected"]:
        if not isinstance(entry, dict) or set(entry) - {"kind", "value", "input"} or "kind" not in entry or "value" not in entry:
            errs.append(("schema", f"bad protected entry {entry!r}"[:120]))
            continue
        kind, value = entry["kind"], entry["value"]
        if kind not in KINDS:
            errs.append(("schema", f"unknown kind {kind!r}"))
            continue
        if kind == "superseded":
            if _boundary_find(value, tgt):
                errs.append(("superseded", f"superseded value {value!r} still in target"))
            continue
        if not value:
            errs.append(("protected", "empty protected value"))
            continue
        if not _boundary_find(value, tgt):
            errs.append(("protected", f"{kind} value {value!r} missing from target"))
        if "input" in entry and entry["input"].casefold() not in inp.casefold():
            errs.append(("protected", f"{kind} rendering {entry['input']!r} missing from input"))

    ops = row["ops"]
    if not isinstance(ops, list):
        errs.append(("schema", "ops is not a list"))
    elif any(isinstance(o, dict) and o.get("op") == "identity" for o in ops) and inp != tgt:
        errs.append(("identity", "identity row input differs from target"))
    return errs


def check_rows(rows: List[dict]) -> Dict[str, object]:
    ids = Counter(r.get("id") for r in rows if isinstance(r, dict))
    dup = [k for k, v in ids.items() if v > 1]
    failures: List[Tuple[str, str, str]] = []
    checked = 0
    checks = Counter()
    for row in rows:
        errs = check_row(row)
        rid = row.get("id", "?") if isinstance(row, dict) else "?"
        if isinstance(row, dict):
            checked += sum(1 for e in row.get("protected", []) if isinstance(e, dict) and e.get("kind") != "superseded")
        for name, msg in errs:
            failures.append((rid, name, msg))
            checks[name] += 1
    if dup:
        failures.append(("(file)", "ids", f"duplicate ids: {dup[:5]}"))
    return {"rows": len(rows), "protected_checked": checked, "failed_rows": len({f[0] for f in failures}),
            "failures_by_check": dict(checks), "examples": failures[:10]}


def main(argv: List[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    overall_fail = 0
    for path in argv:
        with open(path, encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
        result = check_rows(rows)
        overall_fail += result["failed_rows"]
        print(f"{path}: rows={result['rows']} protected_values_checked={result['protected_checked']} "
              f"failed_rows={result['failed_rows']}")
        if result["failures_by_check"]:
            print("  by check:", result["failures_by_check"])
            for rid, name, msg in result["examples"]:
                print(f"  - {rid} [{name}] {msg}")
    return 0 if overall_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
