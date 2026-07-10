#!/usr/bin/env bash
# check_ban_stats.sh — Tier 1, needs a dedicated read-only bouncer key.
#
# Visible proof CrowdSec is actually doing its job, not just running: how
# many decisions are active right now, broken down by scope and origin.
# Uses GET /v1/decisions with no filter and the same X-Api-Key bouncers
# already use — the exact same read path check_ip.sh uses for a single IP,
# just without the ?ip= filter. Unlike check-ip (which needs an IP argument
# and so stays a named action), this needs no input at all, so it runs
# automatically as part of the default sweep whenever a bouncer key is
# present — see troubleshoot.sh's run_tier1().

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

if [[ "${HAS_BOUNCER_KEY:-false}" != true ]]; then
  skip "Showing current ban stats (proof CrowdSec is actively enforcing, not just running)" \
    "Same read-only bouncer key as the IP block checker — this just asks for the whole list instead of one IP." \
    "Run on your CrowdSec server: docker exec crowdsec cscli bouncers add troubleshooter-readonly — then set CROWDSEC_LAPI_KEY to the key it prints" \
    "Run on your CrowdSec server: docker exec crowdsec cscli bouncers delete troubleshooter-readonly — then unset CROWDSEC_LAPI_KEY"
  exit 0
fi

response="$(http_get "${CROWDSEC_LAPI_URL}/v1/decisions" "X-Api-Key: ${CROWDSEC_LAPI_KEY}")"
status=$?

if [[ $status -ne 0 ]]; then
  crit "Couldn't reach LAPI to fetch ban stats — check CROWDSEC_LAPI_KEY is still valid"
  exit 1
fi

if [[ -z "$response" || "$response" == "null" || "$response" == "[]" ]]; then
  info "No active decisions right now — not necessarily a problem, just means nothing's currently banned"
  exit 0
fi

count="$(echo "$response" | jq 'length')"
ok "${count} decision(s) currently active"

by_scope="$(echo "$response" | jq -r '.[].scope // "unknown"' | sort | uniq -c | sort -rn)"
by_origin="$(echo "$response" | jq -r '.[].origin // "unknown"' | sort | uniq -c | sort -rn)"

echo "   By scope:"
echo "$by_scope" | awk '{printf "     %s: %s\n", $2, $1}'
echo "   By origin:"
echo "$by_origin" | awk '{printf "     %s: %s\n", $2, $1}'
exit 0
