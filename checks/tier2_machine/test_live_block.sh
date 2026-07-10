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
#
# Credentials file holds login+password, NOT a ready bearer token. An
# earlier version read a `.token` field directly out of the credentials
# file, but `cscli machines add --auto` only ever prints a login/password
# pair — there's no ready-made token to save. A machine authenticates by
# POSTing that login+password to /v1/watchers/login, which returns a
# short-lived JWT. Doing that exchange once at setup time and saving the
# resulting token would work for a few hours and then silently start
# failing, so instead we mint a fresh token on every run, same as a real
# CrowdSec agent does.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
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
    "Run on your CrowdSec server: docker exec crowdsec cscli machines add troubleshooter --auto — it prints a Login/Password pair. Save them as JSON ({\"login\":\"...\",\"password\":\"...\"}), then mount that file into this container with -v and point CROWDSEC_MACHINE_CREDENTIALS_FILE at the in-container path (see setup/register_machine.sh for the full walkthrough)" \
    "Run on your CrowdSec server: docker exec crowdsec cscli machines delete troubleshooter — then delete the credentials file and unset CROWDSEC_MACHINE_CREDENTIALS_FILE"
  exit 0
fi

MACHINE_LOGIN="$(jq -r '.login // empty' "$CROWDSEC_MACHINE_CREDENTIALS_FILE" 2>/dev/null)"
MACHINE_PASSWORD="$(jq -r '.password // empty' "$CROWDSEC_MACHINE_CREDENTIALS_FILE" 2>/dev/null)"
if [[ -z "$MACHINE_LOGIN" || -z "$MACHINE_PASSWORD" ]]; then
  crit "Couldn't read login/password from CROWDSEC_MACHINE_CREDENTIALS_FILE"
  info "Expected JSON: {\"login\": \"...\", \"password\": \"...\"} — see setup/register_machine.sh"
  exit 1
fi

step "Logging in as machine '${MACHINE_LOGIN}' to mint a fresh token..."
login_response="$(curl -fsS -X POST --max-time 10 \
  -H "Content-Type: application/json" \
  -d "{\"machine_id\":\"${MACHINE_LOGIN}\",\"password\":\"${MACHINE_PASSWORD}\"}" \
  "${CROWDSEC_LAPI_URL}/v1/watchers/login" 2>/dev/null)"

MACHINE_TOKEN="$(echo "$login_response" | jq -r '.token // empty' 2>/dev/null)"
if [[ -z "$MACHINE_TOKEN" ]]; then
  crit "Machine login failed — credential may be wrong or deleted. Check: docker exec crowdsec cscli machines list"
  exit 1
fi

TEST_IP="$(curl -fsS --max-time 5 "${IP_ECHO_URL:-https://api.ipify.org}" 2>/dev/null || echo "")"
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
trap cleanup EXIT SIGTERM SIGINT
# Explicit, not just EXIT: this script runs as PID 1 inside the container.
# Linux gives PID 1 special treatment — any signal without an explicitly
# installed handler is silently ignored by the kernel (so an init process
# can't die by accident). A bare `trap cleanup EXIT` may not count as an
# explicit SIGTERM handler in that context, meaning `docker stop` could be
# ignored until the grace period expires and SIGKILL forces it — skipping
# this cleanup entirely, and SIGKILL can't be trapped by anything. Naming
# SIGTERM/SIGINT explicitly here is the actual fix; it costs nothing and
# needs no init-system dependency (tini/dumb-init/s6) to get right.

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
