#!/usr/bin/env bash
#
# launch-ornith.sh — launch Claude Code wired to a local Ollama model,
#                    with a chosen KV cache precision and context window.
#
# VERIFIED FIT TABLE — measured on this RTX 5060 Ti (16 GB) via the preload
# guard (/api/ps size_vram vs size). Numbers are total reported VRAM use.
#
#   ornith:latest (~5.6 GB weights) — FITS EVERYTHING, 100% GPU:
#     ctx     q4_0     q8_0     f16
#     32K     5.7 GB   6.0 GB   6.4 GB
#     64K     6.1 GB   6.6 GB   7.4 GB
#     128K    7.0 GB   8.1 GB   9.6 GB
#     256K    8.9 GB   11 GB    14 GB     <- 256K/f16 is the heaviest, still fits
#
#   gemma4:latest (8B, Q4_K_M) — FITS EVERYTHING, 100% GPU. Max context is 128K.
#     Peak ~6.5 GB VRAM at 128K/f16 — comfortable headroom everywhere.
#
#   gpt-oss:20b (~12 GB MXFP4 MoE) — max context 128K. Sliding-window attention
#     keeps KV growth tiny, so context is nearly free — EXCEPT f16 KV, which
#     spills to CPU beyond 32K:
#     ctx     q4_0     q8_0     f16
#     32K     11.9 GB  12.0 GB  11.9 GB
#     64K     12.2 GB  12.2 GB  13.3 GB (2.0 GB on CPU — DON'T)
#     128K    12.2 GB  12.2 GB  13.3 GB (2.0 GB on CPU — DON'T)
#     -> for gpt-oss pick q8_0 KV and any context up to 128K.
#
# (qwen3-coder:30b was dropped: ~18 GB weights exceed 16 GB VRAM, so it spills
#  to CPU at every context/KV setting and runs CPU-bound. Not offered here.)
#
# On launch you pick the model, context window, and KV cache precision. The
# preload guard aborts on a CPU spill; if it triggers, re-run with a smaller
# context and/or more compressed KV cache.
#
set -euo pipefail

HOST="127.0.0.1:11434"
PROXY_HOST="127.0.0.1:11435"   # temperature-clamping proxy in front of HOST
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/ornith-editing-rules.md"
TEMP_PROXY="$SCRIPT_DIR/ornith-temp-proxy.py"

# Small models emit malformed/hallucinated tool calls when too many tools are
# in context. The temp proxy STRIPS these from the `tools` schema on every
# /v1/messages request, so the model never sees them at all — no hallucinated
# calls, and several thousand tokens of schema freed for actual code context.
# --disallowedTools is kept as a backstop (it auto-denies at execution time in
# case a call slips through, e.g. when the proxy isn't running).
# 'Task' is kept here only for older builds; the live subagent tool is 'Agent'.
DISALLOWED_TOOLS=(Task Agent Workflow WebFetch WebSearch NotebookEdit)

# `ollama launch claude` sets CLAUDE_CODE_SUBAGENT_MODEL to EMPTY. Claude's logic
# is: if the var is set and != "inherit", use it; otherwise fall back to a default
# 'sonnet' alias — which this local Ollama cannot serve, so every spawned agent
# panel errors with "There's an issue with the selected model". Forcing "inherit"
# makes any subagent reuse the running local model instead, so a stray Agent call
# is harmless rather than an error. Passed via --settings (scoped to THIS launch
# only; your normal cloud Claude is untouched). settings.env beats process env.
SUBAGENT_SETTINGS='{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"inherit"}}'

# --- interactive selection -----------------------------------------------------
# Each model carries its own max context and sampling band. Claude Code sends
# temp=1.0 on every request; the proxy clamps it into [TEMP_FLOOR, TEMP_CEIL].
# A single low value keeps tool calls clean but makes a small model loop; a band
# keeps enough entropy to escape agentic repetition loops. gpt-oss is the
# exception: its recommended sampling IS temp 1.0 / top_p 1.0, so its band is
# 0.9-1.0 and the clamp is effectively a no-op.
echo "Select model:   (see fit table in header; the preload guard verifies fit)"
echo "  1) ornith:latest         9B,  5.6 GB weights, full 256K context (bench: 4/8)"
echo "  2) gemma4:latest         8B Q4_K_M, max 128K context"
echo "  3) qwen2.5-coder:14b     strong coder, native 32K context (capped at 32K)"
echo "  4) gpt-oss:20b           20B MoE, ~12 GB, max 128K, use q8_0 KV (bench: 8/8)"
read -rp "Model [1-4]: " MODEL_CHOICE
case "$MODEL_CHOICE" in
  1) MODEL="ornith:latest"     MAX_CTX=262144 TEMP_FLOOR=0.55 TEMP_CEIL=0.70 TOP_P_CEIL=0.95 ;;
  2) MODEL="gemma4:latest"     MAX_CTX=131072 TEMP_FLOOR=0.55 TEMP_CEIL=0.70 TOP_P_CEIL=0.95 ;;
  3) MODEL="qwen2.5-coder:14b" MAX_CTX=32768  TEMP_FLOOR=0.55 TEMP_CEIL=0.70 TOP_P_CEIL=0.95 ;;
  4) MODEL="gpt-oss:20b"       MAX_CTX=131072 TEMP_FLOOR=0.90 TEMP_CEIL=1.00 TOP_P_CEIL=1.00 ;;
  *) echo "!! Invalid model choice: $MODEL_CHOICE" >&2; exit 1 ;;
