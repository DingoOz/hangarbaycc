#!/usr/bin/env bash
#
# hangarbaycc.sh — HangarBayCC: launch Claude Code wired to a local Ollama
#                   model, or to meshllm (a remote OpenAI-compatible LAN
#                   server), with a chosen KV cache precision and context
#                   window (Ollama only — meshllm's config is fixed).
#
# Usage:
#   ./hangarbaycc.sh                  run everything on this machine (default)
#   ./hangarbaycc.sh --remote HOST    run the Ollama server on HOST over SSH;
#                                     the proxy and Claude Code stay on THIS
#                                     machine, wired to HOST's Ollama over the
#                                     LAN. HOST is anything `ssh HOST` accepts
#                                     (hostname, IP, or ssh-config alias).
#   HANGARBAY_REMOTE=HOST ./hangarbaycc.sh   same, via env var instead of a flag.
#
# On launch you first pick a backend — Ollama (local model, this machine or
# --remote) or meshllm (an always-on OpenAI-compatible LLM server on the LAN,
# reached through a translation proxy since Claude Code only speaks the
# Anthropic Messages protocol). --remote/--dictate only apply to the Ollama
# backend; meshllm is a fixed endpoint with no local GPU/server involvement.
#
# If neither the flag nor the env var is given, and Ollama is picked, an
# interactive menu asks whether to run locally or against a remote host (the
# remote default is 'ml-server').
#
# Remote mode requires: `ssh HOST` already works (key-based auth strongly
# preferred — several separate ssh calls happen per launch); HOST has the GPU,
# ollama, and the model store; HOST's Ollama binds 0.0.0.0:11434, so it is
# reachable by anything on the LAN for as long as the session runs — fine on a
# trusted home LAN, not something to expose beyond it. If HOST's firewall
# blocks port 11434 from your subnet, the server-wait step below will time out
# with a hint.
#
# VERIFIED FIT TABLE — measured on an RTX 5060 Ti (16 GB) via the preload
# guard (/api/ps size_vram vs size). Numbers are total reported VRAM use.
# Applies to whichever machine actually hosts the GPU (local or --remote).
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
# meshllm backend: a fixed remote model (currently
# meshllm/Qwen3-30B-A3B-Q4_K_M-layers at 192.168.1.16:9337, 40960 native
# context) reached through hangarbaycc-proxy.py's protocol=openai translation
# mode, which converts Claude Code's Anthropic Messages requests to OpenAI
# Chat Completions and back (including streaming). No HA — depends on both
# the mesh-llm process and its GPU host's Docker container staying up.
#
# OPTIONAL: voice dictation (--dictate / HANGARBAY_DICTATE=1, Ollama remote
# mode only). Starts whisper-server (whisper.cpp, CUDA) on the GPU host's
# spare VRAM AFTER the model above is confirmed 100% on GPU (~0.6 GB for the
# default small.en q8_0 model — e.g. gpt-oss:20b @128K/q8_0 leaves ~3.5 GB of
# headroom per the table above). One-time setup: ./setup-whisper-server.sh
# [HOST]. Then bind hangarbay-dictate.sh to a hotkey to talk into the Claude
# Code prompt. See README.md "Voice dictation" for details.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: hangarbaycc.sh [-r|--remote HOST] [-d|--dictate]

  -r, --remote HOST   Run the Ollama server on HOST over SSH instead of this
                       machine. The proxy and Claude Code still run here.
                       Ollama backend only.
  -d, --dictate        Start voice dictation (whisper-server on the GPU host).
                       Ollama remote mode only; see README.md "Voice dictation".
  -h, --help           Show this help.

HOST may also come from the HANGARBAY_REMOTE environment variable; the flag
takes precedence if both are given. If neither is set, an interactive menu asks
whether to run locally or against a remote host (default: ml-server).

--dictate may also come from HANGARBAY_DICTATE=1; the flag takes precedence.
If neither is set and this is a remote, interactive run, a menu prompt asks
(default: no).
USAGE
}

REMOTE=""
DICTATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--remote) REMOTE="${2:?--remote requires a HOST argument}"; shift 2 ;;
    --remote=*)  REMOTE="${1#*=}"; shift ;;
    -d|--dictate) DICTATE="1"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "!! Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
REMOTE="${REMOTE:-${HANGARBAY_REMOTE:-}}"
DICTATE="${DICTATE:-${HANGARBAY_DICTATE:-}}"

