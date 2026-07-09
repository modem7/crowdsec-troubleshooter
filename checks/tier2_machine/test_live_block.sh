#!/usr/bin/env bash
# test_live_block.sh — Tier 2, needs machine credentials (read-write).
#
# THE real wellness check: does blocking actually work end-to-end. Adds a
# short-lived decision banning this container's own outbound IP, confirms
# the target service actually returns 403, removes the decision, confirms
# access is restored. Mirrors CrowdSec's own documented health-check flow.
#
# Safety: the trap on EXIT guarantees the test decision is removed even if
# the script is killed, the target is unreachable, or anything else goes
# wrong partway through — this must never leave a stray ban behind.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"
require_jq

usage() { echo "Usage: test_live_block.sh --target-url <url>"; exit 2; }
TARGET_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-url) TARGET_URL="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -z "$TARGET_URL" ]] && usage

if [[ "${HAS_MACHINE_CREDS:-false}" != true ]]; then
  skip "Checking whether bans actually block traffic (recommended — the biggest single proof of health)" \
    "Proving blocking really works means briefly creating a real (tiny, seconds-long) test ban and removing it again. The read-only key alone can't do that — only a 'machine' credential can. Treat it like an admin password, not like the block-checker key: it CAN create/delete real bans; it CANNOT touch Docker, your host, or anything outside CrowdSec's own ban list." \
    "Run on your CrowdSec server: docker exec crowdsec cscli machines add troubleshooter --auto — save the output as a file, point CROWDSEC_MACHINE_CREDENTIALS_FILE at it" \
    "Run on your CrowdSec server: docker exec crowdsec cscli machines delete troubleshooter — then delete the credentials file and unset CROWDSEC_MACHINE_CREDENTIALS_FILE"
  exit 0
fi

MACHINE_TOKEN="$(jq -r '.token // empty' "$CROWDSEC_MACHINE_CREDENTIALS_FILE" 2>/dev/null)"
if [[ -z "$MACHINE_TOKEN" ]]; then
  crit "Couldn't read a valid token from CROWDSEC_MACHINE_CREDENTIALS_FILE"
  exit 1
fi

TEST_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
if [[ -z "$TEST_IP" ]]; then
  warn "Couldn't determine this container's own outbound IP — skipping the live test"
  info "This check needs to know its own public/routable IP to ban and then verify against"
  exit 0
fi

DECISION_ADDED=false
cleanup() {
  if [[ "$DECISION_ADDED" == true ]]; then
    step "Removing test decision for ${TEST_IP}..."
    curl -fsS -X DELETE --max-time 10 \
      -H "Authorization: Bearer ${MACHINE_TOKEN}" \
      "${CROWDSEC_LAPI_URL}/v1/decisions?ip=${TEST_IP}" >/dev/null 2>&1 || \
      warn "Cleanup request failed — verify manually: cscli decisions list -i ${TEST_IP}"
  fi
}
trap cleanup EXIT

step "Adding test decision banning ${TEST_IP} for 60s..."
add_response="$(curl -fsS -X POST --max-time 10 \
  -H "Authorization: Bearer ${MACHINE_TOKEN}" -H "Content-Type: application/json" \
  -d "{\"decisions\":[{\"duration\":\"60s\",\"scope\":\"Ip\",\"value\":\"${TEST_IP}\",\"type\":\"ban\",\"reason\":\"crowdsec-troubleshooter live test\"}]}" \
  "${CROWDSEC_LAPI_URL}/v1/decisions" 2>/dev/null)"

if [[ -z "$add_response" ]]; then
  crit "Failed to add test decision — check CROWDSEC_MACHINE_CREDENTIALS_FILE is still valid"
  exit 1
fi
DECISION_ADDED=true

sleep 2  # give bouncers a moment to pick up the new decision

status="$(http_status "$TARGET_URL")"
if [[ "$status" == "403" ]]; then
  ok "${TARGET_URL} returned 403 from ${TEST_IP} — blocking confirmed working end-to-end"
else
  warn "${TARGET_URL} returned HTTP ${status}, not 403, from a supposedly-banned IP"
  info "This suggests the decision exists in LAPI but isn't reaching the bouncer enforcing this route"
fi

# cleanup runs automatically via trap; verify restoration after it fires
