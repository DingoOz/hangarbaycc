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

# Vision (mmproj) support: off by default. Grok Build is a text-only coding
# CLI in practice, and loading mmproj costs load time + RAM for a capability
# that's rarely used. Set GROK_LOCAL_IMAGES=1/0 to skip the prompt (e.g. for
# non-interactive/systemd starts, which default to off).
MMPROJ_ARGS=()
if [[ "${GROK_LOCAL_IMAGES:-}" == "1" ]]; then
  MMPROJ_ARGS=(--mmproj "$MODEL_DIR/mmproj-F16.gguf" --no-mmproj-offload)
elif [[ -z "${GROK_LOCAL_IMAGES:-}" && -t 0 ]]; then
  read -r -p "Load image/vision support (mmproj)? Rarely needed for coding, adds load time/RAM [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    MMPROJ_ARGS=(--mmproj "$MODEL_DIR/mmproj-F16.gguf" --no-mmproj-offload)
  fi
fi

# Auto-unload timer: GROK_LOCAL_TIMEOUT in minutes; -1 or 0 (default) = run
# forever, same as before. Anything else kills the server after that many
# minutes, freeing the VRAM without you having to remember to do it. Can't
# use `exec` for the server anymore once a watchdog needs to outlive it, so
# this script now stays resident as the parent (it was already backgrounded
# by hangarbaycc.sh via setsid nohup, so that's no behavior change there).
GROK_LOCAL_TIMEOUT="${GROK_LOCAL_TIMEOUT:--1}"

"$LLAMA_SERVER" \
  -m "$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf" \
  "${MMPROJ_ARGS[@]}" \
  -ngl 99 --n-cpu-moe 25 \
  -c 110000 -fa on \
  -np 1 \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  --dry-multiplier 0.8 \
  --reasoning-budget 4000 --no-reasoning-preserve \
  --host 127.0.0.1 --port 8080 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ "$GROK_LOCAL_TIMEOUT" != "-1" && "$GROK_LOCAL_TIMEOUT" != "0" ]]; then
  (
    sleep "$(( GROK_LOCAL_TIMEOUT * 60 ))"
    echo ">> Auto-unload timer (${GROK_LOCAL_TIMEOUT}m) elapsed — stopping server."
    kill "$SERVER_PID" 2>/dev/null || true
  ) &
fi

wait "$SERVER_PID"

# Tuning notes (measured from /tmp/hangarbaycc-grok-local.log, 666 turns):
#   -c 110000        — was 200000, but the model's output quality collapses into
#                      repetition loops past ~90k anyway, so the extra KV cache
#                      (~26KB/token at q8_0: 200k ≈ 5GB vs 110k ≈ 2.9GB) bought
#                      nothing but VRAM pressure. The grok client is told
#                      context_window = 100000 so it compacts before the
#                      degradation zone; the extra 10k here is headroom.
#   --n-cpu-moe 25   — unchanged from the original. Tried dropping to 22 to
#                      trade the smaller KV cache's freed VRAM for more GPU-
#                      resident MoE experts, but that undershot: the compute
#                      buffers alone (not just KV cache + weights) need more
#                      headroom than estimated, and it OOM'd on startup
#                      (cudaMalloc failed allocating ~690MB for graph/compute
#                      buffers). Left at 25 — revisit only with actual free-
#                      VRAM headroom to spare, not by estimate.
#   --dry-multiplier — DRY sampler (server-side default; applies since the grok
#                      client doesn't send it). Penalizes verbatim repetition of
#                      recent sequences — targets exactly the long-context
#                      looping failure mode, with less quality cost than a
#                      blanket repetition penalty.
#   --reasoning-budget 4000 — this is a *reasoning* model: a single bench turn
#                      on the merge_intervals prompt spent 6,134-8,192 tokens
#                      in reasoning_content before answering (confirmed via
#                      curl against the raw stream — server TTFB is 0.2s, the
#                      82s+ "TTFT" bench-local.py reported was actually time
#                      spent thinking, which the script doesn't count as
#                      output). Unbounded thinking (-1, the default) is both
#                      slow and exactly the kind of unconstrained generation
#                      where repetition loops take hold. 4000 leaves room for
#                      a real answer within max_completion_tokens (8192).
#   --no-reasoning-preserve — don't carry old turns' reasoning traces forward
#                      in full history (grok's own reasoning_effort/--effort
#                      flag is a no-op here — llama-server has no
#                      reasoning_effort request param, only these two server
#                      flags actually govern it). Keeps context growth
#                      dominated by real conversation content, not thinking
#                      exhaust — matters both for hitting the 90k+ zone later
#                      and for not re-feeding the model its own past
#                      (possibly repetitive) reasoning as future input.
