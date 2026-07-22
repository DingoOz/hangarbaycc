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
# On launch you pick the model, context window, and KV cache precision. If
# ollama isn't installed on the target host you're offered the official
# installer; if the chosen model isn't in either model store you're offered an
# `ollama pull`. The preload guard aborts on a CPU spill; if it triggers,
# re-run with a smaller context and/or more compressed KV cache.
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
# grok backend (2 variants): launches xAI's Grok Build TUI (the `grok` CLI)
# INSTEAD OF Claude Code, wired to a Qwen3.6-35B-A3B llama-server. No proxy
# either way — llama-server already speaks OpenAI-compatible
# /v1/chat/completions natively, and grok is a native OpenAI-compatible
# client (unlike Claude Code, which needs hangarbaycc-proxy.py's
# Anthropic<->OpenAI translation).
#   4) Grok Build (ml-server)  model server is grok-local's own stack, fixed
#      at :8081, 128K ctx, q8_0 KV, started/reused over SSH on ml-server (see
#      ~/Programming/grok-local/README.md there). `grok` itself always runs
#      HERE, talking to ml-server over the LAN. The default sub-choice instead
#      ATTACHES to whatever llama-server is already up on :8081 — no SSH, no
#      start/stop; the model id and context window are read from /props.
#   5) Grok Build (local)      model server is grok-local-server.sh (vendored
#      into this repo from ~/ai-models/qwen3.6-35b-a3b/run.sh so there's no
#      external script reference), fixed at :8080, 200K ctx, q8_0 KV, on THIS
#      machine's own GPU — no SSH, no LAN dependency.
# Either way, the first run against a given target adds a `[model.*]` entry
# to ~/.grok/config.toml pointing at it (qwen36-mlserver / qwen36-local); if
# the `grok` CLI itself isn't found on PATH, both variants offer to install
# it (see ensure_grok_cli below), the same posture as the meshllm classifier
# host's Ollama auto-install.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: hangarbaycc.sh [-r|--remote HOST] [-d|--dictate] [-i|--isolate]

  -r, --remote HOST   Run the Ollama server on HOST over SSH instead of this
                       machine. The proxy and Claude Code still run here.
                       Ollama backend only.
  -d, --dictate        Start voice dictation (whisper-server on the GPU host).
                       Ollama remote mode only; see README.md "Voice dictation".
  -i, --isolate        Network-isolate the grok process (local backend only).
                       Blocks all outbound traffic except loopback (127.0.0.0/8).
                       Uses nftables socket cgroupv2 matching. Requires root.
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
ISOLATE="1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--remote) REMOTE="${2:?--remote requires a HOST argument}"; shift 2 ;;
    --remote=*)  REMOTE="${1#*=}"; shift ;;
    -d|--dictate) DICTATE="1"; shift ;;
    -i|--isolate) ISOLATE="1"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "!! Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
REMOTE="${REMOTE:-${HANGARBAY_REMOTE:-}}"
DICTATE="${DICTATE:-${HANGARBAY_DICTATE:-}}"

# --- backend selection ----------------------------------------------------
echo "Select backend:"
echo "  1) Ollama              (local model — this machine or --remote; model/context/KV menus)"
echo "  2) meshllm             (LAN mesh-llm server, always-on, fixed config)"
echo "  3) meshllm, no classifier   (same, but skips the auto-mode safety-classifier host — faster"
echo "                              startup; Bash/Edit/Write auto-approval falls back to a normal"
echo "                              interactive y/n prompt instead — see the classifier comment below)"
echo "  4) Grok Build          (grok CLI instead of Claude Code; model runs on ml-server — pick"
echo "                          the already-running server, Qwen3.6-35B-A3B or gemma4-31B-3gpu at the"
echo "                          next prompt)"
echo "  5) Grok Build (local)  (same, but model server runs on THIS machine only — no SSH/LAN)"
read -rp "Backend [1-5]: " BACKEND_CHOICE
MESHLLM_SKIP_CLASSIFIER=""
case "$BACKEND_CHOICE" in
  1) BACKEND="ollama" ;;
  2) BACKEND="meshllm" ;;
  3) BACKEND="meshllm"; MESHLLM_SKIP_CLASSIFIER="1" ;;
  4) BACKEND="grok" ;;
  5) BACKEND="grok-local" ;;
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
  local url="$1" hint="${2:-}" mode="${3:-hard}" tries="${4:-60}"
  until curl -sf -m 5 "$url" >/dev/null 2>&1; do
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

