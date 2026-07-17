#!/usr/bin/env bash
#
# isolate.sh — network isolation wrapper for the grok harness
#
# Usage:
#   isolate.sh [blocklist ...] -- command [args...]
#
# Two independent modes, chosen by the blocklist contents:
#
#   any | loopback  — full lockdown. Runs the command in a network namespace
#                      that has only loopback; socat forwards 127.0.0.1:<port>
#                      inside the namespace to the host's 127.0.0.1:<port> so
#                      local services (model server, SearXNG) stay reachable.
#                      No other traffic — inbound or outbound — is possible.
#
#   <domain> | xai   — targeted blocklist (the default). The command keeps
#                      the host's normal network namespace, so real internet
#                      access and loopback services all work exactly as
#                      normal. It runs under a private mount namespace with
#                      two DNS-blocking layers laid over it:
#                        1. A scoped dnsmasq instance (127.0.0.2:53) that
#                           wildcard-resolves each blocklist domain AND ALL
#                           ITS SUBDOMAINS to 127.0.0.1, forwarding everything
#                           else upstream. This is the layer that matters —
#                           clients call subdomains (cli-chat-proxy.grok.com,
#                           api.x.ai, ...), not just the apex domain.
#                        2. A bind-mounted /etc/hosts with known concrete
#                           subdomains blackholed too, as an exact-match
#                           fallback if dnsmasq isn't available.
#                      "xai" expands to XAI_DOMAINS (dnsmasq layer) and
#                      XAI_KNOWN_SUBDOMAINS (hosts layer) below. Only the
#                      launched command's own view is affected — the host's
#                      real /etc/hosts and /etc/resolv.conf are never touched.
#
#      Caveat: this is DNS-level blocking. It stops the harness resolving
#      the blocked hostnames via the normal system resolver (what grok, curl,
#      and virtually everything else use), but it does not inspect traffic,
#      so a hardcoded IP literal or a DNS-over-HTTPS resolver embedded in the
#      client would bypass it. Good enough to stop the harness talking to
#      xAI's cloud by accident; not a substitute for a firewall if the
#      threat model includes an adversarial binary.
#
# Requires: root (network/mount namespace creation); dnsmasq for the
# wildcard layer (falls back to the weaker hosts-only layer if absent).
#
# Exit codes:
#   0  — command exited successfully
#   1  — isolation setup failed (falls through to running command without isolation)
#   N  — command exit code (passed through)

set -euo pipefail

log()  { echo ">> isolate.sh: $*"; }
warn() { echo ">> isolate.sh: WARNING: $*" >&2; }

# xAI's own domains — the harness must never be able to reach these, since
# the whole point of hangarbaycc is running a *local* model behind the grok
# CLI, not xAI's cloud. Only the two apex domains are needed: the DNS
# wildcard layer below blocks every subdomain of each automatically (the
# grok binary itself calls a bunch of them — cli-chat-proxy.grok.com,
# assets.grok.com, computer-hub.grok.com, api.x.ai, accounts.x.ai,
# auth.x.ai, console.x.ai, docs.x.ai — confirmed via `strings` on the
# installed binary; an exact-match list would always be one subdomain
# behind whatever xAI adds next).
XAI_DOMAINS=(x.ai grok.com)

# Concrete subdomains, for the /etc/hosts fallback layer only (used if
# dnsmasq isn't available to do real wildcard blocking — see below).
XAI_KNOWN_SUBDOMAINS=(
  www.x.ai api.x.ai accounts.x.ai auth.x.ai console.x.ai docs.x.ai
  www.grok.com cli-chat-proxy.grok.com assets.grok.com code.grok.com
  computer-hub.grok.com app-builder-deployer.grok.com
)

# --- Parse arguments -----------------------------------------------------------

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
  BLOCKLIST=("xai")
fi

if [[ ${#COMMAND[@]} -eq 0 ]]; then
  echo "Usage: $0 [blocklist ...] -- command [args...]" >&2
  exit 1
fi

# DOMAINS: apex domains — wildcard-blocked via DNS (covers every subdomain).
# HOSTS_DOMAINS: DOMAINS plus known concrete subdomains, blocked via a literal
# /etc/hosts entry too, as a fallback layer in case dnsmasq isn't available.
FULL_BLOCK=0
DOMAINS=()
HOSTS_DOMAINS=()
for entry in "${BLOCKLIST[@]}"; do
  case "$entry" in
    any|loopback) FULL_BLOCK=1 ;;
    xai)
      DOMAINS+=("${XAI_DOMAINS[@]}")
      HOSTS_DOMAINS+=("${XAI_DOMAINS[@]}" "${XAI_KNOWN_SUBDOMAINS[@]}")
      ;;
    *)
      DOMAINS+=("$entry")
      HOSTS_DOMAINS+=("$entry")
      ;;
  esac
