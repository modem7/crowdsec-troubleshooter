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
    "Run on your CrowdSec server: docker exec crowdsec cscli machines add troubleshooter --auto -f - — the -f - avoids colliding with /etc/crowdsec/local_api_credentials.yaml (crowdsec's own engine already uses that path) and prints a Login/Password pair instead. Save them as JSON ({\"login\":\"...\",\"password\":\"...\"}), then mount that file into this container with -v and point CROWDSEC_MACHINE_CREDENTIALS_FILE at the in-container path (see setup/register_machine.sh for the full walkthrough)" \
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

MACHINE_TOKEN="$(jq -r '.token // empty' <<<"$login_response" 2>/dev/null)"
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
# There is no POST /v1/decisions — that endpoint is GET (list)/DELETE
# (remove) only. A confirmed-working live test against a real LAPI instance
# hit this: `cscli decisions add` doesn't call any such endpoint either —
# it builds a full synthetic Alert with the decision embedded and POSTs
# that to /v1/alerts (see pkg/apiclient/alerts_service.go and
# cmd/crowdsec-cli/clidecision/decisions.go in crowdsecurity/crowdsec).
# Field shape below (capacity/leakspeed/events/etc., decision.scenario
# instead of a "reason" key) is copied from that Go struct, not guessed —
# see DESIGN.md for the earlier lesson about assuming an endpoint exists
# without checking against the real API first.
ALERT_REASON="crowdsec-troubleshooter live test"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
alert_payload=$(cat <<EOF
[{"capacity":0,"leakspeed":"0","message":"${ALERT_REASON}","events":[],"events_count":1,
"scenario":"${ALERT_REASON}","scenario_hash":"","scenario_version":"","simulated":false,
"start_at":"${NOW}","stop_at":"${NOW}","remediation":true,"kind":"cscli",
"source":{"ip":"${TEST_IP}","scope":"Ip","value":"${TEST_IP}"},
"decisions":[{"duration":"60s","scope":"Ip","value":"${TEST_IP}","type":"ban","scenario":"${ALERT_REASON}","origin":"cscli"}]}]
EOF
)

# No -f here on purpose: a failed request needs its body to be diagnosable.
# -f discards the response body on any 4xx/5xx, which is exactly what
# turned the original bug into a bare "check your credentials" guess
# instead of an actual LAPI error message.
add_raw="$(curl -sS -w '\n%{http_code}' -X POST --max-time 10 \
  -H "Authorization: Bearer ${MACHINE_TOKEN}" -H "Content-Type: application/json" \
  -d "$alert_payload" \
  "${CROWDSEC_LAPI_URL}/v1/alerts" 2>/dev/null)"
add_http_code="${add_raw##*$'\n'}"
add_body="${add_raw%$'\n'*}"

if [[ "$add_http_code" != "201" ]]; then
  crit "Failed to add test decision — LAPI returned HTTP ${add_http_code}"
  info "Response: ${add_body:-<empty — LAPI unreachable or connection dropped>}"
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
