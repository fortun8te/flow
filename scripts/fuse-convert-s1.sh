#!/bin/bash
# Turn the PC's merged BF16 S1-mini into the 4-bit MLX folder Flow loads, with the same quantization as
# mlx-community/S1-mini-MLX-4bit (mlx-lm 0.31.3, affine, 4 bits, group size 64, BF16 for the rest).
# Light work: about a minute of CPU/GPU and ~2 GB of disk. Nothing is uploaded.
#
#   scripts/fuse-convert-s1.sh --verify-recipe                       # once: prove the recipe reproduces stock bit-for-bit
#   scripts/fuse-convert-s1.sh <merged dir from the PC> [name]       # default name: S1-mini-wispr-v1
#
# Output: ~/Library/Caches/models/flow/<name>/ (published atomically), with .voice-model.json listing
# every file's size and SHA-256, LICENSE + NOTICE + MODIFIED.txt for attribution.
set -euo pipefail

MLX_LM_VERSION="0.31.3"
VENV="${FLOW_TRAIN_VENV:-$HOME/.venvs/flow-train}"
STOCK="$HOME/Library/Caches/models/mlx-community/S1-mini-MLX-4bit"
STOCK_SHA="284990f04854426d6164d634d8c472d7eb6e79c68f8fd8b4c8a80a4f234276ba"
BASE_REPO="superwhisper/s1-mini"
BASE_REVISION="88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES="$ROOT/Sources/Voice/Resources/ModelNotices/S1-mini"
DEST_ROOT="$HOME/Library/Caches/models/flow"

ensure_venv() {
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
  fi
  if ! "$VENV/bin/python" -c "import mlx_lm, sys; sys.exit(mlx_lm.__version__ != '$MLX_LM_VERSION')" 2>/dev/null; then
    "$VENV/bin/pip" install --quiet "mlx-lm==$MLX_LM_VERSION" "huggingface_hub>=0.35"
  fi
}

convert() {  # $1 = BF16 HF folder, $2 = output folder
  "$VENV/bin/python" -m mlx_lm convert --hf-path "$1" --mlx-path "$2" \
    -q --q-bits 4 --q-group-size 64 --q-mode affine --dtype bfloat16
}

ensure_venv

if [ "${1:-}" = "--verify-recipe" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  base="$("$VENV/bin/python" -c "from huggingface_hub import snapshot_download as s; print(s('$BASE_REPO', revision='$BASE_REVISION'))")"
  convert "$base" "$work/stock-rebuilt"
  got="$(shasum -a 256 "$work/stock-rebuilt/model.safetensors" | cut -d' ' -f1)"
  if [ "$got" = "$STOCK_SHA" ]; then
    echo "Recipe verified: rebuilt stock S1-mini is bit-identical to mlx-community/S1-mini-MLX-4bit."
  else
    echo "Recipe differs: rebuilt $got, expected $STOCK_SHA."
    echo "Weights may still be equivalent (metadata/order). Compare outputs with the eval script before trusting it."
    exit 2
  fi
  exit 0
fi

MERGED="${1:?usage: fuse-convert-s1.sh <merged dir> [name] | --verify-recipe}"
NAME="${2:-S1-mini-wispr-v1}"
[ -f "$MERGED/config.json" ] || { echo "No config.json in $MERGED"; exit 1; }
ls "$MERGED"/*.safetensors >/dev/null 2>&1 || { echo "No safetensors in $MERGED"; exit 1; }

mkdir -p "$DEST_ROOT"
chmod 700 "$DEST_ROOT"
DEST="$DEST_ROOT/$NAME"
TMP="$DEST_ROOT/.$NAME.tmp-$$"
rm -rf "$TMP"
convert "$MERGED" "$TMP"

# Flow's S1MiniPolisher.isCompleteCache needs these files; the chat template must equal stock's byte-for-byte.
if [ ! -f "$TMP/chat_template.jinja" ]; then cp "$STOCK/chat_template.jinja" "$TMP/"; fi
cmp -s "$TMP/chat_template.jinja" "$STOCK/chat_template.jinja" || { echo "chat_template.jinja differs from stock"; exit 1; }
cp "$STOCK/generation_config.json" "$TMP/generation_config.json"
cp "$NOTICES/LICENSE" "$NOTICES/NOTICE" "$TMP/"
if [ -f "$MERGED/MODIFIED.txt" ]; then cp "$MERGED/MODIFIED.txt" "$TMP/"; else
  echo "S1-mini by Superwhisper, modified: LoRA fine-tuned locally for Wispr-style cleanup." > "$TMP/MODIFIED.txt"; fi

"$VENV/bin/python" - "$TMP" "$STOCK" "$NAME" "$MERGED" <<'PY'
import hashlib, json, os, sys, time
tmp, stock, name, merged = sys.argv[1:]
cfg, ref = json.load(open(os.path.join(tmp, 'config.json'))), json.load(open(os.path.join(stock, 'config.json')))
for key in ('model_type', 'hidden_size', 'num_hidden_layers', 'num_attention_heads', 'num_key_value_heads',
            'intermediate_size', 'vocab_size', 'tie_word_embeddings', 'quantization', 'rope_theta'):
    if cfg.get(key) != ref.get(key):
        sys.exit('config.json %s differs from stock: %r vs %r' % (key, cfg.get(key), ref.get(key)))
a = set(json.load(open(os.path.join(tmp, 'model.safetensors.index.json')))['weight_map']) if os.path.exists(os.path.join(tmp, 'model.safetensors.index.json')) else None
b = set(json.load(open(os.path.join(stock, 'model.safetensors.index.json')))['weight_map'])
if a is not None and a != b:
    sys.exit('Tensor names differ from stock (%d vs %d)' % (len(a), len(b)))
files = []
for entry in sorted(os.listdir(tmp)):
    path = os.path.join(tmp, entry)
    if os.path.isfile(path) and not entry.startswith('.'):
        h = hashlib.sha256(open(path, 'rb').read()).hexdigest()
        files.append({'path': entry, 'size': os.path.getsize(path), 'sha256': h})
receipt = {'schemaVersion': 1, 'modelId': name.lower(), 'repository': 'local:flow-wispr-cleanup',
           'revision': hashlib.sha256(''.join(f['sha256'] for f in files).encode()).hexdigest()[:40],
           'base': 'superwhisper/s1-mini@88f6b15896c73bbb13a3b596e0afe8ea0d5150b4',
           'attribution': 'S1-mini by Superwhisper, modified', 'source_merged_dir': merged,
           'completedAtUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'files': files}
receipt['manifestSHA256'] = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
json.dump(receipt, open(os.path.join(tmp, '.voice-model.json'), 'w'), indent=1)
weights = next(f for f in files if f['path'] == 'model.safetensors')
print('model.safetensors size %d sha256 %s' % (weights['size'], weights['sha256']))
PY

chmod -R go-rwx "$TMP"
if [ -d "$DEST" ]; then mv "$DEST" "$DEST.previous-$(date +%Y%m%d%H%M%S)"; fi
mv "$TMP" "$DEST"
echo "Published $DEST"
echo "Next: python3 scripts/eval-cleanup-vs-wispr.py --mlx-model \"$DEST\"   (model-only check after quantization)"