done

ORIGINAL_UID="$(id -u)"
ORIGINAL_GID="$(id -g)"
ORIGINAL_USER="$(id -un)"
ORIGINAL_HOME="$HOME"

CLEANED_UP=0
CMD_EXIT=0

# --- Mode: any/loopback — full lockdown via network namespace ------------------

run_full_block() {
  for cmd in socat ip; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "'$cmd' not found — cannot set up network namespace isolation"
      warn "Running command without network isolation"
      CMD_EXIT=0
      "${COMMAND[@]}" || CMD_EXIT=$?
      exit "$CMD_EXIT"
    fi
  done

  if ! sudo ip netns add "__hangarbaycc-test-$$" 2>/dev/null; then
    warn "Cannot create network namespace — need root privileges"
    warn "Running command without network isolation"
    CMD_EXIT=0
    "${COMMAND[@]}" || CMD_EXIT=$?
    exit "$CMD_EXIT"
  fi
  sudo ip netns delete "__hangarbaycc-test-$$" 2>/dev/null || true

  local netns="hangarbaycc-$$"
  local ns_lo_up=0
  local ns_socats=()

  cleanup() {
    if [[ $CLEANED_UP -eq 1 ]]; then return; fi
    CLEANED_UP=1
    log "Tearing down isolation..."
    for pid in "${ns_socats[@]}"; do
      sudo kill "$pid" 2>/dev/null || true
    done
    if [[ $ns_lo_up -eq 1 ]]; then
      sudo ip netns exec "$netns" ip link set lo down 2>/dev/null || true
    fi
    sudo ip netns delete "$netns" 2>/dev/null || true
    log "Isolation removed."
  }
  trap cleanup EXIT

  log "Setting up network namespace isolation..."
  sudo ip netns add "$netns"
  log "Created network namespace '$netns'"

  sudo ip netns exec "$netns" ip link set lo up
  ns_lo_up=1
  log "Loopback up in namespace"

  # Local ports the isolated process needs to reach: 8080 (grok-local model
  # server), 8888 (SearXNG), plus anything else already listening on the
  # host's 127.0.0.1.
  local needed_ports=(8080 8888)
  while read -r local_addr; do
    local port="${local_addr##*:}"
    local found=0
    for p in "${needed_ports[@]}"; do
      [[ "$p" == "$port" ]] && found=1 && break
    done
    [[ $found -eq 0 ]] && needed_ports+=("$port")
  done < <(ss -tlnH sport = 127.0.0.1:* 2>/dev/null | awk '{print $4}' | grep -v 'Local' || true)

  for port in "${needed_ports[@]}"; do
    sudo ip netns exec "$netns" socat \
      TCP-LISTEN:${port},fork,reuseaddr,bind=127.0.0.1 \
      TCP:127.0.0.1:${port} &
    ns_socats+=($!)
    log "Forwarding ns:127.0.0.1:${port} -> host:127.0.0.1:${port} (socat pid ${ns_socats[-1]})"
  done

  log "Isolation active. Namespace '$netns' has only loopback."
  log "Launching command in isolated namespace..."
  sudo ip netns exec "$netns" env PATH="$PATH" HOME="$HOME" LANG="$LANG" "${COMMAND[@]}" || CMD_EXIT=$?
  exit "$CMD_EXIT"
}

# --- Mode: domain blocklist — DNS wildcard block + hosts fallback --------------

# Loopback alias dnsmasq listens on for the blocking resolver. Not the
# systemd-resolved stub (127.0.0.53) or any other address anything else on
# this host uses, so it can't collide with an already-bound port 53.
DNSMASQ_ADDR="127.0.0.2"

