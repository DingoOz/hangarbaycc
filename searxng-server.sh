#!/usr/bin/env bash
#
# searxng-server.sh — starts (or reuses) a SearXNG docker container providing
# the JSON search API behind the web-search MCP tool (searxng-mcp/server.py).
# Mounts searxng-settings.yml (vendored in this repo) to enable the JSON
# format, which SearXNG disables by default.
#
# Runs on whichever host actually needs it: called directly for the
# grok-local backend (this machine, 127.0.0.1); piped over SSH via
# remote_script for every other backend (ml-server), with
# SEARXNG_BIND_ADDR=0.0.0.0 so the LAN can reach it — same posture as
# whisper-server/mesh-llm's remote binds elsewhere in this repo.
#
# Idempotent and fast: `docker run -d` is already backgrounded by the Docker
# daemon, so unlike grok-local-server.sh (execs a foreground process the
# caller backgrounds with setsid/nohup), this script just ensures the
# container exists and is running, then exits — the caller polls
# /search?format=json itself to confirm readiness.
set -euo pipefail

# When DOCKER_SG=1 (set by ensure_docker when the session predates docker group
# membership), wrap every docker call with 'sg docker' so it runs with the
# group active.  This is a local-only workaround — remote hosts via SSH always
# start a fresh login session with the group already active.
if [[ "${DOCKER_SG:-}" == "1" ]]; then
  docker() { sg docker -c "docker $*"; }
fi

PORT="${SEARXNG_PORT:-8888}"
BIND_ADDR="${SEARXNG_BIND_ADDR:-127.0.0.1}"
BASE_URL="${SEARXNG_BASE_URL:-http://${BIND_ADDR}:${PORT}/}"
CONTAINER_NAME="${SEARXNG_CONTAINER_NAME:-hangarbaycc-searxng}"
IMAGE="${SEARXNG_IMAGE:-docker.io/searxng/searxng:latest}"
SETTINGS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/searxng-settings.yml"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  # Container is running — verify SearXNG is actually responding
  if curl -sf -m 3 "${BASE_URL}search?q=test&format=json" >/dev/null 2>&1; then
    echo ">> $CONTAINER_NAME already running and healthy."
    exit 0
  fi
  echo ">> $CONTAINER_NAME running but not responding — restarting..."
  docker restart "$CONTAINER_NAME" >/dev/null
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo ">> Starting existing (stopped) $CONTAINER_NAME container..."
  docker start "$CONTAINER_NAME" >/dev/null
  exit 0
fi

echo ">> Creating $CONTAINER_NAME container (${BIND_ADDR}:${PORT}, JSON API enabled)..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${BIND_ADDR}:${PORT}:8080" \
  -v "${SETTINGS_FILE}:/etc/searxng/settings.yml:ro" \
  -e "SEARXNG_BASE_URL=${BASE_URL}" \
  "$IMAGE" >/dev/null