# --- backend selection ----------------------------------------------------
echo "Select backend:"
echo "  1) Ollama    (local model — this machine or --remote; model/context/KV menus)"
echo "  2) meshllm   (LAN mesh-llm server, always-on, fixed config)"
read -rp "Backend [1-2]: " BACKEND_CHOICE
case "$BACKEND_CHOICE" in
  1) BACKEND="ollama" ;;
  2) BACKEND="meshllm" ;;
  *) echo "!! Invalid backend choice: $BACKEND_CHOICE" >&2; exit 1 ;;
esac

# --- shared infra (both backends) ------------------------------------------
PROXY_HOST="127.0.0.1:11435"   # translation/temperature-clamping proxy; always local
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDIT_RULES="$SCRIPT_DIR/hangarbaycc-editing-rules.md"
TEMP_PROXY="$SCRIPT_DIR/hangarbaycc-proxy.py"

# Small models emit malformed/hallucinated tool calls when too many tools are
# in context. The proxy STRIPS these from the `tools` schema on every
# /v1/messages request, so the model never sees them at all — no hallucinated
# calls, and several thousand tokens of schema freed for actual code context.
# --disallowedTools is kept as a backstop (it auto-denies at execution time in
# case a call slips through, e.g. when the proxy isn't running).
# 'Task' is kept here only for older builds; the live subagent tool is 'Agent'.
DISALLOWED_TOOLS=(Task Agent Workflow WebFetch WebSearch NotebookEdit)

# Poll a URL until it answers or we give up, instead of looping forever (a
# blocked port or a server that never starts would otherwise hang the
# launcher indefinitely). mode="soft" returns 1 on timeout instead of exiting
# — used for optional features (dictation) that should degrade, not abort.
wait_for_http() {
  local url="$1" hint="${2:-}" mode="${3:-hard}" tries=60
  until curl -sf "$url" >/dev/null 2>&1; do
    tries=$((tries - 1))
    if [[ $tries -le 0 ]]; then
      echo "!! Timed out waiting for ${url} to answer." >&2
      [[ -n "$hint" ]] && echo "!! $hint" >&2
      [[ "$mode" == "soft" ]] && return 1
      exit 1
    fi
    sleep 0.5
  done
}

# --- helpers for running a command on a target host (local, or over SSH) ----
# Shared by the Ollama --remote backend (main model host) and the meshllm
# backend's classifier host — each passes its own host as the first arg, "" for
# local. Simple one-shot command, no pty (fine for anything that doesn't need a
# terminal, e.g. a health check).
remote_exec() {
  local host="$1" cmd="$2"
  if [[ -n "$host" ]]; then ssh "$host" "$cmd"; else bash -c "$cmd"; fi
}
# Same, but allocates a pty — needed for an interactive sudo password prompt.
remote_exec_tty() {
  local host="$1" cmd="$2"
  if [[ -n "$host" ]]; then ssh -t "$host" "$cmd"; else bash -c "$cmd"; fi
}
# Multi-line script fed over stdin instead of as a quoted argument — avoids
# quoting hell when a script mixes values already known here (interpolated
# before sending) with variables meant to be evaluated on the target host
# (escaped as \$foo so they survive to the far end literally).
remote_script() {
  local host="$1"
  if [[ -n "$host" ]]; then ssh "$host" bash -s; else bash -s; fi
}

# `ollama launch claude` sets CLAUDE_CODE_SUBAGENT_MODEL to EMPTY. Claude's logic
# is: if the var is set and != "inherit", use it; otherwise fall back to a default
# 'sonnet' alias — which a local/meshllm backend cannot serve, so every spawned
# agent panel errors with "There's an issue with the selected model". Forcing
# "inherit" makes any subagent reuse the running model instead, so a stray
# Agent call is harmless rather than an error.
#
# Claude Code doesn't know this model, so it assumes its 200K default context
# window: /context shows 200k regardless of what we actually configured, and —
# more importantly — auto-compaction would never trigger before the real
# server-side limit, at which point the backend silently context-shifts (drops
# the oldest messages, including our appended editing rules) instead of Claude
# Code compacting on purpose. CLAUDE_CODE_AUTO_COMPACT_WINDOW pins the
# effective/auto-compact window to NUM_CTX, so compaction fires at the real
# limit; /context then shows "Auto-compact window: <NUM_CTX> tokens (from
# CLAUDE_CODE_AUTO_COMPACT_WINDOW)". The headline total still reads 200k —
# that's cosmetic only, hardcoded per model ID with no override that doesn't
# also disable auto-compaction entirely (rejected: worse than a wrong number).
#
# Both settings passed via --settings (scoped to THIS launch only; your normal
# cloud Claude is untouched). settings.env beats process env. Called after
# NUM_CTX is finalized in each backend branch below, so it reflects the actual
# server context rather than the raw menu choice.
build_launch_settings() {
  printf '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"inherit","CLAUDE_CODE_AUTO_COMPACT_WINDOW":"%s"}}' "$NUM_CTX"
}