# Shared by both grok backends (4 and 5, both run `grok` on THIS machine
# regardless of where the model server lives). Same posture as the meshllm
# classifier host's Ollama auto-install below: offer to install rather than
# just erroring, but — unlike that SSH/non-interactive install — ask first,
# since this runs in this interactive terminal and installs a new CLI tool
# for the calling user rather than provisioning a dedicated remote host.
ensure_grok_cli() {
  if command -v grok >/dev/null 2>&1; then
    return 0
  fi
  echo ">> 'grok' (Grok Build CLI) not found on PATH."
  read -rp "Install it now (curl -fsSL https://x.ai/cli/install.sh | bash)? [y/N]: " GROK_INSTALL_CONFIRM
  if [[ ! "$GROK_INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "!! Grok Build CLI is required for this backend — aborting." >&2
    echo "!! Install manually: https://x.ai/cli" >&2
    exit 1
  fi
  echo ">> Installing Grok Build CLI..."
  if ! curl -fsSL https://x.ai/cli/install.sh | bash; then
    echo "!! Install failed. Install manually: https://x.ai/cli" >&2
    exit 1
  fi
  hash -r   # forget any cached "not found" lookup for `grok` in this shell
  if ! command -v grok >/dev/null 2>&1; then
    echo "!! 'grok' still not on PATH after install — check the installer's target dir" >&2
    echo "!! (often ~/.local/bin) is on PATH, open a new shell, and re-run." >&2
    exit 1
  fi
  echo ">> Grok Build CLI installed: $(command -v grok)"
}

# Shared by ensure_searxng below (its only caller). Same offer-first posture
# as ensure_grok_cli. Unlike that one, this runs on whichever host will
# actually serve SearXNG (this machine for the grok-local backend, ml-server
# for every other backend — see ensure_searxng), so it takes a host argument
# like remote_exec/remote_script instead of always targeting this shell.
# Never exits the whole launcher on failure (returns 1 instead) — web search
# is optional, so a Docker problem should fall back to "no web search", not
# abort a session that doesn't otherwise need it.
ensure_docker() {
  local host="$1" label="${host:-this machine}"
  if remote_exec "$host" 'docker ps >/dev/null 2>&1'; then
    return 0
  fi
  # Local only: a new terminal window doesn't always start a fresh login
  # session (desktop terminal emulators commonly just fork off the existing
  # session), so group membership added by a prior Docker install can still
  # be invisible here even after "opening a new terminal" — sg re-execs with
  # the group active without needing an actual logout/login. Remote hosts are
  # unaffected: an SSH connection always starts a genuine new login session.
  if [[ -z "$host" ]] && sg docker -c 'docker ps' >/dev/null 2>&1; then
    echo ">> Using 'sg docker' — this session predates docker group membership."
    export DOCKER_SG=1
    return 0
  fi
  if ! remote_exec "$host" 'command -v docker >/dev/null 2>&1'; then
    echo ">> Docker is not installed on ${label}."
    read -rp "Install it now via the official script (curl https://get.docker.com | sh, needs sudo)? [y/N]: " DOCKER_INSTALL_CONFIRM
    if [[ ! "$DOCKER_INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
      echo "!! Docker declined — continuing without it." >&2
      return 1
    fi
    echo ">> Installing Docker on ${label}..."
    if ! remote_exec_tty "$host" 'curl -fsSL https://get.docker.com | sudo sh'; then
      echo "!! Docker install failed on ${label}." >&2
      return 1
    fi
    # The convenience script doesn't do this itself: without it, only root
    # can run docker, and there's no way to pick that up mid-session (group
    # membership is read at login, not on demand) — so this alone won't make
    # docker usable THIS run either, but saves a second install next time.
    remote_exec_tty "$host" 'sudo usermod -aG docker "$(whoami)"' || true
  fi
  if ! remote_exec "$host" 'docker ps >/dev/null 2>&1'; then
    echo "!! docker is installed on ${label} but this session can't use it yet" >&2
    echo "!! (group membership needs a fresh login). Log out/in there (or open a" >&2
    echo "!! new session after 'newgrp docker') and re-run this launcher." >&2
    return 1
  fi
}

# Wires the web-search MCP tool (searxng-mcp/server.py, backed by a SearXNG
# docker container) into whichever backend is running. On success, sets
# WEBSEARCH_ENABLED=1 and SEARXNG_MCP_JSON (a ready-to-pass --mcp-config file
# for Claude Code backends); also (re)writes ./.grok/config.toml's
# [mcp_servers.searxng] block, which grok's project-scoped config picks up
# automatically (see the existing model-config comment elsewhere in this
# file: "project-scoped .grok/config.toml only supports [mcp_servers]") — so
# the grok backends need no extra CLI flag. Never exits: any failure along
# the way (declined Docker install, container that won't start, venv setup
# failure) degrades to WEBSEARCH_ENABLED="" rather than aborting the session,
# same best-effort posture as the meshllm classifier's setup.
#
# Host choice: the grok-local backend is the only one with a "stays fully on
# this machine, no SSH" contract, so it's the only one that gets a local
# SearXNG too. Every other backend (Ollama in any mode, meshllm, the ml-server
# grok backend) already depends on the LAN or ml-server specifically for its
# own model serving, so they share ONE SearXNG on ml-server rather than each
# backend running its own — simpler, and consistent with meshllm/grok already
# treating ml-server as "the server". (Ollama's own --remote target, if it
# differs from ml-server, doesn't change this — search still goes to
# ml-server specifically, not wherever Ollama happens to be pointed.)
ensure_searxng() {
  WEBSEARCH_ENABLED=""
  local host port bind api_host label
  # Port 8889, not SearXNG's usual 8888: ml-server already runs an unrelated,
  # independently-managed SearXNG deployment on 8888 (loopback-only), and
  # docker can't bind 0.0.0.0:8888 alongside an existing 127.0.0.1:8888 —
  # 8889 keeps hangarbaycc's own container conflict-free instead of trying
  # (and failing) to share the port.
  if [[ "$BACKEND" == "grok-local" ]]; then
    host="" port=8889 bind="127.0.0.1" api_host="127.0.0.1" label="this machine"
  else
    host="ml-server" port=8889 bind="0.0.0.0" api_host="192.168.1.16" label="ml-server"
  fi
  local base_url="http://${api_host}:${port}/"

  if [[ -n "$host" ]] && ! ssh -o ConnectTimeout=5 "$host" true 2>/dev/null; then
    echo "!! Could not reach '$host' over SSH — continuing without web search." >&2
    return 0
  fi

  if ! ensure_docker "$host"; then
    echo "!! Continuing without web search." >&2
    return 0
  fi

  echo ">> Starting SearXNG on ${label} (:$port) for web search..."
  if [[ -n "$host" ]]; then
    remote_exec "$host" 'mkdir -p "$HOME/.hangarbaycc"'
    if ! scp -q "$SCRIPT_DIR/searxng-server.sh" "$SCRIPT_DIR/searxng-settings.yml" "${host}:.hangarbaycc/"; then
      echo "!! Could not copy searxng-server.sh to ${label} — continuing without web search." >&2
      return 0
    fi
    if ! remote_exec "$host" "SEARXNG_PORT=${port} SEARXNG_BIND_ADDR=${bind} SEARXNG_BASE_URL=${base_url} bash ~/.hangarbaycc/searxng-server.sh"; then
      echo "!! Could not start SearXNG on ${label} — continuing without web search." >&2
      return 0
    fi
  else
    if ! SEARXNG_PORT="$port" SEARXNG_BIND_ADDR="$bind" SEARXNG_BASE_URL="$base_url" "$SCRIPT_DIR/searxng-server.sh"; then
      echo "!! Could not start SearXNG locally — continuing without web search." >&2
      return 0
    fi
  fi

  # 240 tries (120s), not the default 30s: first run on a host pulls the
  # searxng/searxng image (a few hundred MB) before the container can even
  # start, which alone can blow past 30s on an ordinary connection.
  if ! wait_for_http "http://${api_host}:${port}/search?q=test&format=json" \
      "Check SearXNG's container logs on ${label} (docker logs hangarbaycc-searxng)." soft 240; then
    echo "!! SearXNG didn't come up in time on ${label} — continuing without web search." >&2
    return 0
  fi

  # One-time venv bootstrap for the MCP server. Gitignored, not vendored like
  # grok-local-server.sh — this is machine-specific installed packages, not a
  # portable script. Idempotent: skipped once already set up.
  local venv="$SCRIPT_DIR/searxng-mcp/.venv"
  if [[ ! -x "$venv/bin/python" ]]; then
    echo ">> Setting up the searxng-mcp Python venv (one-time)..."
    if ! python3 -m venv "$venv" \
        || ! "$venv/bin/pip" install -q --upgrade pip \
        || ! "$venv/bin/pip" install -q mcp; then
      echo "!! Could not set up the searxng-mcp venv — continuing without web search." >&2
      rm -rf "$venv"
      return 0
    fi
  fi

  local mcp_url="http://${api_host}:${port}"

  # Claude Code backends read this via --mcp-config; grok's TOML config
  # (below) can't take an env var (config.toml's [mcp_servers.*] only
  # documents command/args, no env table), so server.py accepts the URL as
  # argv[1] too — this JSON uses env, the TOML block below uses args, same
  # server script handles either.
  SEARXNG_MCP_JSON="/tmp/hangarbaycc-searxng-mcp.json"
  printf '{"mcpServers":{"searxng":{"command":"%s","args":["%s"],"env":{"SEARXNG_URL":"%s"}}}}' \
    "$venv/bin/python" "$SCRIPT_DIR/searxng-mcp/server.py" "$mcp_url" >"$SEARXNG_MCP_JSON"

  # Project-scoped, not ~/.grok/config.toml (that one's reserved for the
  # [model.*] entries the grok backends already manage) — grok reads
  # [mcp_servers] from whichever one is project-scoped, per the comment on
  # GROK_CONFIG elsewhere in this file. Written at $PWD, not $SCRIPT_DIR:
  # "project-scoped" means grok resolves it relative to ITS OWN working
  # directory when exec'd below, which is wherever hangarbaycc.sh was
  # invoked from — normally the same as $SCRIPT_DIR (the documented usage is
  # `cd` into the repo then `./hangarbaycc.sh`), but not guaranteed if this
  # script is invoked by its full path from elsewhere. Machine-specific
  # (absolute paths, current host's URL), so this file is gitignored,
  # regenerated every launch.
  local grok_toml="$PWD/.grok/config.toml"
  mkdir -p "$(dirname "$grok_toml")"
  touch "$grok_toml"
  python3 - "$grok_toml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n?\[mcp_servers\.searxng\].*?(?=\n\[|\Z)", "", text, flags=re.S)
open(path, "w").write(text)
PY
  cat >>"$grok_toml" <<EOF

[mcp_servers.searxng]
command = "$venv/bin/python"
args = ["$SCRIPT_DIR/searxng-mcp/server.py", "$mcp_url"]
enabled = true
EOF

  WEBSEARCH_ENABLED="1"
  echo ">> Web search ready: SearXNG on ${label}, MCP tool wired in."
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

# --- web search (optional, all backends) --------------------------------------
# Always enabled. ensure_searxng degrades gracefully — if Docker/SearXNG
# isn't available it leaves WEBSEARCH_ENABLED empty rather than aborting.
ensure_searxng

# --- meshllm backend --------------------------------------------------------
if [[ "$BACKEND" == "meshllm" ]]; then
  [[ -n "$REMOTE" || -n "$DICTATE" ]] && \
    echo "!! --remote/--dictate don't apply to the meshllm backend (fixed LAN endpoint); ignoring." >&2

  MESHLLM_HOST="192.168.1.16:9337"
  MESHLLM_BASE="http://${MESHLLM_HOST}/v1"

  echo "Select mesh-llm model:"
  echo "  1) Qwen3-30B-A3B-Q4_K_M-layers   (MoE, 48 layers, split ml-server+rtx3070 — current default)"
  echo "  2) Qwen3-8B-Q4_K_M-layers        (smaller dense model, same split topology)"
  read -rp "Model [1-2, default 1]: " MESHLLM_MODEL_CHOICE
  case "${MESHLLM_MODEL_CHOICE:-1}" in
    1) MESHLLM_MODEL_REF="Qwen3-30B-A3B-Q4_K_M-layers" ;;
    2) MESHLLM_MODEL_REF="Qwen3-8B-Q4_K_M-layers" ;;
    *) echo "!! Invalid model choice: $MESHLLM_MODEL_CHOICE" >&2; exit 1 ;;
  esac
  MODEL="meshllm/${MESHLLM_MODEL_REF}"

  # 40960 is mesh-llm/skippy's ctx_size — confirmed via the GGUF metadata to
  # be the native context for BOTH catalog models above, so this doesn't need
  # to vary by selection. It IS, however, one shared KV cache divided evenly
  # across however many concurrent "lanes" (skippy's llama.cpp-style
  # parallel-slot count) are configured — live-confirmed via ml-server's own
  # console API (curl http://127.0.0.1:3131/api/status) as lane_count=4 in
  # production, meaning a single session's real budget is ~40960/4≈10240
  # tokens, NOT the full 40960 this NUM_CTX claims. No CLI flag for lane
  # count was found in `mesh-llm --help-advanced` (0.73.1) to bring it down
  # to 1 — this mismatch is a known, NOT-yet-fixed gap (a prior comment here
  # incorrectly claimed lane_count=1 was already deliberately configured;
  # that was never actually implemented, since no lever for it exists yet).
  # Until resolved, treat compaction/rejection near the true ~10240-token
  # ceiling as expected, not a bug.
  NUM_CTX=40960
  TEMP_FLOOR=0.7; TEMP_CEIL=0.85; TOP_P_CEIL=1.0   # no established guidance yet; easy to tune
  PROXY_PORT="${PROXY_HOST##*:}"

  # --- mesh-llm cluster control (ml-server coordinator + rtx3070 worker) ----
  # The "-layers" catalog build only forms a split when BOTH nodes are
  # serving the exact same model reference (see mesh-llm-setup.md on
  # ml-server) — there's no way to hot-swap the model on a running instance,
  # so switching models means stopping and restarting mesh-llm on BOTH hosts.
  MESHLLM_COORD_SSH="ml-server"
  MESHLLM_COORD_IP="192.168.1.16"
  MESHLLM_WORKER_SSH="rtx3070"
  MESHLLM_WORKER_IP="192.168.1.193"
  # ml-server's node identity (~/.mesh-llm/mesh-id and its keypair) persists
  # across restarts unless `mesh-llm rotate-key` is run there, so this join
  # token (ml-server's node id + LAN address, from mesh-llm-setup.md) keeps
  # working across model switches without needing to be regenerated each
  # time. If joining ever starts failing, check whether that identity was
  # rotated and pull a fresh token from ml-server (its console API's
  # /api/status "token" field, or the serve command's own startup output).
  MESHLLM_JOIN_TOKEN="eyJpZCI6ImY5MTE1YzE2MmI1NjdmOGYwZTM1N2FmYWU2ODdlNjAyN2Y2N2JkMjM5NmIzYTcwZGI5NDA5Yjk0ZDkyYzQzN2MiLCJhZGRycyI6W3siSXAiOiIxOTIuMTY4LjEuMTY6Nzg0MiJ9XX0"

  # /v1/models' single entry's `id` is the model currently being served —
  # empty string (rather than erroring) if unreachable or the response
  # doesn't parse, so callers can just compare against "$MODEL".
  meshllm_current_model() {
    curl -sf -m 5 "$MESHLLM_BASE/models" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["data"][0]["id"])
except Exception:
    pass
' 2>/dev/null
  }

  ensure_meshllm_model() {
    local want="$1" current
    current="$(meshllm_current_model)"

    if [[ "$current" == "$want" ]]; then
      echo ">> mesh-llm already serving $want — skipping restart."
      return 0
    fi

    echo ">> mesh-llm is currently serving '${current:-<unreachable>}', not '$want'."
    echo ">> Switching models restarts the SHARED mesh-llm service on both"
    echo ">> $MESHLLM_COORD_SSH and $MESHLLM_WORKER_SSH — anyone else mid-request"
    echo ">> against it right now (inflight requests, if any) will be interrupted."
    read -rp "Proceed with the switch? [y/N]: " MESHLLM_CONFIRM_SWITCH
    [[ "$MESHLLM_CONFIRM_SWITCH" =~ ^[Yy]$ ]] || { echo "!! Aborting." >&2; exit 1; }

    if ! ssh -o ConnectTimeout=5 "$MESHLLM_COORD_SSH" true; then
      echo "!! Could not reach '$MESHLLM_COORD_SSH' over SSH." >&2
      exit 1
    fi
    if ! ssh -o ConnectTimeout=5 "$MESHLLM_WORKER_SSH" true; then
      echo "!! Could not reach '$MESHLLM_WORKER_SSH' over SSH." >&2
      exit 1
    fi

    echo ">> Stopping mesh-llm on $MESHLLM_COORD_SSH..."
    remote_exec "$MESHLLM_COORD_SSH" '~/stop-mesh-llm.sh' || true

    echo ">> Stopping mesh-llm-node container on $MESHLLM_WORKER_SSH..."
    remote_exec "$MESHLLM_WORKER_SSH" \
      'docker stop mesh-llm-node >/dev/null 2>&1 || true; docker rm mesh-llm-node >/dev/null 2>&1 || true'

    # Not backgrounded via a service manager on ml-server today (it normally
    # runs attached to whoever's terminal started it) — setsid+nohup+disown
    # detaches it from this SSH session the same way the classifier-host
    # bring-up above does, so it survives after we disconnect.
    echo ">> Starting mesh-llm on $MESHLLM_COORD_SSH with $want..."
    remote_script "$MESHLLM_COORD_SSH" <<EOF
setsid nohup ~/start-mesh-llm.sh serve --model $want --split --max-vram 15 \
  --bind-ip $MESHLLM_COORD_IP --bind-port 7842 --mesh-discovery-mode mdns --listen-all \
  >/tmp/mesh-llm-coordinator.log 2>&1 </dev/null &
disown
EOF
    wait_for_http "http://${MESHLLM_COORD_IP}:9337/v1/models" \
      "Check /tmp/mesh-llm-coordinator.log on $MESHLLM_COORD_SSH."

    echo ">> Starting mesh-llm-node container on $MESHLLM_WORKER_SSH with $want..."
    remote_script "$MESHLLM_WORKER_SSH" <<EOF
docker run -d \
  --name mesh-llm-node \
  --network host \
  --restart unless-stopped \
  --gpus all \
  -v /home/dingo/mesh-llm-remote-home:/root \
  -v /home/dingo/.local/bin/mesh-llm:/usr/local/bin/mesh-llm:ro \
  mesh-llm-base:latest \
  mesh-llm serve --model $want --split --max-vram 7 \
    --join $MESHLLM_JOIN_TOKEN \
    --bind-ip $MESHLLM_WORKER_IP --bind-port 7843 --port 9337 --console 3131 \
    --mesh-discovery-mode mdns --log-format json --listen-all
EOF

    echo ">> Waiting for the mesh-llm split to form and report '$want' (this can take a"
    echo ">> while the first time a model is selected — rtx3070 may need to download its"
    echo ">> share of layers from Hugging Face)..."
    local tries=150   # up to 5 min: cold weight download + split-plan formation
    until [[ "$(meshllm_current_model)" == "$want" ]]; do
      tries=$((tries - 1))
      if [[ $tries -le 0 ]]; then
        echo "!! Timed out waiting for mesh-llm to report '$want'." >&2
        echo "!! Check /tmp/mesh-llm-coordinator.log on $MESHLLM_COORD_SSH and" >&2
        echo "!! 'ssh $MESHLLM_WORKER_SSH docker logs mesh-llm-node' for split-formation errors." >&2
        exit 1
      fi
      sleep 2
    done
    echo ">> mesh-llm now serving $want."
  }

  ensure_meshllm_model "$MODEL"

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
    #
    # OLLAMA_NUM_PARALLEL=1 is load-bearing, not just tidy: Ollama's
    # prompt-prefix cache (which makes every classifier call after the first
    # in a session nearly free — see hangarbaycc-proxy.py's
    # CLASSIFIER_CONTEXT_BUDGET_BYTES comment) only reliably reuses the same
    # KV cache when sequential requests land in the same slot. With more than
    # one parallel slot, concurrent classifier calls (Claude Code does fire
    # more than one at once sometimes) could land in different slots and
    # silently lose the cache hit, reintroducing the full cold-prefill cost
    # on calls that should have been fast.
    remote_exec_tty "$CLASSIFIER_SSH_HOST" 'if systemctl is-active --quiet ollama 2>/dev/null; then sudo systemctl stop ollama; fi'
    remote_script "$CLASSIFIER_SSH_HOST" <<'EOF'
