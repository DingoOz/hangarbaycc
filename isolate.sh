#!/usr/bin/env bash
#
# isolate.sh — network isolation wrapper for grok-local
#
# Usage:
#   isolate.sh [blocklist ...] -- command [args...]
#
# Creates a network namespace with only loopback, then uses socat to
# forward the specific ports the command needs (model server, SearXNG).
# All other outbound traffic is impossible — the namespace has no
# external network interface.
#
# Blocklist entries can be:
#   api.x.ai            — specific domain/IP to block
#   xai                 — shorthand for all xAI domains
#   any / loopback      — block all external traffic (allow only loopback)
#
# Requires: root (for network namespace creation + socat)
#
# Exit codes:
#   0  — command exited successfully
#   1  — isolation setup failed (falls through to running command without isolation)
#   N  — command exit code (passed through)

set -euo pipefail

log()  { echo ">> isolate.sh: $*"; }
warn() { echo ">> isolate.sh: WARNING: $*" >&2; }

# --- Parse arguments ----------------------------------------------------------

BLOCKLIST=()
COMMAND=()
PARSING_BLOCKLIST=1

for arg in "$@"; do
  if [[ "$arg" == "--" ]]; then
    PARSING_BLOCKLIST=0
    continue
  fi
  if [[ $PARSING_BLOCKLIST -eq 1 ]]; then
    BLOCKLIST+=("$arg")
  else
    COMMAND+=("$arg")
  fi
done

if [[ ${#BLOCKLIST[@]} -eq 0 ]]; then
  BLOCKLIST=("api.x.ai")
fi

if [[ ${#COMMAND[@]} -eq 0 ]]; then
  echo "Usage: $0 [blocklist ...] -- command [args...]" >&2
  exit 1
fi

# --- Check prerequisites ------------------------------------------------------

check_prereqs() {
  for cmd in socat ip; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "'$cmd' not found — cannot set up network namespace isolation"
      return 1
    fi
  done

  # Verify we can create a network namespace
  if ! sudo ip netns add "__hangarbaycc-test-$$" 2>/dev/null; then
    warn "Cannot create network namespace — need root privileges"
    return 1
  fi
  sudo ip netns delete "__hangarbaycc-test-$$" 2>/dev/null || true
  return 0
}

# --- Main ---------------------------------------------------------------------

NETNS="hangarbaycc-$$"
NS_LO_UP=0
NS_SOCATS=()
CLEANED_UP=0

cleanup() {
  if [[ $CLEANED_UP -eq 1 ]]; then return; fi
  CLEANED_UP=1
  log "Tearing down isolation..."

  # Kill socat forwarders
  for pid in "${NS_SOCATS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  # Bring down loopback in namespace
  if [[ $NS_LO_UP -eq 1 ]]; then
    sudo ip netns exec "$NETNS" ip link set lo down 2>/dev/null || true
  fi

  # Delete namespace
  sudo ip netns delete "$NETNS" 2>/dev/null || true

  log "Isolation removed."
}
trap cleanup EXIT

log "Setting up network namespace isolation..."

if ! check_prereqs; then
  warn "Running command without network isolation"
  exec "${COMMAND[@]}"
fi

# Create network namespace
sudo ip netns add "$NETNS"
log "Created network namespace '$NETNS'"

# Bring up loopback inside the namespace
sudo ip netns exec "$NETNS" ip link set lo up
NS_LO_UP=1
log "Loopback up in namespace"

# Determine which local ports the isolated process needs to reach.
# The command connects to 127.0.0.1 in its own namespace, which only has lo.
# We need socat to forward those ports to the HOST's 127.0.0.1.
#
# Default ports needed for hangarbaycc:
#   8080 = grok-local model server (localhost on host)
#   8888 = SearXNG (localhost on host)
NEEDED_PORTS=(8080 8888)

# Also check what's actually listening on 127.0.0.1
while read -r local_addr; do
  port="${local_addr##*:}"
  # Add if not already in the list
  local found=0
  for p in "${NEEDED_PORTS[@]}"; do
    [[ "$p" == "$port" ]] && found=1 && break
  done
  if [[ $found -eq 0 ]]; then
    NEEDED_PORTS+=("$port")
  fi
done < <(ss -tlnH sport = 127.0.0.1:* 2>/dev/null | awk '{print $4}' | grep -v 'Local' || true)

# Start socat forwarders: namespace-127.0.0.1:<port> -> host-127.0.0.1:<port>
# We use the SAME port in the namespace as on the host. The namespace has its own
# network stack, so port 8080 in the namespace does NOT conflict with port 8080
# on the host — they are completely separate sockets.
for port in "${NEEDED_PORTS[@]}"; do
  sudo ip netns exec "$NETNS" socat \
    TCP-LISTEN:${port},fork,reuseaddr,bind=127.0.0.1 \
    TCP:127.0.0.1:${port} &
  NS_SOCATS+=($!)
  log "Forwarding ns:127.0.0.1:${port} -> host:127.0.0.1:${port} (socat pid ${NS_SOCATS[-1]})"
done

log "Isolation active. Namespace '$NETNS' has only loopback."
log "All connections to 127.0.0.1 in the namespace are forwarded to the host."

# --- Execute command in namespace ---------------------------------------------

# The command runs inside the namespace. It only sees loopback.
# All 127.0.0.1:<port> connections are forwarded to the host's 127.0.0.1:<port>.
# The command uses the same ports as normal — no configuration needed.
log "Launching command in isolated namespace..."
exec sudo ip netns exec "$NETNS" env PATH="$PATH" HOME="$HOME" LANG="$LANG" "${COMMAND[@]}"