# --- meshllm backend --------------------------------------------------------
if [[ "$BACKEND" == "meshllm" ]]; then
  [[ -n "$REMOTE" || -n "$DICTATE" ]] && \
    echo "!! --remote/--dictate don't apply to the meshllm backend (fixed LAN endpoint); ignoring." >&2

  MESHLLM_HOST="192.168.1.16:9337"
  MESHLLM_BASE="http://${MESHLLM_HOST}/v1"
  MODEL="meshllm/Qwen3-30B-A3B-Q4_K_M-layers"
  NUM_CTX=40960
  TEMP_FLOOR=0.7; TEMP_CEIL=0.85; TOP_P_CEIL=1.0   # no established guidance yet; easy to tune
  PROXY_PORT="${PROXY_HOST##*:}"

  echo ">> Checking meshllm reachability at $MESHLLM_BASE ..."
  if ! curl -sf -m 5 "$MESHLLM_BASE/models" >/dev/null; then
    echo "!! meshllm server unreachable at $MESHLLM_BASE." >&2
    echo "!! No HA/failover — depends on BOTH ml-server (mesh-llm process) and" >&2
    echo "!! rtx3070 (Docker container) staying up. Check both." >&2
    exit 1
  fi

  LAUNCH_SETTINGS="$(build_launch_settings)"

  # Claude Code's "auto mode" runs a separate safety-classifier call before
  # executing tools like Bash, to judge whether the command is safe to
  # auto-approve. That call always requests "claude-sonnet-5" (Claude Code's
  # hardcoded default) — setting CLAUDE_CODE_AUTO_MODE_MODEL as a plain env
  # var does NOT change this (confirmed by live-capturing the request body).
  # Against a real Anthropic backend that's fine; against meshllm it's a
  # request for a model that doesn't exist there, AND meshllm's own 10-20s+
  # per-call latency (it burns hidden reasoning tokens even on trivial
  # replies) blows past whatever short timeout the classifier expects anyway
  # — so Claude Code can't safety-check (and therefore can't run) Bash at
  # all. The proxy (see hangarbaycc-proxy.py's CLASSIFIER_* args) detects any
  # request naming "claude-sonnet-5", rewrites it to CLASSIFIER_MODEL, trims
  # its context (it grows with the conversation just like the main turn's
  # does), and routes it to Ollama's NATIVE /api/chat on the classifier host
  # (see below). llama3.2:3b (~2 GB) balances judgment quality against
  # prefill speed — live-tested: correctly says "No" to `rm -rf /` (a 0.5B
  # model wrongly said it was safe; a 14B model was fine on judgment but too
  # slow once its request grew past a few KB on CPU — a bigger model only
  # makes the latency problem worse there, not better). Best-effort: if the
  # classifier host isn't reachable/set up or the pull fails, warn and
  # continue without a classifier override rather than aborting the whole
  # session (auto-mode Bash/Edit/Write checks may be slow/unreliable, but
  # read-only work still functions).
  #
  # keep_alive=-1 (indefinite), not a bounded duration: Ollama refreshes
  # keep_alive on every request, so this preload's setting only matters until
  # the FIRST real classifier call goes through the proxy — after that,
  # hangarbaycc-proxy.py's own to_ollama_native_request() sets it on every
  # call, which is what actually keeps it loaded for the session. Both need
  # to agree, or the model unloads between the preload and first real use.
  # llama3.2:3b's ~2 GB footprint makes squatting on the classifier host's
  # RAM/VRAM for the session's duration a fine tradeoff (unlike the much
  # larger 14B classifier model tried earlier, which used a bounded 30m
  # specifically to avoid this).
  #
  # Runs on gtx1070, a dedicated GPU host (~8 GB, nothing else loaded) —
  # NOT ml-server, whose GPU is already ~full with mesh-llm's own layers.
  # Being dedicated, the classifier can use the GPU here (CLASSIFIER_NUM_GPU
  # below) instead of the CPU-forced fallback ml-server needed. Unlike
  # ml-server (an always-on box we just reach over the LAN), gtx1070 isn't
  # assumed to be running Ollama already, so ensure_classifier_server below
  # installs it on first use and (re)starts `ollama serve` bound to
  # 0.0.0.0:11434 each launch.
  CLASSIFIER_MODEL="llama3.2:3b"
  CLASSIFIER_SSH_HOST="gtx1070"
  CLASSIFIER_HOST="${CLASSIFIER_SSH_HOST}:11434"
  CLASSIFIER_NUM_GPU=-1   # -1 = let Ollama use the GPU (dedicated host, no other model resident)

  ensure_classifier_server() {
    if curl -sf -m 5 "http://${CLASSIFIER_HOST}/api/version" >/dev/null; then
      return 0
    fi
    echo ">> Classifier host ${CLASSIFIER_HOST} not answering — bringing up Ollama on ${CLASSIFIER_SSH_HOST} over SSH..."
    if ! ssh -o ConnectTimeout=5 "$CLASSIFIER_SSH_HOST" true; then
      echo "!! Could not reach '$CLASSIFIER_SSH_HOST' over SSH." >&2
      return 1
    fi
    if ! ssh "$CLASSIFIER_SSH_HOST" 'command -v ollama' >/dev/null 2>&1; then
      echo ">> Ollama not found on ${CLASSIFIER_SSH_HOST} — installing (official installer, needs sudo)..."
      if ! ssh -t "$CLASSIFIER_SSH_HOST" 'curl -fsSL https://ollama.com/install.sh | sudo sh'; then
        echo "!! Ollama install failed on ${CLASSIFIER_SSH_HOST}." >&2
        return 1
      fi
    fi
    echo ">> Starting ollama serve on ${CLASSIFIER_SSH_HOST} (binds 0.0.0.0:11434)..."
    # The installer starts its own systemd-managed instance bound to
    # 127.0.0.1 (not LAN-reachable) — stop that (sudo, hence _tty for the
    # password prompt) and start our own bound to every interface instead,
    # same pattern as the main Ollama --remote backend below.
    remote_exec_tty "$CLASSIFIER_SSH_HOST" 'if systemctl is-active --quiet ollama 2>/dev/null; then sudo systemctl stop ollama; fi'
    remote_script "$CLASSIFIER_SSH_HOST" <<'EOF'
pkill -x ollama 2>/dev/null || true
sleep 2
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_KEEP_ALIVE=-1 setsid nohup ollama serve >/tmp/ollama-classifier.log 2>&1 </dev/null &
disown
EOF
    wait_for_http "http://${CLASSIFIER_HOST}/api/version" \
      "Check /tmp/ollama-classifier.log on ${CLASSIFIER_SSH_HOST}, and that its firewall allows port 11434 from this LAN." soft
  }

  if ! ensure_classifier_server; then
    echo "!! Continuing without a classifier override (auto-mode Bash/Edit/Write checks may be slow/unreliable)." >&2
    CLASSIFIER_MODEL=""
  fi

  if [[ -n "$CLASSIFIER_MODEL" ]]; then
    echo ">> Pulling classifier model $CLASSIFIER_MODEL on ${CLASSIFIER_HOST} (no-op if already present)..."
    if OLLAMA_HOST="$CLASSIFIER_HOST" ollama pull "$CLASSIFIER_MODEL" \
        && curl -sf "http://${CLASSIFIER_HOST}/api/chat" \
             -d "{\"model\":\"${CLASSIFIER_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false,\"keep_alive\":-1,\"options\":{\"num_gpu\":${CLASSIFIER_NUM_GPU},\"num_ctx\":32768}}" >/dev/null; then
      echo ">> Classifier ready: $CLASSIFIER_MODEL on ${CLASSIFIER_HOST} (GPU)"
    else
      echo "!! Could not pull/preload $CLASSIFIER_MODEL on ${CLASSIFIER_HOST} — continuing without a" >&2
      echo "!! classifier override (auto-mode Bash/Edit/Write checks may be slow/unreliable)." >&2
      CLASSIFIER_MODEL=""
    fi
  fi

  # meshllm's 40960 context is much tighter than what a full Claude Code tool
  # surface needs — a live test measured ~57KB (~14K tokens) of tool schemas
  # alone beyond the base DISALLOWED_TOOLS strip list, pushing a single empty
  # turn's request to ~52K tokens and getting rejected outright ("no
  # context-compatible target ... can fit approximately 52194 tokens"). These
  # extra tools (background task/cron/worktree/monitoring/messaging — not
  # needed for basic file-editing coding work) are stripped ADDITIONALLY here,
  # on top of the base list, without changing DISALLOWED_TOOLS itself (that
  # array is shared with the Ollama backend's --disallowedTools flag below,
  # which shouldn't change). Stripping a tool name that isn't actually present
  # in a given session's tools array is a harmless no-op.
  MESHLLM_STRIP_TOOLS=(
    "${DISALLOWED_TOOLS[@]}"
    CronCreate CronDelete CronList DesignSync EnterWorktree ExitWorktree
    Monitor PushNotification ReportFindings ScheduleWakeup SendMessage Skill
    TaskCreate TaskGet TaskList TaskOutput TaskStop TaskUpdate
  )

  pkill -f "$TEMP_PROXY" 2>/dev/null || true   # stale proxy from a prior run
  STRIP_TOOLS="$(IFS=,; echo "${MESHLLM_STRIP_TOOLS[*]}")"
  echo ">> Starting translation proxy (:$PROXY_PORT -> $MESHLLM_HOST, protocol=openai${CLASSIFIER_MODEL:+, classifier=$CLASSIFIER_MODEL@$CLASSIFIER_HOST})..."
  nohup python3 "$TEMP_PROXY" "$PROXY_PORT" "$MESHLLM_HOST" "$TEMP_FLOOR" "$TEMP_CEIL" \
    "$TOP_P_CEIL" "$STRIP_TOOLS" "openai" "$CLASSIFIER_MODEL" "$CLASSIFIER_HOST" \
    "claude-sonnet-5" "$CLASSIFIER_NUM_GPU" \
    >/tmp/hangarbaycc-proxy.log 2>&1 &
  disown
  wait_for_http "http://${PROXY_HOST}/v1/models" "Check /tmp/hangarbaycc-proxy.log"

  # Kill the proxy when Claude Code exits.
  cleanup() { pkill -f "$TEMP_PROXY" 2>/dev/null || true; }
  trap cleanup EXIT

  export ANTHROPIC_BASE_URL="http://${PROXY_HOST}"
  export ANTHROPIC_MODEL="$MODEL"
  export ANTHROPIC_AUTH_TOKEN="mesh"   # proxy doesn't validate this; claude just needs *a* value
  # NOT setting CLAUDE_CODE_AUTO_MODE_MODEL here — confirmed to have no effect
  # as a plain env var (see the classifier comment above). The proxy handles
  # classifier routing by request content instead.

  echo ">> Backend: meshllm | Model: $MODEL | Context: $NUM_CTX | temp band: [$TEMP_FLOOR, $TEMP_CEIL]"
  echo ">> Auto-compact window: $NUM_CTX (matches server context; /context headline still shows 200k — cosmetic)"

  # No `ollama launch claude` here — that subcommand tries to pull MODEL from
  # the Ollama registry and fails outright for a non-Ollama model name. claude
  # itself honours ANTHROPIC_BASE_URL/ANTHROPIC_MODEL/ANTHROPIC_AUTH_TOKEN
  # directly, so we call it straight (NOT via `exec` — the script must stay
  # alive after Claude Code exits so the `trap cleanup EXIT` above actually
  # runs and stops the proxy; `exec` would replace this shell entirely and
  # skip trap handling).
  if [[ -f "$EDIT_RULES" ]]; then
    echo ">> Appending editing rules from $EDIT_RULES"
    echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${MESHLLM_STRIP_TOOLS[*]}"
    claude --settings "$LAUNCH_SETTINGS" \
      --append-system-prompt "$(cat "$EDIT_RULES")" \
      --disallowedTools "${MESHLLM_STRIP_TOOLS[@]}"
  else
    echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
    echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${MESHLLM_STRIP_TOOLS[*]}"
    claude --settings "$LAUNCH_SETTINGS" --disallowedTools "${MESHLLM_STRIP_TOOLS[@]}"
  fi

  echo ">> Session over. Translation proxy stopped. meshllm is always-on — nothing to leave warm here."
  exit 0