pkill -x ollama 2>/dev/null || true
sleep 2
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_KEEP_ALIVE=-1 OLLAMA_NUM_PARALLEL=1 setsid nohup ollama serve >/tmp/ollama-classifier.log 2>&1 </dev/null &
disown
EOF
    wait_for_http "http://${CLASSIFIER_HOST}/api/version" \
      "Check /tmp/ollama-classifier.log on ${CLASSIFIER_SSH_HOST}, and that its firewall allows port 11434 from this LAN." soft
  }

  if [[ -n "$MESHLLM_SKIP_CLASSIFIER" ]]; then
    echo ">> Skipping classifier setup (menu choice) — auto-mode Bash/Edit/Write checks may be" >&2
    echo ">> slow/unreliable against meshllm; see the classifier comment above for why." >&2
    CLASSIFIER_MODEL=""
  elif ! ensure_classifier_server; then
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

  # Without a classifier override, auto-mode's safety-classifier call still
  # fires (its hardcoded "claude-sonnet-5" target isn't rewritten by the
  # proxy — see CLASSIFIER_MODEL comment above), requests a model that
  # doesn't exist on meshllm, and HARD-FAILS every non-allowlisted
  # Bash/Edit/Write call rather than degrading gracefully. --permission-mode
  # manual sidesteps auto-mode's classifier gate entirely, falling back to a
  # normal interactive y/n prompt for anything not covered by an explicit
  # allow/deny rule — the tradeoff for skipping the classifier host is
  # "ask me every time", not "broken".
  CLAUDE_EXTRA_ARGS=()
  if [[ -n "$MESHLLM_SKIP_CLASSIFIER" ]]; then
    CLAUDE_EXTRA_ARGS+=(--permission-mode manual)
  fi
  [[ -n "$WEBSEARCH_ENABLED" ]] && CLAUDE_EXTRA_ARGS+=(--mcp-config "$SEARXNG_MCP_JSON")

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
      --disallowedTools "${MESHLLM_STRIP_TOOLS[@]}" \
      "${CLAUDE_EXTRA_ARGS[@]}"
  else
    echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
    echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${MESHLLM_STRIP_TOOLS[*]}"
    claude --settings "$LAUNCH_SETTINGS" --disallowedTools "${MESHLLM_STRIP_TOOLS[@]}" "${CLAUDE_EXTRA_ARGS[@]}"
  fi

  echo ">> Session over. Translation proxy stopped. meshllm is always-on — nothing to leave warm here."
  exit 0
