#!/usr/bin/env python3
"""E1 stand-in adapter: a random-weight rank-16 LoRA in PEFT format for DOSE1 T1's linear layers.

Used only to time the adapter route. Speed depends on the adapter's shapes, not its
values, so nothing is trained. B is kept small so the stand-in changes few tokens; A is ordinary random.
Run with the convert venv (needs torch and safetensors):

  ~/flow-train/convert-venv/bin/python training/t2/make_standin_lora.py \
      --base ~/flow-train/merged/final-20261113-2207 --out ~/flow-train/e1/standin-r16 --rank 16

Target names are the LFM3 linear layers that exist in the merged safetensors: conv in_proj/out_proj, feed_forward
w1/w2/w3, and self_attn q/k/v/o/gate projections. Norms, embeddings and the depthwise conv are not adapted.
"""
import argparse
import json
import struct
from pathlib import Path

import torch
from safetensors.torch import save_file

TARGETS = ["in_proj", "out_proj", "w1", "w2", "w3", "q_proj", "k_proj", "v_proj", "o_proj", "gate_proj"]


def tensor_shapes(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
    header.pop("__metadata__", None)
    return {k: v["shape"] for k, v in header.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=int, default=32)
    ap.add_argument("--seed", type=int, default=20261114)
    ap.add_argument("--b-std", type=float, default=1e-3, help="std of B; larger makes the adapter change outputs more")
    args = ap.parse_args()

    shapes = tensor_shapes(args.base / "model.safetensors")
    targets = []
    for name, shape in shapes.items():
        if not name.startswith("model.layers.") or not name.endswith(".weight") or len(shape) != 2:
            continue
        module = name[: -len(".weight")]
        if module.split(".")[-1] in TARGETS:
            targets.append((module, shape))
    targets.sort()
    g = torch.Generator().manual_seed(args.seed)
    tensors = {}
    for module, (out_f, in_f) in targets:
        prefix = f"base_model.model.{module}"
        # PEFT convention: A (r x in) is random, B (out x r) starts small but non-zero so the adapter does something.
        tensors[f"{prefix}.lora_A.weight"] = (torch.randn(args.rank, in_f, generator=g) / in_f ** 0.5).to(torch.bfloat16)
        tensors[f"{prefix}.lora_B.weight"] = (torch.randn(out_f, args.rank, generator=g) * args.b_std).to(torch.bfloat16)
    args.out.mkdir(parents=True, exist_ok=True)
    save_file(tensors, str(args.out / "adapter_model.safetensors"))
    cfg = {
        "peft_type": "LORA", "task_type": "CAUSAL_LM", "r": args.rank, "lora_alpha": args.alpha,
        "lora_dropout": 0.0, "bias": "none", "fan_in_fan_out": False, "use_rslora": False,
        "base_model_name_or_path": str(args.base),
        "target_modules": sorted({m.split(".")[-1] for m, _ in targets}),
        "modules_to_save": None, "inference_mode": True,
    }
    (args.out / "adapter_config.json").write_text(json.dumps(cfg, indent=2))
    n_params = sum(t.numel() for t in tensors.values())
    print(f"wrote {args.out}: {len(targets)} target modules, rank {args.rank}, {n_params / 1e6:.2f} M params (stand-in, random)")


if __name__ == "__main__":
    main()
