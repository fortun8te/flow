"""Process-private D1 worker for Flow. The pipes carry only bounded JSON frames."""

import json
import math
import os
from pathlib import Path
import re
import sys

MAX_FRAME = 8192
MAX_STATE = 6000
LABEL = re.compile(r"[a-zA-Z0-9_-]{1,32}")
REQUEST_ID = re.compile(r"[a-fA-F0-9-]{36}")


def small_text(value, limit):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= limit


def label(value):
    return isinstance(value, str) and LABEL.fullmatch(value) is not None


def valid_question(question):
    if not isinstance(question, dict) or not small_text(question.get("instructions"), 500):
        return False
    kind = question.get("type")
    criteria = question.get("criteria")
    if kind == "noul":
        return set(question) == {"type", "instructions"}
    return (
        kind == "choice"
        and set(question) == {"type", "instructions", "criteria"}
        and isinstance(criteria, dict)
        and 2 <= len(criteria) <= 6
        and all(label(key) and small_text(value, 300) for key, value in criteria.items())
    )


def valid_request(request):
    if not isinstance(request, dict) or set(request) != {"id", "state", "questions"}:
        return False
    questions = request["questions"]
    return (
        isinstance(request["id"], str)
        and REQUEST_ID.fullmatch(request["id"]) is not None
        and small_text(request["state"], MAX_STATE)
        and isinstance(questions, dict)
        and 1 <= len(questions) <= 8
        and all(label(name) and valid_question(question) for name, question in questions.items())
    )


def probabilities(answer, question):
    if question["type"] == "noul":
        yes = float(answer["noul"])
        values = {"yes": yes, "no": 1.0 - yes}
    else:
        raw = answer["probabilities"]
        if set(raw) != set(question["criteria"]):
            raise ValueError("unexpected choices")
        values = {key: float(value) for key, value in raw.items()}
    if not all(math.isfinite(value) and 0 <= value <= 1 for value in values.values()):
        raise ValueError("invalid probability")
    if abs(math.fsum(values.values()) - 1.0) > 0.01:
        raise ValueError("invalid distribution")
    return values


def run():
    # Reserve stdout for protocol frames. Suppress library logging, including
    # native writes to file descriptor 1, through the parent's /dev/null stderr.
    output = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())

    def emit(reply):
        payload = json.dumps(reply, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
        if len(payload) + 1 > MAX_FRAME:
            raise ValueError("reply too large")
        output.write(payload + "\n")

    checkpoint = Path(sys.argv[1])
    if not (checkpoint / "config.json").is_file() or not (checkpoint / "model.safetensors").is_file():
        return 1
    from mlx_vlm import load

    model, _processor = load(str(checkpoint), local_files_only=True, trust_remote_code=False)
    model.system_one("This is a local startup check.", {
        "check": {"type": "noul", "instructions": "Is this a startup check?"},
    })
    emit({"ready": True})

    while line := sys.stdin.buffer.readline(MAX_FRAME + 1):
        if len(line) > MAX_FRAME or not line.endswith(b"\n"):
            return 1
        request = json.loads(line)
        if not valid_request(request):
            return 1
        result = model.system_one(request["state"], request["questions"])["answers"]
        emit({
            "id": request["id"],
            "answers": {
                name: probabilities(result[name], question)
                for name, question in request["questions"].items()
            },
        })
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except Exception:
        # Never include draft text, model output, or an exception in a log.
        raise SystemExit(1) from None