fi

# --- grok backend ------------------------------------------------------------
# Launches xAI's Grok Build TUI instead of Claude Code. The model server is
# grok-local's own stack (llama-server serving Qwen3.6-35B-A3B) started/reused
# on ml-server over SSH; `grok` itself runs on THIS machine, talking to
# ml-server over the LAN — no proxy involved, since llama-server already
# speaks OpenAI-compatible /v1/chat/completions natively and grok is a native
# OpenAI-compatible client (unlike Claude Code, which needs
# hangarbaycc-proxy.py's Anthropic<->OpenAI translation).
if [[ "$BACKEND" == "grok" ]]; then
  [[ -n "$REMOTE" || -n "$DICTATE" ]] && \
    echo "!! --remote/--dictate don't apply to the grok backend (fixed ml-server endpoint); ignoring." >&2

  # Same host as the meshllm coordinator above, but a different service (grok-local's
  # llama-server, not mesh-llm) and a different port. IP hardcoded rather than
  # resolved from the 'ml-server' ssh alias, matching the MESHLLM_COORD_IP
  # convention above — ssh aliases aren't guaranteed resolvable for plain HTTP.
  GROK_SSH_HOST="ml-server"
  GROK_HOST_IP="192.168.1.16"
  GROK_PORT=8081
  GROK_BASE="http://${GROK_HOST_IP}:${GROK_PORT}"
  GROK_REMOTE_ROOT='$HOME/Programming/grok-local'   # single-quoted: expanded on the TARGET host

  # Two model stacks live on ml-server, both served by grok-local's llama-server
  # on the SAME port (8081), so only one can be up at a time — the health check
  # below therefore also verifies WHICH model is loaded and restarts on mismatch.
  echo "Select grok model (ml-server):"
  echo "  1) Use existing server  (whatever llama-server is already up on ${GROK_SSH_HOST}:${GROK_PORT} — default)"
  echo "  2) Qwen3.6-35B-A3B     (MoE, 2-GPU split: ml-server + rtx3070)"
  echo "  3) gemma4-31B-3gpu     (dense 31B, RPC across 5060 Ti + rtx3070 + gtx1070 VM)"
  read -rp "Model [1-3, default 1]: " GROK_MODEL_CHOICE
  # Attach to what's running (option 1) vs. own the server's lifecycle (2/3).
  GROK_USE_EXISTING=0
  case "${GROK_MODEL_CHOICE:-1}" in
    1)
      GROK_USE_EXISTING=1
      ;;
    2)
      GROK_MODEL_ID="qwen36-mlserver"   # distinct from ml-server's own local-loopback config's "qwen36-local"
      GROK_MODEL_LABEL="Qwen3.6-35B-A3B"
      GROK_MODEL_GGUF="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
      GROK_MODEL_MATCH="Qwen3.6-35B"
      GROK_START_CMD="./bin/run-qwen36-35b.sh --port ${GROK_PORT}"
      GROK_DOWNLOAD_HINT="${GROK_REMOTE_ROOT}/bin/download-qwen36.sh"
      GROK_CTX_WINDOW=131072
      # Qwen's own stack tears down cleanly with a port kill; nothing else to stop.
      GROK_STOP_CMD="fuser -k ${GROK_PORT}/tcp 2>/dev/null || true"
      GROK_WAIT_TRIES=60
      ;;
    3)
      GROK_MODEL_ID="gemma4-31b-mlserver"
      GROK_MODEL_LABEL="gemma4-31B (3-GPU)"
      GROK_MODEL_GGUF="gemma-4-31B-it-UD-Q4_K_XL.gguf"
      GROK_MODEL_MATCH="gemma-4-31B"
      GROK_START_CMD="./bin/start-gemma4-31b-3gpu.sh --port ${GROK_PORT}"
      GROK_DOWNLOAD_HINT="hf download unsloth/gemma-4-31B-it-GGUF ${GROK_MODEL_GGUF} --local-dir ${GROK_REMOTE_ROOT}/models"
      # The gemma script's own default (-c 65536). Only 10 of its 60 layers are
      # global-attention; the other 50 are sliding-window (fixed ~425 MiB KV),
      # so context costs just ~1.36 GiB per 32K across the three GPUs.
      GROK_CTX_WINDOW=65536
      # Its --stop also shuts down both RPC workers (3070 + 1070 VM).
      GROK_STOP_CMD="cd ${GROK_REMOTE_ROOT} && ./bin/start-gemma4-31b-3gpu.sh --stop 2>/dev/null || true; fuser -k ${GROK_PORT}/tcp 2>/dev/null || true"
      # Slower: brings up the gtx1070 VM and two RPC peers before loading ~19 GB.
      GROK_WAIT_TRIES=900
      ;;
    *) echo "!! Invalid model choice: $GROK_MODEL_CHOICE" >&2; exit 1 ;;
  esac

  # Attach mode: no SSH, no GPU check, no start/stop — whatever is already
  # listening on :8081 is taken as-is. Its identity and real context window
  # come from /props, so grok's config matches the server instead of guessing.
  if [[ "$GROK_USE_EXISTING" -eq 1 ]]; then
    if ! curl -sf -m 3 "${GROK_BASE}/health" >/dev/null 2>&1; then
      echo "!! No healthy llama-server on ${GROK_BASE}." >&2
      echo "!! Nothing to attach to — re-run and pick option 2 or 3 to start one." >&2
      exit 1
    fi
    GROK_PROPS="$(curl -sf -m 5 "${GROK_BASE}/props" 2>/dev/null || true)"
    GROK_PROPS_INFO="$(printf '%s' "$GROK_PROPS" | python3 -c '
