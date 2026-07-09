#!/usr/bin/env bash
# check_lapi_alive.sh — Tier 0, no credential needed.
#
# LAPI has a real, purpose-built, unauthenticated /health endpoint. A 200
# proves the process is up and speaking the CrowdSec protocol; anything else
# (connection refused, timeout, non-200) means it isn't. No API key needed —
# this is the one thing LAPI has to answer for literally anyone.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

status="$(http_status "${CROWDSEC_LAPI_URL}/health")"

if [[ "$status" == "200" ]]; then
  ok "CrowdSec LAPI is up and responding at ${CROWDSEC_LAPI_URL}"
  exit 0
elif [[ "$status" == "000" ]]; then
  crit "Can't reach LAPI at ${CROWDSEC_LAPI_URL} — connection refused or timed out"
  info "Check: is the crowdsec container running? Is CROWDSEC_LAPI_URL using the right service name/port?"
  exit 1
else
  warn "LAPI responded, but with HTTP ${status} instead of the expected 200"
  info "Something is listening at that address, but it may not be CrowdSec's LAPI — double-check CROWDSEC_LAPI_URL"
  exit 1
fi