fi

# --- Ollama backend ----------------------------------------------------------
# If no host was given via flag or env var, offer an interactive choice between
# running everything locally or targeting a remote Ollama server. A flag/env var
# takes precedence, so this is skipped when either was supplied; it's also
# skipped when stdin isn't a terminal (non-interactive/CI use), where we can't
# prompt — that falls through to local mode.
DEFAULT_REMOTE="ml-server"
if [[ -z "$REMOTE" && -t 0 ]]; then
  echo "Select Ollama server location:"
  echo "  1) Local        run the Ollama server on this machine"
  echo "  2) Remote host  run it on another machine over SSH (default: $DEFAULT_REMOTE)"
  read -rp "Server [1-2, default 1]: " SERVER_CHOICE
  case "${SERVER_CHOICE:-1}" in
    1) REMOTE="" ;;
    2) read -rp "Remote host [$DEFAULT_REMOTE]: " REMOTE_INPUT
       REMOTE="${REMOTE_INPUT:-$DEFAULT_REMOTE}" ;;
    *) echo "!! Invalid server choice: $SERVER_CHOICE" >&2; exit 1 ;;
  esac
fi

SERVER_LABEL="${REMOTE:-local}"

if [[ -n "$REMOTE" ]]; then
  echo ">> Remote mode: Ollama server on '$REMOTE'; proxy + Claude Code stay here."
  if ! ssh -o ConnectTimeout=5 "$REMOTE" true; then
    echo "!! Could not reach '$REMOTE' over SSH." >&2
    echo "!! Check the host is up, 'ssh $REMOTE' works by hand, and (ideally)" >&2
    echo "!! key-based auth is set up (ssh-copy-id $REMOTE) — several separate" >&2
    echo "!! ssh calls happen per launch, which is painful with password auth." >&2
    exit 1
  fi
