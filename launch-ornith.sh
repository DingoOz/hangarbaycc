#!/usr/bin/env bash
#
# launch-ornith.sh — launch Claude Code wired to the local Ornith model,
#                    with an fp16 KV cache and a large context window.
#
# VERIFIED on this RTX 5060 Ti (16 GB):
#   64K  fp16 -> 7.4 GB, 100% GPU            (known good)
#   256K fp16 -> fits, 100% GPU              (known good)
# On launch you pick the context window (32K/64K/128K/256K) and the KV cache
# precision (fp16/q8_0/Q4_0). If the guard reports a CPU spill, re-run and
# choose a smaller context and/or a more compressed KV cache.
#
set -euo pipefail

HOST="127.0.0.1:11434"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/ornith-editing-rules.md"

# --- interactive selection -----------------------------------------------------
echo "Select model:"
echo "  1) ornith:latest        [system store: /var/lib/ollama/models]"
echo "  2) qwen3-coder:30b       [default store]"
read -rp "Model [1-2]: " MODEL_CHOICE
# MODEL_STORE: leave empty to use the default OLLAMA_MODELS location.
MODEL_STORE=""
case "$MODEL_CHOICE" in
  1) MODEL="ornith:latest"; MODEL_STORE=/var/lib/ollama/models ;;  # ornith lives in the system store
  2) MODEL="qwen3-coder:30b" ;;
  *) echo "!! Invalid model choice: $MODEL_CHOICE" >&2; exit 1 ;;
esac

echo "Select context window:"
echo "  1) 32K   (32768)"
echo "  2) 64K   (65536)    [known good on 16 GB]"
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
sleep 2

# --- 2. start our server with the settings above ------------------------------
echo ">> Starting ollama serve..."
nohup ollama serve >/tmp/ollama-ornith.log 2>&1 &
disown
until curl -sf "http://${HOST}/api/version" >/dev/null 2>&1; do sleep 0.5; done

# --- 3. preload and VERIFY it's fully on the GPU before launching Claude Code --
echo ">> Preloading (allocates the full KV cache)..."
curl -sf "http://${HOST}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"30m\"}" >/dev/null

ollama ps
PROC="$(ollama ps | awk 'NR==2 {print $4 $5}')"
if echo "$PROC" | grep -qi cpu; then
  echo "!! $NUM_CTX tokens spilled to CPU ($PROC) — too big for 16 GB VRAM." >&2
  echo "!! Unloading and aborting. Re-run and pick a smaller context / more compressed KV cache." >&2
  ollama stop "$MODEL" 2>/dev/null || true
  exit 1
fi
echo ">> Fully on GPU. Launching Claude Code..."

# --- 4. hand off to Claude Code wired to ornith -------------------------------
# Append the extra editing rules to the system prompt so the local model is
# reminded how to use the Edit tool (exact byte-for-byte old_string matching).
if [[ -f "$EDIT_RULES" ]]; then
  echo ">> Appending editing rules from $EDIT_RULES"
  # Args after `--` are forwarded to Claude Code itself (ollama launch passes
  # them through). The flag is NOT an `ollama launch` flag, so it must go here.
  exec ollama launch claude --model "$MODEL" -y -- --append-system-prompt "$(cat "$EDIT_RULES")"
else
  echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
  exec ollama launch claude --model "$MODEL" -y
fi
