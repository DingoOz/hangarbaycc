#!/usr/bin/env bash
#
# grok-local-server.sh — starts llama-server serving Qwen3.6-35B-A3B on THIS
# machine's own GPU, for the "Grok Build (local)" backend in hangarbaycc.sh
# (menu option 5). Vendored in from ~/ai-models/qwen3.6-35b-a3b/run.sh (tuned
# for an RTX 5080 16GB / 32GB RAM, per
# https://x.com/DogukanUrker/status/2077472690156511643 — orig: RTX 3060 12GB
# / 16GB RAM) so hangarbaycc.sh has no external script reference. The model
# weights and the llama-server binary itself still live outside the repo (too
# large to vendor) — both paths are overridable below if yours differ.
set -euo pipefail

MODEL_DIR="${GROK_LOCAL_MODEL_DIR:-$HOME/ai-models/qwen3.6-35b-a3b}"
LLAMA_SERVER="${GROK_LOCAL_LLAMA_SERVER:-$HOME/llama.cpp/build/bin/llama-server}"

exec "$LLAMA_SERVER" \
  -m "$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf" \
  --mmproj "$MODEL_DIR/mmproj-F16.gguf" \
  --no-mmproj-offload \
  -ngl 99 --n-cpu-moe 25 \
  -c 200000 -fa on \
  -np 1 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  --host 127.0.0.1 --port 8080
