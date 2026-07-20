#!/usr/bin/env bash
#
# grok-local-unload.sh — stops the llama-server started by
# grok-local-server.sh, freeing its VRAM immediately without waiting on
# GROK_LOCAL_TIMEOUT. Safe to run whether or not a server is currently up.
#
# Usage:
#   ./grok-local-unload.sh          # default port 8080
#   ./grok-local-unload.sh 8080     # explicit port
set -euo pipefail

PORT="${1:-8080}"

if curl -sf -m 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
  sleep 1
  if curl -sf -m 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "!! Server on port ${PORT} did not stop." >&2
    exit 1
  fi
  echo ">> Model server on port ${PORT} stopped."
else
  echo ">> No model server running on port ${PORT}."
fi