import json, os, sys
try:
    p = json.load(sys.stdin)
except Exception:
    p = {}
path = p.get("model_path") or p.get("default_generation_settings", {}).get("model") or ""
ctx = p.get("default_generation_settings", {}).get("n_ctx") or p.get("n_ctx") or 0
print(os.path.basename(path))
print(int(ctx))
' 2>/dev/null || true)"
    GROK_MODEL_GGUF="$(printf '%s\n' "$GROK_PROPS_INFO" | sed -n 1p)"
    GROK_CTX_WINDOW="$(printf '%s\n' "$GROK_PROPS_INFO" | sed -n 2p)"
    [[ -n "$GROK_MODEL_GGUF" ]] || GROK_MODEL_GGUF="unknown"
    [[ "${GROK_CTX_WINDOW:-0}" -gt 0 ]] 2>/dev/null || GROK_CTX_WINDOW=32768
    GROK_MODEL_LABEL="${GROK_MODEL_GGUF%.gguf} (already running)"
    # One config entry per distinct running model, so a stale context_window
    # from a previous attach doesn't get reused for a different model.
    GROK_MODEL_ID="existing-$(printf '%s' "${GROK_MODEL_GGUF%.gguf}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
    echo ">> Backend: Grok Build | Attaching to running server on ${GROK_SSH_HOST} (${GROK_BASE})"
    echo ">> Loaded model: ${GROK_MODEL_GGUF} | context window: ${GROK_CTX_WINDOW}"
  fi

  if [[ "$GROK_USE_EXISTING" -eq 0 ]]; then
  echo ">> Backend: Grok Build | Model: ${GROK_MODEL_LABEL} on ${GROK_SSH_HOST} (${GROK_BASE})"

  if ! ssh -o ConnectTimeout=5 "$GROK_SSH_HOST" true; then
    echo "!! Could not reach '$GROK_SSH_HOST' over SSH." >&2
    exit 1
  fi

  if ! remote_exec "$GROK_SSH_HOST" "nvidia-smi >/dev/null 2>&1"; then
    echo "!! GPU unavailable on ${GROK_SSH_HOST} (nvidia-smi failed)." >&2
    exit 1
  fi

  # A healthy server on :8081 may be serving the OTHER model (they share the
  # port), so match the loaded model path from /props before reusing it.
  GROK_REUSE=0
  if curl -sf -m 3 "${GROK_BASE}/health" >/dev/null 2>&1; then
    GROK_LOADED="$(curl -sf -m 5 "${GROK_BASE}/props" 2>/dev/null || true)"
    if [[ "$GROK_LOADED" == *"$GROK_MODEL_MATCH"* ]]; then
      GROK_REUSE=1
      echo ">> Model server already up on ${GROK_SSH_HOST}:${GROK_PORT} with ${GROK_MODEL_LABEL} — reusing it."
    else
      echo ">> A different model is loaded on ${GROK_SSH_HOST}:${GROK_PORT} — stopping it to load ${GROK_MODEL_LABEL}."
      # Stop BOTH stacks: whichever is up, its own teardown is the clean one
      # (the gemma stack also owns two RPC workers that must be released).
      remote_script "$GROK_SSH_HOST" <<EOF
