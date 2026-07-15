#!/usr/bin/env bash
#
# launch-aider.sh — launch Aider wired to either a local Ollama model or the
#                    LAN meshllm server.
#
# Sibling of hangarbaycc.sh (the HangarBayCC project), but hands off to Aider
# instead of Claude Code. Two backends:
#   - Ollama:   local model picker, context/KV-cache guard, GPU-spill abort
#               (same shape as hangarbaycc.sh).
#   - meshllm:  a remote, always-on, OpenAI-compatible server on the LAN —
#               no local GPU/preload involvement, fixed model/context.
#
# Why Aider (for either backend):
#   - Forgiving edit formats (whole-file / unified-diff) instead of byte-exact
#     Edit matching — removes the #1 failure mode for small/local models, so
#     the hangarbaycc-editing-rules.md band-aid is unnecessary here.
#   - No function/tool-calling required — Aider parses edits out of plain
#     chat text, so it works fine against a backend like meshllm that only
#     advertises "text" capabilities (no tool-calling).
#   - Native temperature control (--temperature-equivalent via extra_params),
#     so no temp-clamping proxy needed.
#
# See hangarbaycc.sh for the measured VRAM fit table (Ollama backend only);
# it applies unchanged (the model + KV cache live in the same ollama server
# process).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/hangarbaycc-editing-rules.md"

# --- backend selection -----------------------------------------------------
echo "Select backend:"
echo "  1) Ollama    (local model — model/context/KV menus, GPU-spill guard)"
echo "  2) meshllm   (LAN mesh-llm server, always-on, fixed config)"
read -rp "Backend [1-2]: " BACKEND_CHOICE
case "$BACKEND_CHOICE" in
  1) BACKEND="ollama" ;;
  2) BACKEND="meshllm" ;;
  *) echo "!! Invalid backend choice: $BACKEND_CHOICE" >&2; exit 1 ;;
esac

if [[ "$BACKEND" == "meshllm" ]]; then
  MESHLLM_HOST="192.168.1.16:9337"
  MESHLLM_BASE="http://${MESHLLM_HOST}/v1"
  MODEL="meshllm/Qwen3-30B-A3B-Q4_K_M-layers"
  # Fixed server-side infra, not client-configurable here. Must match the
  # server's actual advertised config — verify with:
  #   curl -s http://192.168.1.16:9337/v1/models | python3 -m json.tool
  NUM_CTX=40960
  TARGET_TEMP="0.7"   # no prior guidance for this model; easy to tune here
  API_KEY="mesh"      # no auth configured server-side; any value works

  echo ">> Checking meshllm reachability at $MESHLLM_BASE ..."
  if ! curl -sf -m 5 "$MESHLLM_BASE/models" >/dev/null; then
    echo "!! meshllm server unreachable at $MESHLLM_BASE." >&2
    echo "!! No HA/failover — this depends on BOTH ml-server (mesh-llm process)" >&2
    echo "!! and rtx3070 (Docker container) staying up. Check both." >&2
    exit 1
  fi
  echo ">> meshllm reachable. Model: $MODEL | Context: $NUM_CTX | temp: $TARGET_TEMP"
fi

if [[ "$BACKEND" == "ollama" ]]; then
HOST="127.0.0.1:11434"
TARGET_TEMP="0.4"             # a 9B model wants lower than the default temp

# --- interactive selection -----------------------------------------------------
echo "Select model:   (all fit any ctx/KV on 16 GB; see fit table in hangarbaycc.sh)"
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
nohup ollama serve >/tmp/ollama-hangarbaycc.log 2>&1 &
disown
until curl -sf "http://${HOST}/api/version" >/dev/null 2>&1; do sleep 0.5; done

# --- 3. preload and VERIFY it's fully on the GPU before launching Aider --------
echo ">> Preloading (allocates the full KV cache)..."
if ! curl -sf "http://${HOST}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"30m\"}" >/dev/null; then
  echo "!! Preload failed for model '$MODEL' (server returned an error)." >&2
  echo "!! Most likely the model isn't in the store the server is using." >&2
  echo "!!   store in use: ${OLLAMA_MODELS:-$HOME/.ollama/models}" >&2
  echo "!! Check 'ollama list', or 'ollama pull $MODEL'. See /tmp/ollama-hangarbaycc.log for details." >&2
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
fi

# --- 4. hand off to Aider -----------------------------------------------------
# Aider talks to the backend through litellm's OpenAI-compatible layer:
#   - Ollama:  OLLAMA_API_BASE + model named ollama_chat/<model> (the _chat
#     variant streams better and respects the chat template).
#   - meshllm: OPENAI_API_BASE + OPENAI_API_KEY + model named openai/<model>
#     (litellm's generic OpenAI-compatible provider — same shape, different
#     prefix/env vars).
# The context window is set explicitly in both cases; otherwise litellm
# defaults to a small window and silently truncates. Mirrors NUM_CTX above.
if [[ "$BACKEND" == "ollama" ]]; then
  export OLLAMA_API_BASE="http://${HOST}"
  AIDER_MODEL="ollama_chat/${MODEL}"
else
  export OPENAI_API_BASE="$MESHLLM_BASE"
  export OPENAI_API_KEY="$API_KEY"
  AIDER_MODEL="openai/${MODEL}"
fi

# Tell Aider the model's real context size so it doesn't truncate history.
META_FILE="$(mktemp /tmp/aider-model-meta.XXXX.json)"
cat > "$META_FILE" <<JSON
{
  "${AIDER_MODEL}": {
    "max_input_tokens": ${NUM_CTX},
    "max_output_tokens": 8192
  }
}
JSON

# Aider has no --temperature flag; temperature is a per-model setting passed
# through to the API via extra_params in a model-settings YAML. num_ctx is an
# Ollama-specific request param (llama.cpp KV-cache size) — meaningless
# against a generic OpenAI-compatible backend like meshllm, whose context is
# fixed server-side, so it's only included for the Ollama backend.
SETTINGS_FILE="$(mktemp /tmp/aider-model-settings.XXXX.yml)"
if [[ "$BACKEND" == "ollama" ]]; then
  cat > "$SETTINGS_FILE" <<YAML
- name: ${AIDER_MODEL}
  edit_format: whole
  use_temperature: ${TARGET_TEMP}
  extra_params:
    temperature: ${TARGET_TEMP}
    num_ctx: ${NUM_CTX}
YAML
else
  cat > "$SETTINGS_FILE" <<YAML
- name: ${AIDER_MODEL}
  edit_format: whole
  use_temperature: ${TARGET_TEMP}
  extra_params:
    temperature: ${TARGET_TEMP}
YAML
fi

AIDER_ARGS=(
  --model "${AIDER_MODEL}"
  --model-metadata-file "$META_FILE"
  --model-settings-file "$SETTINGS_FILE"
  --no-show-model-warnings
)

# Edit format (whole-file) is set in the model-settings YAML above — the most
# forgiving format, and kept for meshllm too as a safe first cut. meshllm's
# Qwen3-30B is materially stronger than ornith, so "diff" is worth trying
# there once whole-file edits prove reliable in practice.

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
