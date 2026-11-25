#!/bin/bash
# Merged WhisperNow HF model (from the PC) -> BF16 GGUF -> Q8_0, Q6_K, Q5_K_M, Q4_K_M, then a sanity check
# against stock WhisperNow Q8_0 on built-in, non-private prompts. Runs on the Mac, under nice.
#
#   scripts/whispernow-to-gguf.sh ~/flow-train/wn-merged-v1                 # -> ~/flow-train/gguf/wn-merged-v1/
#   scripts/whispernow-to-gguf.sh ~/flow-train/wn-merged-v1 OUT_DIR "Q8_0 Q6_K"
#   scripts/whispernow-to-gguf.sh --setup-only                              # fetch converter + venv, nothing else
#
# Converter: llama.cpp's convert_hf_to_gguf.py at the SAME build tag as the installed llama-quantize /
# llama-server (Homebrew), fetched once into ~/flow-train/llama.cpp-b<build>. Every quant is made from the
# one BF16 GGUF (never requantized from Q8). LFM3 needs llama.cpp b11960 or newer.
# Undo: delete the output folder. Nothing outside ~/flow-train is written.
set -euo pipefail

ROOT="$HOME/flow-train"
STOCK="$HOME/.cache/huggingface/hub/models--category271--whispernow-lfm3-1.7b/snapshots/34d7624c191379f40b63aa48b7d6bad3d7987f73/model-Q8_0.gguf"
HERE="$(cd "$(dirname "$0")" && pwd)"
QUANTIZE="$(command -v llama-quantize || true)"
[ -n "$QUANTIZE" ] || { echo "llama-quantize not found (brew install llama.cpp)"; exit 2; }
BUILD="$( { "$QUANTIZE" --version 2>&1; "$(dirname "$QUANTIZE")/llama-server" --version 2>&1; } | sed -n 's/.*build \([0-9][0-9]*\).*/\1/p' | head -1 || true)"
[ -n "$BUILD" ] || { echo "cannot read the llama.cpp build number"; exit 2; }
[ "$BUILD" -ge 11960 ] || { echo "llama.cpp b$BUILD is older than b11960 (no LFM3 support)"; exit 2; }
SRC="$ROOT/llama.cpp-b$BUILD"
VENV="$ROOT/convert-venv"

setup() {
  mkdir -p "$ROOT"
  if [ ! -f "$SRC/convert_hf_to_gguf.py" ]; then
    echo "== fetching llama.cpp source at tag b$BUILD (converter only)"
    git clone --quiet --depth 1 --branch "b$BUILD" --filter=blob:none --sparse https://github.com/ggml-org/llama.cpp.git "$SRC"
    git -C "$SRC" sparse-checkout set --no-cone /convert_hf_to_gguf.py /conversion /gguf-py /requirements /LICENSE
  fi
  if [ ! -x "$VENV/bin/python" ]; then
    echo "== creating converter venv (CPU torch, transformers 5.18.0 for the LFM3 tokenizer)"
    uv venv --quiet --python 3.12 "$VENV"
    uv pip install --quiet --python "$VENV/bin/python" torch numpy sentencepiece safetensors protobuf \
        "transformers==5.18.0" "tokenizers==0.23.2" "$SRC/gguf-py"
  fi
}

if [ "${1:-}" = "--setup-only" ]; then setup; echo "converter ready: $SRC ($VENV)"; exit 0; fi
MERGED="${1:?usage: whispernow-to-gguf.sh MERGED_DIR [OUT_DIR] [\"QUANTS\"]}"
MERGED="$(cd "$MERGED" && pwd)"
OUT="${2:-$ROOT/gguf/$(basename "$MERGED")}"
QUANTS="${3:-Q8_0 Q6_K Q5_K_M Q4_K_M}"
for f in config.json tokenizer.json chat_template.jinja modeling_lfm3.py; do
  [ -f "$MERGED/$f" ] || { echo "missing $f in $MERGED"; exit 2; }
done
ls "$MERGED"/*.safetensors >/dev/null 2>&1 || { echo "no safetensors weights in $MERGED"; exit 2; }
grep -q '"model_type": "lfm3"' "$MERGED/config.json" || { echo "$MERGED is not an LFM3 model"; exit 2; }
setup
mkdir -p "$OUT"; chmod 700 "$OUT"

if [ ! -f "$OUT/model-BF16.gguf" ]; then
  echo "== converting to BF16 GGUF"
  PYTHONPATH="$SRC/gguf-py" nice -n 10 "$VENV/bin/python" "$SRC/convert_hf_to_gguf.py" "$MERGED" \
      --outfile "$OUT/model-BF16.gguf.part" --outtype bf16
  mv "$OUT/model-BF16.gguf.part" "$OUT/model-BF16.gguf"
fi
for q in $QUANTS; do
  if [ ! -f "$OUT/model-$q.gguf" ]; then
    echo "== quantizing $q (from BF16)"
    nice -n 10 "$QUANTIZE" "$OUT/model-BF16.gguf" "$OUT/model-$q.gguf.part" "$q" > "$OUT/quantize-$q.log" 2>&1
    mv "$OUT/model-$q.gguf.part" "$OUT/model-$q.gguf"
  fi
done
for f in LICENSE MODIFIED.txt ATTRIBUTION.txt chat_template.jinja; do [ -f "$MERGED/$f" ] && cp "$MERGED/$f" "$OUT/"; done

python3 - "$OUT" "$MERGED" "$BUILD" <<'PY'
import hashlib, json, os, sys, time
out, merged, build = sys.argv[1:]
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''): h.update(c)
    return h.hexdigest()
files = {n: {'bytes': os.path.getsize(os.path.join(out, n)), 'sha256': sha(os.path.join(out, n))}
         for n in sorted(os.listdir(out)) if n.endswith('.gguf')}
receipt = os.path.join(merged, '..', 'train_receipt.json')
manifest = {'made_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'merged_dir': merged,
            'llama_cpp_build': 'b' + build, 'files': files,
            'train_receipt_merged_files': json.load(open(receipt)).get('merged_files') if os.path.exists(receipt) else None}
open(os.path.join(out, 'manifest.json'), 'w').write(json.dumps(manifest, indent=2))
for n, f in files.items(): print('%-22s %6.0f MB  %s' % (n, f['bytes'] / 1e6, f['sha256'][:16]))
PY

echo "== sanity: tuned Q8_0 vs stock WhisperNow Q8_0 on built-in prompts"
if [ -f "$STOCK" ]; then
  python3 "$HERE/eval-whispernow.py" --sanity "$OUT/model-Q8_0.gguf" --compare "$STOCK"
else
  python3 "$HERE/eval-whispernow.py" --sanity "$OUT/model-Q8_0.gguf"
fi
echo "done: $OUT"