cd ${GROK_REMOTE_ROOT} 2>/dev/null || exit 0
./bin/start-gemma4-31b-3gpu.sh --stop >/dev/null 2>&1 || true
fuser -k ${GROK_PORT}/tcp 2>/dev/null || true
EOF
      sleep 2
    fi
  fi

  if [[ "$GROK_REUSE" -eq 0 ]]; then
    echo ">> Model server not up — starting ${GROK_MODEL_LABEL} on ${GROK_SSH_HOST}..."
    if ! remote_exec "$GROK_SSH_HOST" "test -f ${GROK_REMOTE_ROOT}/models/${GROK_MODEL_GGUF}"; then
      echo "!! Model gguf ${GROK_MODEL_GGUF} not found in ${GROK_REMOTE_ROOT}/models on ${GROK_SSH_HOST}." >&2
      echo "!! Get it there first: ${GROK_DOWNLOAD_HINT}" >&2
      exit 1
    fi
    # Port may be occupied by a stale/unhealthy process from a prior crashed
    # run (the health check above already ruled out a *healthy* server) —
    # clear it before starting, same posture as the Ollama backend's stop step.
    remote_script "$GROK_SSH_HOST" <<EOF
${GROK_STOP_CMD}
sleep 1
cd ${GROK_REMOTE_ROOT}
mkdir -p models
setsid nohup ${GROK_START_CMD} >models/llama-server.log 2>&1 </dev/null &
disown
EOF
    wait_for_http "${GROK_BASE}/health" \
      "Check ${GROK_REMOTE_ROOT}/models/llama-server.log on ${GROK_SSH_HOST}." \
      hard "$GROK_WAIT_TRIES"
    echo ">> Model server ready on ${GROK_SSH_HOST}:${GROK_PORT}."
  fi
  fi   # GROK_USE_EXISTING == 0

  # Client-side: register the model with grok's config if it isn't there yet.
  # Only [model.*] sections in ~/.grok/config.toml are read (project-scoped
  # .grok/config.toml only supports [mcp_servers]), so this must be global.
  GROK_CONFIG="$HOME/.grok/config.toml"
  ensure_grok_cli
  mkdir -p "$(dirname "$GROK_CONFIG")"
  touch "$GROK_CONFIG"
  if grep -q "^\[model\.${GROK_MODEL_ID}\]" "$GROK_CONFIG" 2>/dev/null; then
    if [[ "$GROK_USE_EXISTING" -eq 1 ]]; then
      # Attach mode: the section already exists (same model attached before),
      # but the server may have been reloaded since with a different -c —
      # refresh context_window in place so it never goes stale.
      echo ">> Model '$GROK_MODEL_ID' already configured in $GROK_CONFIG — refreshing context_window to ${GROK_CTX_WINDOW}."
      awk -v section="[model.${GROK_MODEL_ID}]" -v ctx="$GROK_CTX_WINDOW" '
        $0 == section { in_section=1 }
        in_section && /^\[/ && $0 != section { in_section=0 }
        in_section && /^context_window[[:space:]]*=/ { print "context_window = " ctx; next }
        { print }
      ' "$GROK_CONFIG" >"${GROK_CONFIG}.tmp" && mv "${GROK_CONFIG}.tmp" "$GROK_CONFIG"
    else
      echo ">> Model '$GROK_MODEL_ID' already configured in $GROK_CONFIG."
    fi
  else
    echo ">> Adding model '$GROK_MODEL_ID' to $GROK_CONFIG (points at ${GROK_BASE})..."
    cat >>"$GROK_CONFIG" <<EOF

[model.${GROK_MODEL_ID}]
model = "${GROK_MODEL_ID}"
base_url = "${GROK_BASE}/v1"
name = "${GROK_MODEL_LABEL} (ml-server, LAN)"
description = "grok-local's llama-server on ml-server, reached over the LAN"
api_key = "local"
api_backend = "chat_completions"
temperature = 0.7
top_p = 0.95
max_completion_tokens = 32768
context_window = ${GROK_CTX_WINDOW}
stream_tool_calls = false
EOF
  fi

  echo ">> Launching Grok Build against ${GROK_SSH_HOST} (model server left running afterward — stays warm)..."
  exec grok -m "$GROK_MODEL_ID" --disable-web-search
fi

# --- grok-local backend --------------------------------------------------------
# Same as the grok backend above, except the model server is
# grok-local-server.sh (vendored into this repo, not an external script
# reference) running on THIS machine's own GPU — no SSH, no LAN dependency.
# See the header comment near the top of the file for the full picture.
if [[ "$BACKEND" == "grok-local" ]]; then
  [[ -n "$REMOTE" || -n "$DICTATE" ]] && \
    echo "!! --remote/--dictate don't apply to the grok-local backend (this machine only); ignoring." >&2

  GROK_PORT=8080
  GROK_BASE="http://127.0.0.1:${GROK_PORT}"
  GROK_SERVER_SCRIPT="$SCRIPT_DIR/grok-local-server.sh"
  GROK_MODEL_DIR="${GROK_LOCAL_MODEL_DIR:-$HOME/ai-models/qwen3.6-35b-a3b}"
  GROK_MODEL_ID="qwen36-local"   # distinct from ml-server's "qwen36-mlserver"
  GROK_CTX=100000   # 10k under grok-local-server.sh's -c: the model loops past
                    # ~90k context, so the client must compact before then

  echo ">> Backend: Grok Build (local) | Model: Qwen3.6-35B-A3B on this machine (${GROK_BASE})"

  if ! nvidia-smi >/dev/null 2>&1; then
    echo "!! GPU unavailable on this machine (nvidia-smi failed)." >&2
    echo "!! Reboot / reset the driver first." >&2
    exit 1
  fi

  if curl -sf -m 3 "${GROK_BASE}/health" >/dev/null 2>&1; then
    echo ">> Model server already up on 127.0.0.1:${GROK_PORT} — reusing it."
  else
    echo ">> Model server not up — starting it..."
    if [[ ! -x "$GROK_SERVER_SCRIPT" ]]; then
      echo "!! $GROK_SERVER_SCRIPT not found or not executable." >&2
      exit 1
    fi
    if [[ ! -f "$GROK_MODEL_DIR/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf" ]]; then
      echo "!! Model gguf not found in $GROK_MODEL_DIR." >&2
      echo "!! Set GROK_LOCAL_MODEL_DIR if your weights live elsewhere." >&2
      exit 1
    fi
    # Port may be occupied by a stale/unhealthy process from a prior crashed
    # run (the health check above already ruled out a *healthy* server) —
    # clear it before starting, same posture as the Ollama backend's stop step.
    fuser -k "${GROK_PORT}/tcp" 2>/dev/null || true
    sleep 1
    # grok-local-server.sh backgrounds with stdin on /dev/null (so it survives
    # this terminal closing), which means IT can never prompt interactively —
    # ask here instead, while we still have a real tty, and pass the answer
    # through as an env var.
    if [[ -z "${GROK_LOCAL_IMAGES:-}" && -t 0 ]]; then
      read -r -p "Load image/vision support (mmproj)? Rarely needed for coding, adds load time/RAM [y/N] " reply
      [[ "$reply" =~ ^[Yy]$ ]] && GROK_LOCAL_IMAGES=1 || GROK_LOCAL_IMAGES=0
    fi
    if [[ -z "${GROK_LOCAL_TIMEOUT:-}" && -t 0 ]]; then
      read -r -p "Auto-unload server after how many minutes? (-1 or 0 = never) [-1]: " reply
      GROK_LOCAL_TIMEOUT="${reply:--1}"
    fi
    GROK_LOCAL_MODEL_DIR="$GROK_MODEL_DIR" GROK_LOCAL_IMAGES="${GROK_LOCAL_IMAGES:-0}" \
      GROK_LOCAL_TIMEOUT="${GROK_LOCAL_TIMEOUT:--1}" \
      setsid nohup "$GROK_SERVER_SCRIPT" \
      >/tmp/hangarbaycc-grok-local.log 2>&1 </dev/null &
    disown
    wait_for_http "${GROK_BASE}/health" "Check /tmp/hangarbaycc-grok-local.log."
    echo ">> Model server ready on 127.0.0.1:${GROK_PORT}."
  fi

  # Client-side: register the model with grok's config if it isn't there yet.
  # Only [model.*] sections in ~/.grok/config.toml are read (project-scoped
  # .grok/config.toml only supports [mcp_servers]), so this must be global.
  GROK_CONFIG="$HOME/.grok/config.toml"
  ensure_grok_cli
  mkdir -p "$(dirname "$GROK_CONFIG")"
  touch "$GROK_CONFIG"
  if grep -q "^\[model\.${GROK_MODEL_ID}\]" "$GROK_CONFIG" 2>/dev/null; then
    echo ">> Model '$GROK_MODEL_ID' already configured in $GROK_CONFIG."
  else
    echo ">> Adding model '$GROK_MODEL_ID' to $GROK_CONFIG (points at ${GROK_BASE})..."
    cat >>"$GROK_CONFIG" <<EOF

[model.${GROK_MODEL_ID}]
model = "${GROK_MODEL_ID}"
base_url = "${GROK_BASE}/v1"
name = "Qwen3.6-35B-A3B (local)"
description = "grok-local-server.sh's llama-server, on this machine's own GPU"
api_key = "local"
api_backend = "chat_completions"
temperature = 0.7
top_p = 0.95
max_completion_tokens = 32768
context_window = ${GROK_CTX}
stream_tool_calls = false
EOF
  fi

  echo ">> Launching Grok Build locally (model server left running afterward — stays warm)..."
  if [[ -n "$ISOLATE" ]]; then
    # Network isolation: block xAI's own domains only (DNS blackhole in a
    # private mount namespace) so the harness can never phone home to xAI's
    # cloud. Normal internet access, and loopback services (model server,
    # SearXNG), are unaffected.
    echo ">> Network isolation enabled: xAI domains blocked, all other traffic unaffected."
    exec "$SCRIPT_DIR/isolate.sh" xai -- grok -m "$GROK_MODEL_ID"
  else
    exec grok -m "$GROK_MODEL_ID" --disable-web-search
  fi
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

# --- Ollama must be installed on the target host -------------------------------
# If it isn't, offer to run the official installer there. The installer needs
# sudo (it installs the binary and a systemd service), hence remote_exec_tty.
# The service it starts is harmless — step 1 below stops it before launching
# our own configured `ollama serve`.
if ! remote_exec "$REMOTE" 'command -v ollama >/dev/null 2>&1'; then
  echo "!! Ollama is not installed on ${SERVER_LABEL}."
  read -rp "Install it now via the official script (curl https://ollama.com/install.sh | sh, needs sudo)? [Y/n]: " INSTALL_CHOICE
  case "${INSTALL_CHOICE:-Y}" in
    [Yy]*)
      echo ">> Installing Ollama on ${SERVER_LABEL}..."
      if ! remote_exec_tty "$REMOTE" 'curl -fsSL https://ollama.com/install.sh | sh'; then
        echo "!! Ollama install failed on ${SERVER_LABEL}." >&2
        exit 1
      fi
      if ! remote_exec "$REMOTE" 'command -v ollama >/dev/null 2>&1'; then
        echo "!! Install finished but 'ollama' still isn't on PATH on ${SERVER_LABEL}." >&2
        echo "!! Open a fresh shell there and check, then re-run this launcher." >&2
        exit 1
      fi
      ;;
    *) echo "!! Ollama is required — install it on ${SERVER_LABEL} and re-run." >&2; exit 1 ;;
  esac
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
# has the chosen model there. (A function because it re-runs after a pull.)
detect_model_store() {
  remote_script "$REMOTE" <<EOF
for store in /var/lib/ollama/models "\$HOME/.ollama/models"; do
  manifest="\$store/manifests/registry.ollama.ai/library/${MODEL%%:*}/${MODEL##*:}"
  if [[ -f "\$manifest" ]]; then echo "\$store"; break; fi
done
EOF
}
MODEL_STORE="$(detect_model_store)"