fi

# SERVER_BIND is what Ollama binds on the server; API_HOST is where the client
# (this machine) reaches it. Same address in local mode; in remote mode the
# server binds every interface (0.0.0.0) so the LAN can reach it, and the
# client talks to it at $REMOTE's address.
if [[ -n "$REMOTE" ]]; then
  SERVER_BIND="0.0.0.0:11434"
  API_HOST="${REMOTE}:11434"
else
  SERVER_BIND="127.0.0.1:11434"
  API_HOST="127.0.0.1:11434"
fi

# Voice dictation (optional, remote mode only): whisper-server binds every
# interface on the GPU host (same posture as Ollama's SERVER_BIND above), the
# client (this machine) reaches it directly — no proxy involved, since it
# never touches Claude Code's request path.
WHISPER_PORT=11436
if [[ -n "$REMOTE" ]]; then
  WHISPER_BIND="0.0.0.0:${WHISPER_PORT}"
  WHISPER_HOST="${REMOTE}:${WHISPER_PORT}"
else
  WHISPER_BIND="127.0.0.1:${WHISPER_PORT}"
  WHISPER_HOST="127.0.0.1:${WHISPER_PORT}"
fi
WHISPER_DIR='$HOME/whisper.cpp'   # single-quoted: expanded on the TARGET host
WHISPER_MODEL="${WHISPER_MODEL:-ggml-small.en-q8_0.bin}"
WHISPER_MIN_FREE_MIB=1000
WHISPER_ENDPOINT_FILE="${XDG_RUNTIME_DIR:-/tmp}/hangarbay-whisper-endpoint"

