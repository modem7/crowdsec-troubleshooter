#!/usr/bin/env bash
# test_appsec_probe.sh — Tier 2, needs machine credentials.
#
# If AppSec/WAF is in use, hits the documented crowdsec-test probe path and
# confirms a matching alert appears — proves the AppSec pipeline is actually
# inspecting requests end-to-end, not just that it's configured. This is also
# where CVE-2026-44982 (chunked/no-Content-Length body bypass, fixed in
# 1.7.8) becomes concrete rather than abstract: this test would have failed
# to register a body-based match on an unpatched version.
#
# STATUS: needs testing against a live AppSec-enabled instance to confirm
# the exact probe path format — CrowdSec's docs show an example token
# (crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl) but don't specify whether it's
# fixed or generated per-install. Treat the path below as unverified until
# checked against a real deployment.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

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
    "Same machine credential as the live block test above — needed to check LAPI for the resulting alert after the probe request." \
    "See test_live_block.sh — same credential, same setup step covers both" \
    "See test_live_block.sh — same credential, same removal step covers both"
  exit 0
fi

# TODO(verify): confirm whether the probe path is fixed or per-install generated
PROBE_PATH="/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl"

step "Requesting ${TARGET_URL}${PROBE_PATH}..."
curl -fsS --max-time 10 "${TARGET_URL}${PROBE_PATH}" >/dev/null 2>&1 || true

info "This check is a stub pending verification against a live AppSec-enabled instance.
See the comment at the top of this file for what needs confirming before it's trustworthy."
exit 0
