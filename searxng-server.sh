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
# Uses --network host to avoid Docker iptables NAT issues. The container
# binds directly to the host's network stack.
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

PORT="${SEARXNG_PORT:-8889}"
BIND_ADDR="${SEARXNG_BIND_ADDR:-127.0.0.1}"
BASE_URL="${SEARXNG_BASE_URL:-http://${BIND_ADDR}:${PORT}/}"
CONTAINER_NAME="${SEARXNG_CONTAINER_NAME:-hangarbaycc-searxng}"
IMAGE="${SEARXNG_IMAGE:-docker.io/searxng/searxng:latest}"
SETTINGS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/searxng-settings.yml"

# Something other than our own container may already be bound to this port
# (e.g. an unrelated, independently-managed SearXNG deployment on the host).
# If it already answers JSON search queries AT THE ADDRESS WE'LL ACTUALLY BE
# TOLD TO USE (BASE_URL — 127.0.0.1 for the local grok-local backend, the
# host's LAN IP for everyone else via ml-server), reuse it rather than
# fighting it for the port — `docker run -p` would just fail with "port is
# already allocated" otherwise, and there's no need for a second instance.
# Deliberately NOT hardcoded to 127.0.0.1: a pre-existing SearXNG bound only
# to loopback would match that check (this script often runs on the target
# host itself, over SSH) yet be unreachable to LAN callers, causing the
# caller's wait_for_http to silently poll the real BASE_URL for up to two
# minutes with no output — indistinguishable from a hang.
if curl -fsS --max-time 3 "${BASE_URL%/}/search?q=test&format=json" \
    2>/dev/null | grep -q '"query"'; then
  echo ">> Something is already serving JSON-capable SearXNG at ${BASE_URL} — reusing it."
  exit 0
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  # Container is running — verify SearXNG is actually responding
  if curl -sf -m 3 "${BASE_URL}search?q=test&format=json" >/dev/null 2>&1; then
    echo ">> $CONTAINER_NAME already running and healthy."
    exit 0
  fi
  echo ">> $CONTAINER_NAME running but not responding — restarting..."
  docker restart "$CONTAINER_NAME" >/dev/null
  echo ">> Waiting for $CONTAINER_NAME to become healthy..."
  tries=120
  until curl -sf -m 3 "${BASE_URL}search?q=test&format=json" >/dev/null 2>&1; do
    tries=$((tries - 1))
    if [[ $tries -le 0 ]]; then
      echo "!! $CONTAINER_NAME did not become healthy after restart." >&2
      return 1
    fi
    sleep 0.5
  done
  echo ">> $CONTAINER_NAME is healthy after restart."
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo ">> Starting existing (stopped) $CONTAINER_NAME container..."
  docker start "$CONTAINER_NAME" >/dev/null
  echo ">> Waiting for $CONTAINER_NAME to become healthy..."
  tries=120
  until curl -sf -m 3 "${BASE_URL}search?q=test&format=json" >/dev/null 2>&1; do
    tries=$((tries - 1))
    if [[ $tries -le 0 ]]; then
      echo "!! $CONTAINER_NAME did not become healthy after start." >&2
      return 1
    fi
    sleep 0.5
  done
  echo ">> $CONTAINER_NAME is healthy after start."
  exit 0
fi

echo ">> Creating $CONTAINER_NAME container (:${PORT}, JSON API enabled)..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --network host \
  -e SEARXNG_PORT=${PORT} \
  -v "${SETTINGS_FILE}:/etc/searxng/settings.yml:ro" \
  -e "SEARXNG_BASE_URL=${BASE_URL}" \
  "$IMAGE" >/dev/null