# --- interactive selection -----------------------------------------------------
# Each model carries its own max context and sampling band. Claude Code sends
# temp=1.0 on every request; the proxy clamps it into [TEMP_FLOOR, TEMP_CEIL].
# A single low value keeps tool calls clean but makes a small model loop; a band
# keeps enough entropy to escape agentic repetition loops. gpt-oss is the
# exception: its recommended sampling is temp 1.0 / top_p 1.0, but 1.0 produced
# imprecise Edit old_strings in long sessions (2026-07-11), so it is pinned at
# the band floor 0.90 — the low end of its recommended range.
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
  4) MODEL="gpt-oss:20b"       MAX_CTX=131072 TEMP_FLOOR=0.90 TEMP_CEIL=0.90 TOP_P_CEIL=1.00 ;;
  *) echo "!! Invalid model choice: $MODEL_CHOICE" >&2; exit 1 ;;
esac

# Models live in either the system store or the user store on the TARGET host;
# Ollama can only use one at a time, so point OLLAMA_MODELS at whichever store
# has the chosen model there.
MODEL_STORE="$(remote_script "$REMOTE" <<EOF
for store in /var/lib/ollama/models "\$HOME/.ollama/models"; do
  manifest="\$store/manifests/registry.ollama.ai/library/${MODEL%%:*}/${MODEL##*:}"
  if [[ -f "\$manifest" ]]; then echo "\$store"; break; fi
done
EOF
)"
if [[ -z "$MODEL_STORE" ]]; then
  echo "!! Model '$MODEL' not found in /var/lib/ollama/models or ~/.ollama/models on ${SERVER_LABEL}." >&2
  echo "!! Pull it there first ('ollama pull $MODEL') — or, if a pull is in progress," >&2
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

# NUM_CTX is now final — build the Claude Code launch settings against it.
LAUNCH_SETTINGS="$(build_launch_settings)"

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

# Dictation only makes sense in remote mode (the laptop has no spare VRAM);
# only ask if it wasn't already decided via flag/env, and only interactively.
if [[ -z "$DICTATE" && -n "$REMOTE" && -t 0 ]]; then
  read -rp "Enable voice dictation (whisper-server on ${REMOTE}) [y/N]: " DICTATE_CHOICE
  case "${DICTATE_CHOICE:-n}" in
    y|Y) DICTATE="1" ;;
    *)   DICTATE="" ;;
  esac
