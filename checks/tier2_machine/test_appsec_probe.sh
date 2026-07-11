#!/usr/bin/env bash
# test_appsec_probe.sh — Tier 2, needs machine credentials.
#
# If AppSec/WAF is in front of the target, hits the documented crowdsec-test
# probe path and confirms a matching alert shows up in LAPI — proves the
# pipeline is actually inspecting requests, not just configured.
#
# The probe path (crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl) is fixed and
# shared by crowdsecurity/http-generic-test and crowdsecurity/appsec-generic-test
# alike, not per-install generated (crowdsec-skill's health-check reference
# confirms this). Both are remediation:false scenarios — they raise an alert,
# never a ban — so this checks GET /v1/alerts rather than looking for a
# block. That endpoint sits behind the same machine-JWT tier test_live_block.sh
# already uses for POST /v1/alerts, and its scenario filter is an exact match
# server-side (pkg/apiserver/controllers/controller.go, pkg/database/
# alertfilter.go — confirmed before writing this, not assumed).
#
# Baseline-then-diff instead of a time filter: record alert ids before firing
# the probe, then poll until an id outside that set shows up (~15s, the
# aggregation delay crowdsec-skill's docs describe). Avoids relying on clock
# sync between this container and the LAPI host.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

SCENARIO="crowdsecurity/appsec-generic-test"
PROBE_PATH="/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl"
POLL_ATTEMPTS="${APPSEC_PROBE_POLL_ATTEMPTS:-5}"
POLL_INTERVAL="${APPSEC_PROBE_POLL_INTERVAL:-3}"

usage() { echo "Usage: test_appsec_probe.sh --target-url <url>"; exit 2; }
TARGET_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-url) TARGET_URL="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -z "$TARGET_URL" ]] && usage

if [[ "${HAS_MACHINE_CREDS:-false}" != true ]]; then
  skip "Checking the AppSec/WAF pipeline is actually inspecting requests" \
    "Same machine credential as the live block test above — needed to query LAPI for the resulting alert after the probe request." \
    "See test_live_block.sh — same credential, same setup step covers both" \
    "See test_live_block.sh — same credential, same removal step covers both"
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

# Raw response, not ids — the baseline check below needs to tell "LAPI
# unreachable" (empty body) apart from "reachable, no alerts yet" ([]).
fetch_alerts() {
  curl -fsS --max-time 10 \
    -H "Authorization: Bearer ${MACHINE_TOKEN}" \
    "${CROWDSEC_LAPI_URL}/v1/alerts?scenario=${SCENARIO}&limit=20" 2>/dev/null
}

step "Recording existing ${SCENARIO} alerts as a baseline..."
baseline="$(fetch_alerts)"
if [[ -z "$baseline" ]]; then
  crit "Couldn't reach LAPI at ${CROWDSEC_LAPI_URL} to record a baseline"
  exit 1
fi
baseline_ids="$(jq -r '.[].id' <<<"$baseline" 2>/dev/null)"

step "Requesting ${TARGET_URL}${PROBE_PATH}..."
curl -fsS --max-time 10 "${TARGET_URL}${PROBE_PATH}" >/dev/null 2>&1 || true

step "Polling for a new ${SCENARIO} alert (up to $((POLL_ATTEMPTS * POLL_INTERVAL))s — alert aggregation can lag the request)..."
new_id=""
for _ in $(seq 1 "$POLL_ATTEMPTS"); do
  sleep "$POLL_INTERVAL"
  current_ids="$(fetch_alerts | jq -r '.[].id' 2>/dev/null)"
  new_id="$(comm -13 <(sort <<<"$baseline_ids") <(sort <<<"$current_ids") | head -n1)"
  [[ -n "$new_id" ]] && break
done

if [[ -n "$new_id" ]]; then
  ok "AppSec probe confirmed — alert id ${new_id} appeared for scenario ${SCENARIO}"
else
  warn "No new ${SCENARIO} alert appeared within $((POLL_ATTEMPTS * POLL_INTERVAL))s of probing ${TARGET_URL}${PROBE_PATH}"
  info "If you don't run AppSec/WAF in front of this target, this is expected — there's nothing to
inspect the request. If you do, this suggests the probe request isn't reaching the AppSec
component, or the appsec-generic-test collection isn't installed (cscli collections list)."
fi
