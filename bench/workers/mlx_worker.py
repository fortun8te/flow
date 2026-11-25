#!/usr/bin/env python3
"""MLX engine worker. Run with the venv that has mlx_lm (~/.venvs/flow-train/bin/python).

Usage: mlx_worker.py MODEL_DIR CASES_JSON OUT_JSON SYSTEM CONTROL_LINE
Mirrors the S1-mini path used by the cleanup shoot-out: system = upstream prompt,
user = control line + newline + raw text, enable_thinking=False, greedy, and
max_tokens = clamp(ceil(1.3 x input tokens) + 32, 64, 1024). Writes {"load_s", "results": [...]}.
"""
import json
import math
import sys
import time

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


def main():
    model_dir, cases_path, out_path, system, control = sys.argv[1:6]
    cases = json.load(open(cases_path))
    t0 = time.time()
    model, tok = load(model_dir)
    load_s = round(time.time() - t0, 2)
    sampler = make_sampler(temp=0.0)
    results = []
    for c in cases:
        msgs = []
        if system:
            msgs.append({"role": "system", "content": system})
        user = (control + "\n" if control else "") + c["raw"]
        msgs.append({"role": "user", "content": user})
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        n_in = len(tok.encode(c["raw"], add_special_tokens=False))
        limit = min(1024, max(64, math.ceil(1.3 * n_in) + 32))
        t = time.time()
        err = None
        text = None
        try:
            text = generate(model, tok, prompt=prompt, max_tokens=limit, sampler=sampler, verbose=False)
        except Exception as e:  # recorded, never silently dropped
            err = repr(e)
        results.append({"id": c["id"], "output": text, "seconds": round(time.time() - t, 3),
                        "error": err, "finish_reason": "length" if text is not None and len(tok.encode(text)) >= limit else "stop"})
    json.dump({"load_s": load_s, "results": results}, open(out_path, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