fi
if [[ -n "$DICTATE" && -z "$REMOTE" ]]; then
  echo ">> Dictation requires --remote (the local machine has no spare VRAM budgeted) — ignoring." >&2
  DICTATE=""
fi

# Client-side: only OLLAMA_HOST matters in this shell (ollama ps/stop below,
# and later `ollama launch claude` once repointed at the proxy). The rest are
# server-only knobs, passed inline to the (possibly remote) `ollama serve`
# invocation in step 2 instead of exported here.
export OLLAMA_HOST="$API_HOST"

echo ">> Model: $MODEL (store: $MODEL_STORE on ${SERVER_LABEL})"
echo ">> Context: $NUM_CTX | KV cache: $KV_CACHE_TYPE | temp band: [$TEMP_FLOOR, $TEMP_CEIL]"
echo ">> Auto-compact window: $NUM_CTX (matches server context; /context headline still shows 200k — cosmetic)"

# --- 0. GPU must be healthy before we do anything -----------------------------
if ! remote_exec "$REMOTE" "nvidia-smi >/dev/null 2>&1"; then
  echo "!! GPU unavailable on ${SERVER_LABEL} (nvidia-smi failed)." >&2
  echo "!! Reboot / reset the driver there first." >&2
  exit 1
fi

# --- 1. stop any running server (exact name; never pkill -f, it self-matches) -
echo ">> Stopping any existing server on ${SERVER_LABEL}..."
remote_exec_tty "$REMOTE" 'if systemctl is-active --quiet ollama 2>/dev/null; then sudo systemctl stop ollama; fi'
pkill -f "$TEMP_PROXY" 2>/dev/null || true   # stale temperature proxy from a prior run (always local)

# --- 2. start the server with the settings above ------------------------------
echo ">> Starting ollama serve on ${SERVER_LABEL}..."
remote_script "$REMOTE" <<EOF
pkill -x ollama 2>/dev/null || true
pkill -x llama-server 2>/dev/null || true
pkill -x whisper-server 2>/dev/null || true
sleep 2
OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=$KV_CACHE_TYPE OLLAMA_CONTEXT_LENGTH=$NUM_CTX OLLAMA_HOST=$SERVER_BIND OLLAMA_MODELS=$MODEL_STORE OLLAMA_KEEP_ALIVE=-1 OLLAMA_NUM_PARALLEL=1 setsid nohup ollama serve >/tmp/ollama-hangarbaycc.log 2>&1 </dev/null &
disown
EOF
wait_for_http "http://${API_HOST}/api/version" "${REMOTE:+Check the firewall on $REMOTE allows port 11434 from this LAN, and that the server started: ssh $REMOTE tail -20 /tmp/ollama-hangarbaycc.log}"

# --- 3. preload and VERIFY it's fully on the GPU before launching Claude Code --
echo ">> Preloading (allocates the full KV cache)..."
if ! curl -sf "http://${API_HOST}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false}" >/dev/null; then
  echo "!! Preload failed for model '$MODEL' (server returned an error)." >&2
  echo "!! Most likely the model isn't in the store the server is using." >&2
  echo "!!   store in use: ${MODEL_STORE} on ${SERVER_LABEL}" >&2
  echo "!! Check 'ollama list', or 'ollama pull $MODEL' there. See /tmp/ollama-hangarbaycc.log for details." >&2
  exit 1
fi

ollama ps
if ! SPILL="$(curl -sf "http://${API_HOST}/api/ps" | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("models", []):
    size, vram = m.get("size", 0), m.get("size_vram", 0)
    if vram < size:
        gib = 2 ** 30
        print("%s: %.1f GiB on CPU of %.1f GiB total"
              % (m.get("name"), (size - vram) / gib, size / gib))
')"; then
  echo "!! Could not verify GPU placement (/api/ps check failed)." >&2
  echo "!! Not launching blind — check /tmp/ollama-hangarbaycc.log on ${SERVER_LABEL} and ollama ps." >&2
  exit 1
fi
if [[ -n "$SPILL" ]]; then
  echo "!! $NUM_CTX tokens spilled to CPU — too big for 16 GB VRAM:" >&2
  echo "!!   $SPILL" >&2
  echo "!! Unloading and aborting. Re-run and pick a smaller context / more compressed KV cache." >&2
  ollama stop "$MODEL" 2>/dev/null || true
  exit 1
fi
echo ">> Fully on GPU. Launching Claude Code..."