esac

# Models live in either the system store or the user store; Ollama can only use
# one at a time, so point OLLAMA_MODELS at whichever store has the chosen model.
MODEL_STORE=""
for store in /var/lib/ollama/models "$HOME/.ollama/models"; do
  manifest="$store/manifests/registry.ollama.ai/library/${MODEL%%:*}/${MODEL##*:}"
  if [[ -f "$manifest" ]]; then MODEL_STORE="$store"; break; fi
done
if [[ -z "$MODEL_STORE" ]]; then
  echo "!! Model '$MODEL' not found in /var/lib/ollama/models or ~/.ollama/models." >&2
  echo "!! Pull it first ('ollama pull $MODEL') — or, if a pull is in progress," >&2
  echo "!! wait for it to finish (manifests only appear when the download completes)." >&2
  exit 1
fi

echo "Select context window:   (${MODEL} caps at $MAX_CTX)"
echo "  1) 32K   (32768)"
echo "  2) 64K   (65536)"
echo "  3) 128K  (131072)"
echo "  4) 256K  (262144)"
read -rp "Context [1-4]: " CTX_CHOICE
case "$CTX_CHOICE" in
  1) NUM_CTX=32768 ;;
  2) NUM_CTX=65536 ;;
  3) NUM_CTX=131072 ;;
  4) NUM_CTX=262144 ;;
  *) echo "!! Invalid context choice: $CTX_CHOICE" >&2; exit 1 ;;
esac

# Clamp to the model's native maximum (beyond it Ollama either silently clamps
# or quality degrades without YaRN — not wired here).
if [[ "$NUM_CTX" -gt "$MAX_CTX" ]]; then
  echo ">> $MODEL caps at $MAX_CTX context; clamping (was $NUM_CTX)."
  NUM_CTX=$MAX_CTX
fi

echo "Select KV cache type:"
echo "  1) fp16  (f16)   full precision, largest"
echo "  2) q8_0          half size, near-lossless"
echo "  3) Q4_0          quarter size, smallest"
read -rp "KV cache [1-3]: " KV_CHOICE
case "$KV_CHOICE" in
  1) KV_CACHE_TYPE="f16"  ;;
  2) KV_CACHE_TYPE="q8_0" ;;
  3) KV_CACHE_TYPE="q4_0" ;;
  *) echo "!! Invalid KV cache choice: $KV_CHOICE" >&2; exit 1 ;;
esac

# qwen2.5-coder is known to be numerically touchy with an fp16 KV cache (attention
# overflow -> degraded/garbled output on long contexts). q8_0 is near-lossless and
# avoids it; warn here but don't override the user's explicit choice.
if [[ "$MODEL" == "qwen2.5-coder:14b" && "$KV_CACHE_TYPE" == "f16" ]]; then
  echo ">> WARNING: qwen2.5-coder can be unstable with an fp16 KV cache; prefer q8_0" >&2
  echo ">>          (near-lossless) if you see garbled or repetitive output." >&2
fi

# Settings below must reach the SERVER process, not the client.
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE="$KV_CACHE_TYPE"
export OLLAMA_CONTEXT_LENGTH="$NUM_CTX"
export OLLAMA_HOST="$HOST"
export OLLAMA_MODELS="$MODEL_STORE"
# Never unload on idle: an unload mid-session forces a full re-prefill of the
# whole conversation on the next request (minutes at 100K+ tokens of context).
export OLLAMA_KEEP_ALIVE=-1
# One request stream (Claude Code) gets the whole context window, regardless of
# what this Ollama version's parallel-request default happens to be.
export OLLAMA_NUM_PARALLEL=1

echo ">> Model: $MODEL (store: $MODEL_STORE)"
echo ">> Context: $NUM_CTX | KV cache: $KV_CACHE_TYPE | temp band: [$TEMP_FLOOR, $TEMP_CEIL]"

# --- 0. GPU must be healthy before we do anything -----------------------------
if ! nvidia-smi >/dev/null 2>&1; then
  echo "!! GPU unavailable (nvidia-smi failed). Reboot / reset the driver first." >&2
  exit 1
