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
#   any                 — block all external traffic (default when no entries given)
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

  # Add blocklist entries
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
      any)
        # Block everything except loopback
        sudo nft add rule inet "$NFT_TABLE" output oif lo accept
        sudo nft add rule inet "$NFT_TABLE" output ip daddr 127.0.0.0/8 accept
        log "Blocking all external traffic (allow only loopback)"
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

  # Add the final drop rule for blocked destinations
  sudo nft add rule inet "$NFT_TABLE" output ip daddr @blocked_ips drop

  # Verify rules were applied
  local rule_count
  rule_count=$(sudo nft list chain inet "$NFT_TABLE" output 2>/dev/null | grep -c "accept\|drop\|set" || true)
  log "Applied $rule_count rules to '$NFT_TABLE'"
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

log "Isolation active. Blocked: ${BLOCKLIST[*]}"
log "Cgroup: $CGROUP_NAME"

# --- Execute command ----------------------------------------------------------

# We're already in the cgroup (the shell moved itself in).
# exec replaces this shell with the command, which inherits the cgroup.
exec "${COMMAND[@]}"