# Model not there yet — offer to pull it on the target host. `ollama pull` is a
# client command that needs a server, and WHICH server matters: the pull lands
# in that server's store. The systemd service the official installer sets up
# runs as its own `ollama` user with a private store
# (/usr/share/ollama/.ollama/models, mode 750) that neither detect_model_store
# nor this launcher's user-run `ollama serve` can read — so never pull through
# a pre-existing server. Instead start a temporary user-owned server on a side
# port (11436, no clash with anything on 11434) with OLLAMA_MODELS pinned to
# the user store, pull through it, and stop it afterwards. OLLAMA_HOST covers
# both sides at once: the bind address for `serve` and the target for `pull`.
# Run with a pty so the pull's progress display works.
if [[ -z "$MODEL_STORE" ]]; then
  echo "!! Model '$MODEL' not found in /var/lib/ollama/models or ~/.ollama/models on ${SERVER_LABEL}."
  read -rp "Pull it now ('ollama pull $MODEL' on ${SERVER_LABEL})? [Y/n]: " PULL_CHOICE
  case "${PULL_CHOICE:-Y}" in
    [Yy]*) ;;
    *) echo "!! Pull it there first ('ollama pull $MODEL'), then re-run." >&2; exit 1 ;;
  esac
  PULL_SCRIPT="$(cat <<EOF
