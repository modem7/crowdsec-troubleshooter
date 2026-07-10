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
cd "$(dirname "${BASH_SOURCE[0]}")" || { echo "Failed to cd into script directory — this shouldn't happen inside the container"; exit 1; }
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

# run_checks_grouped <dir> — runs every check script in <dir>, printing
# actual results (OK/WARN/CRIT/INFO) as they complete, but holding back the
# 🔒 "not configured" reminders to print together under one header at the
# end instead of interleaved with real results. The two were previously
# indistinguishable at a glance in the same flat stream — this keeps them
# structurally separate without changing what any individual check does.
#
# Trade-off: each check's output has to be fully captured before it can be
# classified, so a check with an internal wait (check_metrics_liveness.sh's
# 10s poll gap) no longer streams its own progress line in real time — it
# appears all at once when the check finishes. Worth it for the readability
# win; nothing else in this tool has a comparable internal delay.
run_checks_grouped() {
  local dir="$1"
  local locked="" out status overall_status=0
  for check in "$dir"/*.sh; do
    out="$(bash "$check")"
    status=$?
    # Capturing output via command substitution above already overwrote $?
    # once for the `[[ ]]` test below — grab it into `status` immediately,
    # before anything else touches $?, or a check's real exit code silently
    # vanishes and the whole tier reports success regardless of what ran.
    (( status != 0 )) && overall_status=$status
    if [[ "$out" == *"🔒"* ]]; then
      locked+="${out}"$'\n'
    else
      printf '%s\n' "$out"
    fi
  done
  if [[ -n "$locked" ]]; then
    echo
    echo "── Optional checks (not configured) ──"
    printf '%s' "$locked"
  fi
  return "$overall_status"
}

run_tier0() {
  run_checks_grouped "checks/tier0_no_credential"
}

run_tier1() {
  info "(tier 1 checks are named actions — e.g. 'check-ip <ip>' — not part of the default sweep)"
}

run_tier2() {
  info "(tier 2 live tests need --target-url and are run explicitly, not part of the default sweep)"
}

run_tier3() {
  run_checks_grouped "checks/tier3_mounted"
}

case "$ACTION" in
  tier-run)
    echo "Wellness Check Results"
    echo "────────────────────────"
    # Explicitly aggregated exit status, not "whatever the last statement's
    # own status happened to be". Two failure modes ruled out here:
    # `(( REQUESTED_TIER >= N )) && run_tierN` leaks the *arithmetic test's*
    # exit status (1) whenever the tier isn't requested — and since that's
    # the last thing run on every default (tier0-only) invocation, the
    # container exited 1 on every wellness check regardless of whether any
    # check failed. Swapping to bare `if`/`fi` avoids that, but introduces
    # the opposite bug: a skipped tier's vacuously-true `if` (exit 0) would
    # silently overwrite run_tier0's real, possibly-nonzero result. Tracking
    # `tier_status` explicitly and only updating it when a stage actually
    # ran avoids both.
    tier_status=0
    run_tier0; (( $? != 0 )) && tier_status=1
    if (( REQUESTED_TIER >= 1 )); then run_tier1; (( $? != 0 )) && tier_status=1; fi
    if (( REQUESTED_TIER >= 2 )); then run_tier2; (( $? != 0 )) && tier_status=1; fi
    if (( REQUESTED_TIER >= 3 )); then run_tier3; (( $? != 0 )) && tier_status=1; fi
    exit "$tier_status"
    ;;
  check-ip)
    [[ -z "$ACTION_ARG" ]] && { echo "Usage: troubleshoot.sh check-ip <ip-address>"; exit 2; }
    bash checks/tier1_bouncer_key/check_ip.sh "$ACTION_ARG"
    ;;
  live-test)
    bash checks/tier2_machine/test_live_block.sh --target-url "$ACTION_ARG"
    ;;
esac
