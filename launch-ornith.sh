#!/usr/bin/env bash
#
# launch-ornith.sh — launch Claude Code wired to the local Ornith model,
#                    with an fp16 KV cache and a large context window.
#
# VERIFIED FIT TABLE — measured on this RTX 5060 Ti (16 GB) via the preload
# guard (ollama ps PROCESSOR column). Numbers are total reported VRAM use.
#
#   ornith:latest (~5.6 GB weights) — FITS EVERYTHING, 100% GPU:
#     ctx     q4_0     q8_0     f16
#     32K     5.7 GB   6.0 GB   6.4 GB
#     64K     6.1 GB   6.6 GB   7.4 GB
#     128K    7.0 GB   8.1 GB   9.6 GB
#     256K    8.9 GB   11 GB    14 GB     <- 256K/f16 is the heaviest, still fits
#
#   gemma4:latest (8B, Q4_K_M) — FITS EVERYTHING, 100% GPU. Max context is 128K
#     (a 256K choice is silently clamped to 131072). Peak ~6.5 GB VRAM at
#     128K/f16 — comfortable headroom at every context/KV setting.
#
# (qwen3-coder:30b was dropped: ~18 GB weights exceed 16 GB VRAM, so it spills
#  to CPU at every context/KV setting and runs CPU-bound. Not offered here.)
#
# On launch you pick the context window (32K/64K/128K/256K) and the KV cache
# precision (fp16/q8_0/Q4_0). The preload guard below aborts on a CPU spill;
# if it triggers, re-run with a smaller context and/or more compressed KV cache.
#
set -euo pipefail

HOST="127.0.0.1:11434"
PROXY_HOST="127.0.0.1:11435"   # temperature-clamping proxy in front of HOST
# Claude Code sends temp=1.0; the proxy clamps it into a band. A single low value
# (the old 0.4) keeps tool calls clean but makes a 9B model loop; a band keeps
# enough entropy to escape agentic repetition loops. See ornith-temp-proxy.py.
TEMP_FLOOR="0.55"
TEMP_CEIL="0.70"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/ornith-editing-rules.md"
TEMP_PROXY="$SCRIPT_DIR/ornith-temp-proxy.py"

# A 9B-class model emits malformed/hallucinated tool calls when too many tools
# are in context. Disallow the ones a local model rarely uses well: subagents
# (Task/Agent), web tools, and notebook editing. They never load, so they can't
# be picked wrongly. Tune this list freely — fewer tools = fewer bad calls.
DISALLOWED_TOOLS=(Task Agent Workflow WebFetch WebSearch NotebookEdit)

# --- interactive selection -----------------------------------------------------
echo "Select model:   (all fit any ctx/KV on 16 GB; see fit table in header)"
echo "  1) ornith:latest         5.6 GB weights, full 256K context, best for agents"
echo "  2) gemma4:latest         8B Q4_K_M, max 128K context; avoid agent/subagent use"
echo "  3) qwen2.5-coder:14b      strong coder, native 32K context (capped at 32K)"
read -rp "Model [1-3]: " MODEL_CHOICE
MODEL_STORE=/var/lib/ollama/models   # all live in the system store
case "$MODEL_CHOICE" in
  1) MODEL="ornith:latest" ;;
  2) MODEL="gemma4:latest" ;;
  3) MODEL="qwen2.5-coder:14b" ;;
  *) echo "!! Invalid model choice: $MODEL_CHOICE" >&2; exit 1 ;;
esac

echo "Select context window:   (all fit on 16 GB; gemma4 caps at 128K)"
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

# qwen2.5-coder is trained for 32K; going beyond needs YaRN (not wired here) and
# degrades quality, so cap it at its native context.
if [[ "$MODEL" == "qwen2.5-coder:14b" && "$NUM_CTX" -gt 32768 ]]; then
  echo ">> qwen2.5-coder is a 32K model; capping context at 32768 (was $NUM_CTX)."
  NUM_CTX=32768
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
# Only pin OLLAMA_MODELS when the chosen model lives outside the default store.
if [[ -n "$MODEL_STORE" ]]; then
  export OLLAMA_MODELS="$MODEL_STORE"
fi

echo ">> Model: $MODEL | Context: $NUM_CTX | KV cache: $KV_CACHE_TYPE"

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
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"30m\"}" >/dev/null; then
  echo "!! Preload failed for model '$MODEL' (server returned an error)." >&2
  echo "!! Most likely the model isn't in the store the server is using." >&2
  echo "!!   store in use: ${OLLAMA_MODELS:-$HOME/.ollama/models}" >&2
  echo "!! Check 'ollama list', or 'ollama pull $MODEL'. See /tmp/ollama-ornith.log for details." >&2
  exit 1
fi

ollama ps
PROC="$(ollama ps | awk 'NR==2 {print $4 $5}')"
if echo "$PROC" | grep -qi cpu; then
  echo "!! $NUM_CTX tokens spilled to CPU ($PROC) — too big for 16 GB VRAM." >&2
  echo "!! Unloading and aborting. Re-run and pick a smaller context / more compressed KV cache." >&2
  ollama stop "$MODEL" 2>/dev/null || true
  exit 1
fi
echo ">> Fully on GPU. Launching Claude Code..."

# --- 3b. start the temperature-clamping proxy and point Claude Code at it ------
# Claude Code sends temperature=1.0, which overrides Ornith's preferred sampling
# and makes a 9B model emit far more malformed/hallucinated tool calls. The proxy
# transparently forwards to the real server but clamps temperature into the
# [$TEMP_FLOOR, $TEMP_CEIL] band. We only repoint OLLAMA_HOST for the launch step below.
PROXY_PORT="${PROXY_HOST##*:}"
if [[ -f "$TEMP_PROXY" ]]; then
  echo ">> Starting temperature proxy (:$PROXY_PORT -> $HOST, temp -> [$TEMP_FLOOR, $TEMP_CEIL])..."
  nohup python3 "$TEMP_PROXY" "$PROXY_PORT" "$HOST" "$TEMP_FLOOR" "$TEMP_CEIL" \
    >/tmp/ornith-temp-proxy.log 2>&1 &
  disown
  until curl -sf "http://${PROXY_HOST}/api/version" >/dev/null 2>&1; do sleep 0.2; done
  export OLLAMA_HOST="$PROXY_HOST"
else
  echo "!! $TEMP_PROXY not found — launching at the model's default temperature." >&2
fi

# --- 4. hand off to Claude Code wired to ornith -------------------------------
# Append the extra editing rules to the system prompt so the local model is
# reminded how to use the Edit tool (exact byte-for-byte old_string matching).
if [[ -f "$EDIT_RULES" ]]; then
  echo ">> Appending editing rules from $EDIT_RULES"
  echo ">> Disallowing tools: ${DISALLOWED_TOOLS[*]}"
  # Args after `--` are forwarded to Claude Code itself (ollama launch passes
  # them through). The flags are NOT `ollama launch` flags, so they go here.
  exec ollama launch claude --model "$MODEL" -y -- \
    --append-system-prompt "$(cat "$EDIT_RULES")" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
else
  echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
  echo ">> Disallowing tools: ${DISALLOWED_TOOLS[*]}"
  exec ollama launch claude --model "$MODEL" -y -- \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
fi