run_domain_block() {
  for cmd in unshare setpriv; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "'$cmd' not found — cannot set up domain blocking"
      warn "Running command without network isolation"
      "${COMMAND[@]}" || CMD_EXIT=$?
      exit "$CMD_EXIT"
    fi
  done

  if ! sudo true 2>/dev/null; then
    warn "Cannot get root — need sudo privileges"
    warn "Running command without network isolation"
    "${COMMAND[@]}" || CMD_EXIT=$?
    exit "$CMD_EXIT"
  fi

  # Layer 1 (fallback): literal /etc/hosts entries for known concrete
  # subdomains. Only catches exact names — kept in case layer 2 can't start.
  local hosts_file
  hosts_file="$(mktemp /tmp/hangarbaycc-isolate-hosts.XXXXXX)"
  cp /etc/hosts "$hosts_file"
  {
    echo ""
    echo "# --- hangarbaycc isolate.sh: blocked for grok harness ---"
    for d in "${HOSTS_DOMAINS[@]}"; do
      echo "127.0.0.1 $d"
    done
  } >>"$hosts_file"

  # Layer 2 (primary): a dnsmasq instance that wildcard-blocks every
  # subdomain of each apex DOMAINS entry and forwards everything else to the
  # host's real upstream resolver — this is what actually stops
  # cli-chat-proxy.grok.com, assets.grok.com, and any future xAI subdomain
  # that isn't in the static hosts list above.
  local resolv_file dnsmasq_pid=""
  resolv_file="$(mktemp /tmp/hangarbaycc-isolate-resolv.XXXXXX)"
  cp /etc/resolv.conf "$resolv_file"

  if command -v dnsmasq &>/dev/null; then
    local upstream=()
    while read -r ns; do upstream+=("--server=$ns"); done \
      < <(awk '/^nameserver/{print $2}' /etc/resolv.conf)
    [[ ${#upstream[@]} -eq 0 ]] && upstream=("--server=1.1.1.1")

    local wildcard_args=()
    for d in "${DOMAINS[@]}"; do
      wildcard_args+=("--address=/${d}/127.0.0.1")
    done

    sudo dnsmasq --no-daemon --keep-in-foreground \
      --listen-address="$DNSMASQ_ADDR" --port=53 --bind-interfaces \
      --no-hosts --no-resolv "${upstream[@]}" "${wildcard_args[@]}" \
      &>/tmp/hangarbaycc-isolate-dnsmasq.log &
    dnsmasq_pid=$!

    # Liveness (kill -0) is the portable check: dnsmasq exits immediately on
    # a bind failure, so "still running" after a moment is a solid signal it
    # bound :53 successfully. `dig`, if present, adds a real end-to-end query
    # on top — but its absence shouldn't fail an otherwise-working setup.
    sleep 0.3
    local ready=0
    if kill -0 "$dnsmasq_pid" 2>/dev/null; then
      ready=1
      if command -v dig &>/dev/null; then
        ready=0
        for _ in $(seq 1 20); do
          if dig @"$DNSMASQ_ADDR" -p 53 +time=1 +tries=1 +short example.com &>/dev/null; then
            ready=1
            break
          fi
          kill -0 "$dnsmasq_pid" 2>/dev/null || break
          sleep 0.2
        done
      fi
    fi
    if [[ $ready -eq 1 ]]; then
      echo "nameserver $DNSMASQ_ADDR" >"$resolv_file"
      log "Wildcard DNS block active for: ${DOMAINS[*]} (and all their subdomains)"
    else
      warn "dnsmasq didn't come up — falling back to the /etc/hosts layer only (see /tmp/hangarbaycc-isolate-dnsmasq.log)"
      sudo kill "$dnsmasq_pid" 2>/dev/null || true
      dnsmasq_pid=""
    fi
  else
    warn "dnsmasq not found — falling back to the /etc/hosts layer only (won't catch unlisted subdomains)"
  fi

  local helper
  helper="$(mktemp /tmp/hangarbaycc-isolate-run.XXXXXX)"
  cat >"$helper" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
hosts_file="$1"; shift
resolv_file="$1"; shift
uid="$1"; shift
gid="$1"; shift
user="$1"; shift
home="$1"; shift
path="$1"; shift
mount --bind "$hosts_file" /etc/hosts
mount --bind "$resolv_file" /etc/resolv.conf
exec setpriv --reuid "$uid" --regid "$gid" --init-groups --inh-caps=-all -- \
  env PATH="$path" HOME="$home" USER="$user" LOGNAME="$user" "$@"
HELPER
  chmod +x "$helper"

  cleanup() {
    if [[ $CLEANED_UP -eq 1 ]]; then return; fi
    CLEANED_UP=1
    [[ -n "$dnsmasq_pid" ]] && sudo kill "$dnsmasq_pid" 2>/dev/null
    rm -f "$hosts_file" "$resolv_file" "$helper" /tmp/hangarbaycc-isolate-dnsmasq.log
  }
  trap cleanup EXIT

  log "Blocking: ${DOMAINS[*]}"
  log "Everything else — internet, loopback services — passes through normally."
  # sudo resets PATH/HOME/USER (secure_path, HOME=/root) — grok would then
  # try to read config from a home directory this user can't access. Pass
  # the caller's real values through explicitly rather than relying on sudo's.
  sudo unshare --mount --propagation private -- \
    "$helper" "$hosts_file" "$resolv_file" \
    "$ORIGINAL_UID" "$ORIGINAL_GID" "$ORIGINAL_USER" "$ORIGINAL_HOME" "$PATH" \
    "${COMMAND[@]}" || CMD_EXIT=$?
  exit "$CMD_EXIT"
}

# --- Main ------------------------------------------------------------------

if [[ $FULL_BLOCK -eq 1 ]]; then
  run_full_block
else
  run_domain_block
fi
