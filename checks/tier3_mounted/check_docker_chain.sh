#!/usr/bin/env bash
# check_docker_chain.sh — Tier 3, needs the bouncer's own config+log mounted read-only.
#
# The single most-reported CrowdSec problem: firewall bouncer registered but
# Docker-proxied HTTP traffic still gets through (ping blocked, HTTP isn't).
# Root cause is almost always DOCKER-USER missing from iptables_chains. This
# does NOT query host iptables directly — it reads the bouncer's own config
# (confirms DOCKER-USER is listed) and its own log (confirms it actually
# attached, since the bouncer logs success/failure per chain at startup).
# The bouncer already needs network_mode: host + NET_ADMIN/NET_RAW to do its
# real job; this piggybacks on what it already reports rather than
# duplicating that privilege in the troubleshooter itself.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

CONFIG_PATH="/mnt/bouncer/firewall-bouncer.yaml"
LOG_PATH="/mnt/bouncer/firewall-bouncer.log"

if [[ "${HAS_BOUNCER_CONFIG_MOUNT:-false}" != true ]]; then
  skip "Checking whether the firewall bouncer will actually catch Docker-proxied traffic" \
    "Needs to read the firewall bouncer's own config and log, read-only — never touches host iptables directly, just what the bouncer already reported about itself." \
    "Add these volumes to the troubleshooter service: - ./firewall-bouncer.yaml:/mnt/bouncer/firewall-bouncer.yaml:ro and - ./firewall-bouncer.log:/mnt/bouncer/firewall-bouncer.log:ro" \
    "Just remove those two volume lines — nothing else to undo"
  exit 0
fi

if grep -q 'DOCKER-USER' "$CONFIG_PATH" 2>/dev/null; then
  ok "DOCKER-USER is listed in the firewall bouncer's iptables_chains config"
else
  crit "DOCKER-USER is NOT in the firewall bouncer's iptables_chains config"
  info "Without it, Docker's own NAT rules bypass the ban entirely for any Docker-proxied service —"
  info "the classic 'ping blocked, HTTP still gets through' symptom."
  info "Fix: add DOCKER-USER to iptables_chains in the bouncer's config and restart it."
fi

if [[ "${HAS_BOUNCER_LOG_MOUNT:-false}" == true ]]; then
  if grep -qi 'DOCKER-USER' "$LOG_PATH" 2>/dev/null; then
    ok "Bouncer's own log confirms it attached to DOCKER-USER at startup"
  else
    warn "No mention of DOCKER-USER in the bouncer's log — even if configured, it may not have attached successfully"
    info "Check the log directly for startup errors around chain attachment"
  fi
fi
