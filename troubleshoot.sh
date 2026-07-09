#!/usr/bin/env bash
# troubleshoot.sh — main entrypoint.
#
# Always: docker run --rm, never a daemon. --tier selects what to attempt;
# default (no flag) auto-detects the highest tier the current credentials
# satisfy and runs everything up to that. Requesting a higher tier than
# what's configured doesn't fail — it runs what it can and prints the guard
# explanation for the gap, which doubles as a preview of what that tier
# needs before deciding to set it up.

set -uo pipefail
cd "$(dirname "$0")"
source lib/common.sh

# ---- capability detection, always first ----
source capability_check.sh

# ---- argument parsing ----
REQUESTED_TIER="$DETECTED_TIER"
ACTION="tier-run"
ACTION_ARG=""

case "${1:-}" in
  --tier)
    REQUESTED_TIER="${2:-0}"; ACTION="tier-run"
    ;;
  check-ip)
    ACTION="check-ip"; ACTION_ARG="${2:-}"
    ;;
  live-test)
    ACTION="live-test"; ACTION_ARG="${3:-}"  # expects: live-test --target-url <url>
    ;;
  setup)
    exec "setup/${2}.sh" "${@:3}"
    ;;
  "")
    ACTION="tier-run"
    ;;
  *)
    echo "Usage: troubleshoot.sh [--tier N] | check-ip <ip> | live-test --target-url <url> | setup <script-name>"
    exit 2
    ;;
esac

run_tier0() {
  for check in checks/tier0_no_credential/*.sh; do
    bash "$check"
  done
}

run_tier1() {
  info "(tier 1 checks are named actions — e.g. 'check-ip <ip>' — not part of the default sweep)"
}

run_tier2() {
  info "(tier 2 live tests need --target-url and are run explicitly, not part of the default sweep)"
}

run_tier3() {
  for check in checks/tier3_mounted/*.sh; do
    bash "$check"
  done
}

case "$ACTION" in
  tier-run)
    echo "Wellness Check Results"
    echo "────────────────────────"
    run_tier0
    (( REQUESTED_TIER >= 1 )) && run_tier1
    (( REQUESTED_TIER >= 2 )) && run_tier2
    (( REQUESTED_TIER >= 3 )) && run_tier3
    ;;
  check-ip)
    [[ -z "$ACTION_ARG" ]] && { echo "Usage: troubleshoot.sh check-ip <ip-address>"; exit 2; }
    bash checks/tier1_bouncer_key/check_ip.sh "$ACTION_ARG"
    ;;
  live-test)
    bash checks/tier2_machine/test_live_block.sh --target-url "$ACTION_ARG"
    ;;
esac