fi

# --- 1. stop any running server (exact name; never pkill -f, it self-matches) -
if systemctl is-active --quiet ollama 2>/dev/null; then sudo systemctl stop ollama; fi
pkill -x ollama 2>/dev/null || true
pkill -x llama-server 2>/dev/null || true
pkill -f "$TEMP_PROXY" 2>/dev/null || true   # stale temperature proxy from a prior run
sleep 2

# --- 2. start our server with the settings above ------------------------------
echo ">> Starting ollama serve..."
nohup ollama serve >/tmp/ollama-ornith.log 2>&1 &
disown
until curl -sf "http://${HOST}/api/version" >/dev/null 2>&1; do sleep 0.5; done

# --- 3. preload and VERIFY it's fully on the GPU before launching Claude Code --
echo ">> Preloading (allocates the full KV cache)..."
if ! curl -sf "http://${HOST}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false}" >/dev/null; then
  echo "!! Preload failed for model '$MODEL' (server returned an error)." >&2
  echo "!! Most likely the model isn't in the store the server is using." >&2
  echo "!!   store in use: ${OLLAMA_MODELS}" >&2
  echo "!! Check 'ollama list', or 'ollama pull $MODEL'. See /tmp/ollama-ornith.log for details." >&2
  exit 1
fi

ollama ps
SPILL="$(curl -sf "http://${HOST}/api/ps" | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("models", []):
    size, vram = m.get("size", 0), m.get("size_vram", 0)
    if vram < size:
        gib = 2**30
        print(f"{m.get(\"name\")}: {(size - vram) / gib:.1f} GiB on CPU "
              f"of {size / gib:.1f} GiB total")
')"
if [[ -n "$SPILL" ]]; then
  echo "!! $NUM_CTX tokens spilled to CPU — too big for 16 GB VRAM:" >&2
  echo "!!   $SPILL" >&2
  echo "!! Unloading and aborting. Re-run and pick a smaller context / more compressed KV cache." >&2
  ollama stop "$MODEL" 2>/dev/null || true
  exit 1
fi
echo ">> Fully on GPU. Launching Claude Code..."

# --- 3b. start the temperature-clamping proxy and point Claude Code at it ------
# The proxy transparently forwards to the real server but clamps temperature
# into the model's band, caps top_p, and strips the DISALLOWED_TOOLS schemas
# out of every request. We only repoint OLLAMA_HOST for the launch step below.
PROXY_PORT="${PROXY_HOST##*:}"
STRIP_TOOLS="$(IFS=,; echo "${DISALLOWED_TOOLS[*]}")"
if [[ -f "$TEMP_PROXY" ]]; then
  echo ">> Starting temperature proxy (:$PROXY_PORT -> $HOST, temp -> [$TEMP_FLOOR, $TEMP_CEIL], strip: $STRIP_TOOLS)..."
  nohup python3 "$TEMP_PROXY" "$PROXY_PORT" "$HOST" "$TEMP_FLOOR" "$TEMP_CEIL" \
    "$TOP_P_CEIL" "$STRIP_TOOLS" >/tmp/ornith-temp-proxy.log 2>&1 &
  disown
  until curl -sf "http://${PROXY_HOST}/api/version" >/dev/null 2>&1; do sleep 0.2; done
  export OLLAMA_HOST="$PROXY_HOST"
else
  echo "!! $TEMP_PROXY not found — launching at the model's default temperature." >&2
fi

# Kill the proxy when Claude Code exits. The ollama server is left running on
# purpose (the loaded model stays warm for the next session).
cleanup() { pkill -f "$TEMP_PROXY" 2>/dev/null || true; }
trap cleanup EXIT

# --- 4. hand off to Claude Code wired to the local model ----------------------
# Append the extra editing rules to the system prompt so the local model is
# reminded how to use the Edit tool (exact byte-for-byte old_string matching)
# and to compile/test everything it writes.
if [[ -f "$EDIT_RULES" ]]; then
  echo ">> Appending editing rules from $EDIT_RULES"
  echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${DISALLOWED_TOOLS[*]}"
  # Args after `--` are forwarded to Claude Code itself (ollama launch passes
  # them through). The flags are NOT `ollama launch` flags, so they go here.
  ollama launch claude --model "$MODEL" -y -- \
    --settings "$SUBAGENT_SETTINGS" \
    --append-system-prompt "$(cat "$EDIT_RULES")" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
else
  echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
  echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${DISALLOWED_TOOLS[*]}"
  ollama launch claude --model "$MODEL" -y -- \
    --settings "$SUBAGENT_SETTINGS" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
fi

echo ">> Session over. Temp proxy stopped; ollama server left running (model stays warm)."
echo ">> To restore the system Ollama service: sudo systemctl start ollama"
