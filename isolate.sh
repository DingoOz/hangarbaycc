#!/usr/bin/env bash
#
# isolate.sh — network isolation wrapper for grok-local
#
# Usage:
#   isolate.sh [blocklist ...] -- command [args...]
#
# Applies nftables cgroup-based OUTPUT rules that block the specified
# domains/IPs while allowing all other traffic. By default, blocks xAI
# traffic (api.x.ai) to prevent data exfiltration.
#
# Blocklist entries can be:
#   api.x.ai            — specific domain/IP to block
#   xai                 — shorthand for all xAI domains
#   any / loopback      — block all external traffic (allow only loopback)
#
# Requires: root (for nftables + cgroup creation)
#
# Exit codes:
#   0  — command exited successfully
#   1  — isolation setup failed (falls through to running command without isolation)
#   N  — command exit code (passed through)

set -euo pipefail

# --- Helpers ------------------------------------------------------------------

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

# Default: block xAI traffic
if [[ ${#BLOCKLIST[@]} -eq 0 ]]; then
  BLOCKLIST=("api.x.ai")
fi

if [[ ${#COMMAND[@]} -eq 0 ]]; then
  echo "Usage: $0 [blocklist ...] -- command [args...]" >&2
  exit 1
fi

# --- Prepare nftables ---------------------------------------------------------

NFT_TABLE="hangarbaycc-isolate"
CGROUP_NAME="hangarbaycc-isolate-$$"
CLEANED_UP=0

cleanup() {
  if [[ $CLEANED_UP -eq 1 ]]; then return; fi
  CLEANED_UP=1
  log "Tearing down isolation..."
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  sudo rm -rf "/sys/fs/cgroup/$CGROUP_NAME" 2>/dev/null || true
  log "Isolation removed."
}
trap cleanup EXIT

# --- Resolve domains to IPs ---------------------------------------------------

resolve_domain() {
  local domain="$1"
  local ip
  ip=$(getent ahostsv4 "$domain" 2>/dev/null | head -1 | awk '{print $1}')
  if [[ -z "$ip" ]]; then
    warn "Could not resolve domain: $domain"
    return 1
  fi
  echo "$ip"
}

# --- Set up nftables rules ----------------------------------------------------

setup_nftables() {
  # Clean up any stale table from a previous failed run (prevents duplicate rules)
  sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true

  # Create table and chain with policy ACCEPT (allow everything by default)
  sudo nft add table inet "$NFT_TABLE"
  sudo nft add chain inet "$NFT_TABLE" output \
    '{ type filter hook output priority filter; policy accept; }'

  # Verify the table was actually created
  if ! sudo nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    warn "nftables table '$NFT_TABLE' was not created — setup failed"
    return 1
  fi

  log "nftables table '$NFT_TABLE' created (policy: accept)"

  # Create a set for blocked destinations
  sudo nft add set inet "$NFT_TABLE" blocked_ips '{ type ipv4_addr; flags interval; }'
  sudo nft add set inet "$NFT_TABLE" blocked_ports '{ type inet_service; flags interval; }'

  # Add blocklist entries to the set
  FULL_BLOCK=0
  for entry in "${BLOCKLIST[@]}"; do
    case "$entry" in
      xai)
        # Block all xAI domains
        local xai_ips
        xai_ips=$(resolve_domain "api.x.ai" 2>/dev/null || true)
        if [[ -n "$xai_ips" ]]; then
          sudo nft add element inet "$NFT_TABLE" blocked_ips "{ $xai_ips }"
          log "Blocked xAI API (api.x.ai -> $xai_ips)"
        fi
        # Also block x.ai domain
        local x_ai_ips
        x_ai_ips=$(resolve_domain "x.ai" 2>/dev/null || true)
        if [[ -n "$x_ai_ips" ]]; then
          sudo nft add element inet "$NFT_TABLE" blocked_ips "{ $x_ai_ips }"
          log "Blocked x.ai domain ($x_ai_ips)"
        fi
        ;;
      any|loopback)
        FULL_BLOCK=1
        log "Will block all external traffic (allow only loopback) for cgroup"
        ;;
      *)
        # Block specific domain/IP
        local ip
        ip=$(resolve_domain "$entry" 2>/dev/null || echo "$entry")
        sudo nft add element inet "$NFT_TABLE" blocked_ips "{ $ip }"
        log "Blocked $entry -> $ip"
        ;;
    esac
  done

  # Rules are applied later (after cgroup is created) via apply_cgroup_rules()
  # so they only affect the isolated process, not the whole system.
  log "Blocklist set populated. Cgroup-aware rules will be applied after cgroup is created."
}

# --- Apply cgroup-aware nftables rules ----------------------------------------

# This MUST be called after create_cgroup() so we can reference the cgroup name.
# Rules use 'socket cgroupv2' matching so they only affect the isolated process.
apply_cgroup_rules() {
  if [[ "$FULL_BLOCK" -eq 1 ]]; then
    # Block everything except loopback for this cgroup only
    sudo nft add rule inet "$NFT_TABLE" output \
      socket cgroupv2 level 1 "$CGROUP_NAME" ip daddr != 127.0.0.0/8 drop
    log "Added cgroup rule: drop non-loopback for $CGROUP_NAME"
  else
    # Block only the IPs in blocked_ips for this cgroup
    sudo nft add rule inet "$NFT_TABLE" output \
      socket cgroupv2 level 1 "$CGROUP_NAME" ip daddr @blocked_ips drop
    log "Added cgroup rule: drop blocked_ips for $CGROUP_NAME"
  fi
}

# --- Create cgroup and move process into it -----------------------------------

create_cgroup() {
  # Create the cgroup directory
  sudo mkdir "/sys/fs/cgroup/$CGROUP_NAME"

  # Move the calling shell's process into it
  echo $$ | sudo tee "/sys/fs/cgroup/$CGROUP_NAME/cgroup.procs" >/dev/null

  # Verify the move worked
  if [[ "$(cat /proc/self/cgroup | grep "$CGROUP_NAME")" != "" ]]; then
    log "Created cgroup '$CGROUP_NAME' and moved shell into it"
    return 0
  fi

  warn "Shell may not have moved into cgroup — isolation may not work"
  return 1
}

# --- Verify nftables socket cgroupv2 support ----------------------------------

test_cgroup_support() {
  local test_cgroup="hangarbaycc-cgroup-test-$$"

  # Create a test cgroup
  sudo mkdir "/sys/fs/cgroup/$test_cgroup" 2>/dev/null || return 0

  # Try matching against it
  sudo nft add table inet test-cgroup 2>/dev/null || {
    sudo rm -rf "/sys/fs/cgroup/$test_cgroup" 2>/dev/null || true
    return 0
  }
  sudo nft add chain inet test-cgroup output \
    '{ type filter hook output priority filter; policy accept; }' 2>/dev/null || {
    sudo nft delete table inet test-cgroup 2>/dev/null || true
    sudo rm -rf "/sys/fs/cgroup/$test_cgroup" 2>/dev/null || true
    return 0
  }

  # Level 1 = top-level cgroup name (the name we used in mkdir)
  sudo nft add rule inet test-cgroup output socket cgroupv2 level 1 "$test_cgroup" drop 2>/dev/null && {
    # Success — cgroupv2 matching works
    sudo nft delete table inet test-cgroup 2>/dev/null || true
    sudo rm -rf "/sys/fs/cgroup/$test_cgroup" 2>/dev/null || true
    return 0
  }

  # Failed
  sudo nft delete table inet test-cgroup 2>/dev/null || true
  sudo rm -rf "/sys/fs/cgroup/$test_cgroup" 2>/dev/null || true
  warn "socket cgroupv2 matching not supported on this kernel"
  return 1
}

# --- Main ---------------------------------------------------------------------

log "Setting up network isolation..."

if ! setup_nftables; then
  warn "nftables setup failed — running command without network isolation"
  exec "${COMMAND[@]}"
fi

if ! test_cgroup_support; then
  warn "Cgroup v2 matching test failed — falling back to no isolation"
  cleanup
  exec "${COMMAND[@]}"
fi

if ! create_cgroup; then
  warn "Failed to create cgroup — falling back to no isolation"
  cleanup
  exec "${COMMAND[@]}"
fi

# Apply nftables rules AFTER cgroup is created, so they reference the correct cgroup.
# Rules use 'socket cgroupv2' matching — they only affect processes in this cgroup,
# not the entire system.
apply_cgroup_rules

log "Isolation active. Blocked: ${BLOCKLIST[*]}"
log "Cgroup: $CGROUP_NAME"

# --- Execute command ----------------------------------------------------------

# We're already in the cgroup (the shell moved itself in).
# exec replaces this shell with the command, which inherits the cgroup.
exec "${COMMAND[@]}"