# --- 3a. optionally start voice dictation (whisper-server) on spare VRAM ------
# Runs AFTER the spill guard above confirmed the model is 100% on GPU, so
# whisper only ever takes leftover VRAM — the spill guard above needs no
# changes to account for it. Every failure here warns and skips dictation;
# none of them should abort the coding session.
if [[ -n "$DICTATE" ]]; then
  if ! remote_exec "$REMOTE" "test -x ${WHISPER_DIR}/build/bin/whisper-server && test -f ${WHISPER_DIR}/models/${WHISPER_MODEL}"; then
    echo "!! whisper-server not set up on ${SERVER_LABEL} — run ./setup-whisper-server.sh ${REMOTE} first." >&2
    echo "!! Continuing without dictation." >&2
  else
    FREE_MIB="$(remote_exec "$REMOTE" "nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits" | head -1 | tr -d '[:space:]')"
    if [[ -z "$FREE_MIB" || "$FREE_MIB" -lt "$WHISPER_MIN_FREE_MIB" ]]; then
      echo "!! Only ${FREE_MIB:-0} MiB free on ${SERVER_LABEL} after loading ${MODEL}" >&2
      echo "!! (need ~${WHISPER_MIN_FREE_MIB} MiB for whisper-server) — skipping dictation." >&2
      echo "!! Pick a smaller context/more compressed KV cache to free headroom." >&2
    else
      echo ">> Starting whisper-server on ${SERVER_LABEL} (:${WHISPER_PORT}, ${FREE_MIB} MiB free)..."
      remote_script "$REMOTE" <<EOF
pkill -x whisper-server 2>/dev/null || true
sleep 1
cd ${WHISPER_DIR}
setsid nohup ./build/bin/whisper-server -m models/${WHISPER_MODEL} \
  --host ${WHISPER_BIND%%:*} --port ${WHISPER_PORT} -t 4 \
  >/tmp/whisper-hangarbaycc.log 2>&1 </dev/null &
disown
EOF
      if wait_for_http "http://${WHISPER_HOST}/" "Check /tmp/whisper-hangarbaycc.log on ${SERVER_LABEL} — first start JIT-compiles PTX and can take longer than usual." soft; then
        echo "$WHISPER_HOST" > "$WHISPER_ENDPOINT_FILE"
        echo ">> Dictation ready: bind a hotkey to $SCRIPT_DIR/hangarbay-dictate.sh (toggle to talk)."
      else
        echo "!! whisper-server didn't come up in time — continuing without dictation." >&2
      fi
    fi
  fi
fi

# --- 3b. start the temperature-clamping proxy and point Claude Code at it ------
# The proxy transparently forwards to the real server but clamps temperature
# into the model's band, caps top_p, and strips the DISALLOWED_TOOLS schemas
# out of every request. It always runs on THIS machine, pointed at API_HOST
# (which may be remote); we only repoint OLLAMA_HOST for the launch step below.
PROXY_PORT="${PROXY_HOST##*:}"
STRIP_TOOLS="$(IFS=,; echo "${DISALLOWED_TOOLS[*]}")"
if [[ -f "$TEMP_PROXY" ]]; then
  echo ">> Starting temperature proxy (:$PROXY_PORT -> $API_HOST, temp -> [$TEMP_FLOOR, $TEMP_CEIL], strip: $STRIP_TOOLS)..."
  nohup python3 "$TEMP_PROXY" "$PROXY_PORT" "$API_HOST" "$TEMP_FLOOR" "$TEMP_CEIL" \
    "$TOP_P_CEIL" "$STRIP_TOOLS" >/tmp/hangarbaycc-proxy.log 2>&1 &
  disown
  wait_for_http "http://${PROXY_HOST}/api/version" "Check /tmp/hangarbaycc-proxy.log"
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
    --settings "$LAUNCH_SETTINGS" \
    --append-system-prompt "$(cat "$EDIT_RULES")" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
else
  echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
  echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${DISALLOWED_TOOLS[*]}"
  ollama launch claude --model "$MODEL" -y -- \
    --settings "$LAUNCH_SETTINGS" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}"
fi

echo ">> Session over. Temp proxy stopped; ollama server on ${SERVER_LABEL} left running (model stays warm)."
if [[ -n "$REMOTE" ]]; then
  echo ">> To restore the system Ollama service on $REMOTE: ssh -t $REMOTE sudo systemctl start ollama"
else
  echo ">> To restore the system Ollama service: sudo systemctl start ollama"
fi
if [[ -n "$DICTATE" ]]; then
  echo ">> whisper-server on ${SERVER_LABEL} left running too (dictation keeps working)."
  echo ">> Stop it with: ssh $REMOTE pkill -x whisper-server"
fi