set -e
export OLLAMA_MODELS="\$HOME/.ollama/models"
export OLLAMA_HOST="127.0.0.1:11436"
echo '>> Starting a temporary pull server on ${SERVER_LABEL} (:11436, user store)...'
nohup ollama serve >/tmp/ollama-hangarbaycc-pull.log 2>&1 </dev/null &
PULL_SRV=\$!
trap 'kill "\$PULL_SRV" 2>/dev/null || true' EXIT
tries=20
until curl -sf "http://\$OLLAMA_HOST/api/version" >/dev/null 2>&1; do
  tries=\$((tries - 1))
  if [ "\$tries" -le 0 ]; then
    echo '!! Temporary pull server never came up (see /tmp/ollama-hangarbaycc-pull.log).' >&2
    exit 1
  fi
  sleep 0.5
done
# Stale partial downloads (sha256-*-partial* chunk files left by an interrupted
# multi-stream pull) poison Ollama's resume logic: the pull dies with
# 'Error: EOF' right after 'pulling manifest', every time, until they're
# removed. If the pull fails, clear them and retry once from scratch.
if ! ollama pull ${MODEL}; then
  echo '>> Pull failed — clearing stale partial downloads and retrying once...'
  rm -f "\$OLLAMA_MODELS"/blobs/*-partial*
  ollama pull ${MODEL}
fi
EOF
)"
  if ! remote_exec_tty "$REMOTE" "$PULL_SCRIPT"; then
    echo "!! Pull of '$MODEL' failed on ${SERVER_LABEL}." >&2
    exit 1
  fi
  MODEL_STORE="$(detect_model_store)"
  if [[ -z "$MODEL_STORE" ]]; then
    echo "!! Pull finished but the manifest for '$MODEL' still isn't visible on ${SERVER_LABEL}." >&2
    echo "!! Check 'ollama list' there." >&2
    exit 1
  fi
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
# preload "" loads with Ollama's own placement; preload '"num_gpu":99' forces
# every layer onto the GPU, overriding Ollama's fit estimate.
preload() {
  curl -sf "http://${API_HOST}/api/generate" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false${1:+,\"options\":{$1}}}" >/dev/null
}
# Sets SPILL to a description of any CPU spill ("" = fully on GPU); returns
# nonzero if /api/ps itself couldn't be read.
check_spill() {
  SPILL="$(curl -sf "http://${API_HOST}/api/ps" | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("models", []):
    size, vram = m.get("size", 0), m.get("size_vram", 0)
    if vram < size:
        gib = 2 ** 30
        print("%s: %.1f GiB on CPU of %.1f GiB total"
              % (m.get("name"), (size - vram) / gib, size / gib))
')"
}

echo ">> Preloading (allocates the full KV cache)..."
if ! preload ""; then
  echo "!! Preload failed for model '$MODEL' (server returned an error)." >&2
  echo "!! Most likely the model isn't in the store the server is using." >&2
  echo "!!   store in use: ${MODEL_STORE} on ${SERVER_LABEL}" >&2
  echo "!! Check 'ollama list', or 'ollama pull $MODEL' there. See /tmp/ollama-hangarbaycc.log for details." >&2
  exit 1
fi

ollama ps
if ! check_spill; then
  echo "!! Could not verify GPU placement (/api/ps check failed)." >&2
  echo "!! Not launching blind — check /tmp/ollama-hangarbaycc.log on ${SERVER_LABEL} and ollama ps." >&2
  exit 1
fi

# Newer Ollama (0.31+) estimates fit conservatively and parks MoE expert
# tensors in system RAM when VRAM looks tight (e.g. a desktop session holding
# a few hundred MiB) even when the model would actually fit. A spill from that
# estimate — not from being genuinely too big — disappears when the placement
# is forced, so on spill retry once with num_gpu:99 and re-measure. The forced
# placement persists for the session: later requests without the option (i.e.
# everything Claude Code sends) do not trigger a reload. A genuinely too-big
# config either still spills (caught below) or fails to load (caught here).
if [[ -n "$SPILL" ]]; then
  echo ">> Spill detected ($SPILL)."
  echo ">> Retrying with forced full GPU offload (num_gpu 99) — Ollama's fit estimate is often conservative..."
  ollama stop "$MODEL" 2>/dev/null || true
  if ! preload '"num_gpu":99'; then
    echo "!! Forced full-GPU load failed — this context/KV combination genuinely does not fit." >&2
    echo "!! Re-run and pick a smaller context and/or more compressed KV cache." >&2
    exit 1
  fi
  ollama ps
  if ! check_spill; then
    echo "!! Could not verify GPU placement (/api/ps check failed)." >&2
    echo "!! Not launching blind — check /tmp/ollama-hangarbaycc.log on ${SERVER_LABEL} and ollama ps." >&2
    exit 1
  fi
fi
if [[ -n "$SPILL" ]]; then
  echo "!! $NUM_CTX tokens spilled to CPU — too big for 16 GB VRAM even when forced:" >&2
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
OLLAMA_EXTRA_ARGS=()
[[ -n "$WEBSEARCH_ENABLED" ]] && OLLAMA_EXTRA_ARGS+=(--mcp-config "$SEARXNG_MCP_JSON")
if [[ -f "$EDIT_RULES" ]]; then
  echo ">> Appending editing rules from $EDIT_RULES"
  echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${DISALLOWED_TOOLS[*]}"
  # Args after `--` are forwarded to Claude Code itself (ollama launch passes
  # them through). The flags are NOT `ollama launch` flags, so they go here.
  ollama launch claude --model "$MODEL" -y -- \
    --settings "$LAUNCH_SETTINGS" \
    --append-system-prompt "$(cat "$EDIT_RULES")" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}" \
    "${OLLAMA_EXTRA_ARGS[@]}"
else
  echo "!! $EDIT_RULES not found — launching without the editing-rules prompt." >&2
  echo ">> Stripping tools at the proxy (and auto-denying as backstop): ${DISALLOWED_TOOLS[*]}"
  ollama launch claude --model "$MODEL" -y -- \
    --settings "$LAUNCH_SETTINGS" \
    --disallowedTools "${DISALLOWED_TOOLS[@]}" \
    "${OLLAMA_EXTRA_ARGS[@]}"
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
