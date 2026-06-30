#!/usr/bin/env bash
#
# launch-aider.sh — launch Aider wired to the local Ornith model.
#
# Sibling of launch-ornith.sh. Same model picker, context/KV-cache guard, and
# GPU-spill abort, but hands off to Aider instead of Claude Code.
#
# Why Aider for a 9B-class model:
#   - Forgiving edit formats (whole-file / unified-diff) instead of byte-exact
#     Edit matching — removes the #1 failure mode for small models, so the
#     ornith-editing-rules.md band-aid is unnecessary here.
#   - Native temperature control (--temperature), so no temp-clamping proxy.
#   - Smaller prompt/tool surface leaves more context window for real work.
#
# See launch-ornith.sh for the measured VRAM fit table; it applies unchanged
# (the model + KV cache live in the same ollama server process).
#
set -euo pipefail

HOST="127.0.0.1:11434"
TARGET_TEMP="0.4"             # a 9B model wants lower than the default temp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/ornith-editing-rules.md"

# --- interactive selection -----------------------------------------------------
echo "Select model:   (all fit any ctx/KV on 16 GB; see fit table in launch-ornith.sh)"
echo "  1) ornith:latest         5.6 GB weights, full 256K context, best for agents"
echo "  2) gemma4:latest         8B Q4_K_M, max 128K context"
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

# Settings below must reach the SERVER process, not the client.
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE="$KV_CACHE_TYPE"
export OLLAMA_CONTEXT_LENGTH="$NUM_CTX"
export OLLAMA_HOST="$HOST"
if [[ -n "$MODEL_STORE" ]]; then
  export OLLAMA_MODELS="$MODEL_STORE"
fi

echo ">> Model: $MODEL | Context: $NUM_CTX | KV cache: $KV_CACHE_TYPE | temp: $TARGET_TEMP"

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

# --- 3. preload and VERIFY it's fully on the GPU before launching Aider --------
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
echo ">> Fully on GPU. Launching Aider..."

# --- 4. hand off to Aider -----------------------------------------------------
# Aider talks to ollama through its OpenAI-compatible endpoint. The litellm
# layer Aider uses needs:
#   - OLLAMA_API_BASE pointing at the ollama server
#   - the model named as ollama_chat/<model> (the _chat variant streams better
#     and respects the chat template)
#   - the context window set explicitly; otherwise litellm defaults to a small
#     window and silently truncates. Mirror our chosen NUM_CTX.
export OLLAMA_API_BASE="http://${HOST}"

# Tell Aider the model's real context size so it doesn't truncate history.
META_FILE="$(mktemp /tmp/aider-ornith-model-meta.XXXX.json)"
cat > "$META_FILE" <<JSON
{
  "ollama_chat/${MODEL}": {
    "max_input_tokens": ${NUM_CTX},
    "max_output_tokens": 8192
  }
}
JSON

# Aider has no --temperature flag; temperature is a per-model setting passed
# through to the API via extra_params in a model-settings YAML.
SETTINGS_FILE="$(mktemp /tmp/aider-ornith-model-settings.XXXX.yml)"
cat > "$SETTINGS_FILE" <<YAML
- name: ollama_chat/${MODEL}
  edit_format: whole
  use_temperature: ${TARGET_TEMP}
  extra_params:
    temperature: ${TARGET_TEMP}
    num_ctx: ${NUM_CTX}
YAML

AIDER_ARGS=(
  --model "ollama_chat/${MODEL}"
  --model-metadata-file "$META_FILE"
  --model-settings-file "$SETTINGS_FILE"
  --no-show-model-warnings
)

# Edit format (whole-file) is set in the model-settings YAML above — the most
# forgiving format for a 9B model. Switch edit_format to "diff" there once the
# model proves it can produce clean unified diffs.

# Reuse the existing editing-rules note as read-only context if present.
if [[ -f "$EDIT_RULES" ]]; then
  echo ">> Adding editing rules from $EDIT_RULES as read-only context"
  AIDER_ARGS+=( --read "$EDIT_RULES" )
fi

if ! command -v aider >/dev/null 2>&1; then
  echo "!! aider not found on PATH. Install with: python3 -m pip install aider-install && aider-install" >&2
  echo "!!   (or: python3 -m pip install aider-chat)" >&2
  exit 1
fi

# Forward any extra args (e.g. files to add to the chat) passed to this script.
exec aider "${AIDER_ARGS[@]}" "$@"
